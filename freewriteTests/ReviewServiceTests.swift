//
//  ReviewServiceTests.swift
//  freewriteTests
//
//  End-to-end review with PiDurableKit's scripted FauxProvider: no network, no keys.
//

import Foundation
import PiDurableKit
import Testing
@testable import freewrite

@MainActor
struct ReviewServiceTests {
    private let entryId = UUID(uuidString: "6910BBDE-75FC-415C-ABB9-C76644B037B2")!
    private let entry = "[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04].md"

    private func makeFolder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("freewrite-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeService(root: URL, faux: FauxProvider, credentials: any CredentialStore = InMemoryCredentialStore()) throws -> ReviewService {
        ReviewService(directory: try makeFolder("reviews-db"), credentials: credentials, root: { root }) { credentials in
            let models = Models(credentials: credentials, builtinProviders: false, catalog: nil)
            try await models.register(faux)
            return models
        }
    }

    private let profile = ReviewerProfile(id: "mirror", name: "Mirror", instructions: "Reflect.", model: "faux/faux-1", color: .yellow)

    @Test func scriptedReviewWritesAnnotationsAndSummary() async throws {
        let root = try makeFolder("entries")
        let versions = EntryVersionStore(root: root)
        try "Monday. I keep avoiding it, the call to Dad.".write(to: versions.entryFileURL(for: entry), atomically: true, encoding: .utf8)

        let faux = FauxProvider()
        let service = try makeService(root: root, faux: faux)
        _ = try await service.models()  // registers the faux provider
        try await faux.append(
            .toolCall("add_annotation", ["quote": "I keep avoiding it", "comment": "You say it straight out.", "kind": "observation"]),
            .toolCall("write", ["path": "/tmp/x", "content": "nope"]),
            .toolCall("add_annotation", ["quote": "not in the text", "comment": "Should fail."])
        )
        try await faux.append(.toolCall("finish_review", ["summary": "A short, honest entry."]))

        let outcome = try await service.review(entryFilename: entry, entryId: entryId, versionId: "v1", profile: profile)
        #expect(outcome.added == 1)
        #expect(outcome.summary == "A short, honest entry.")
        #expect(service.activeRuns.isEmpty)
        #expect(try await faux.pendingResponseCount() == 0)  // finish_review ended the run

        let saved = try AnnotationStore(versionStore: versions).load(for: entry)
        #expect(saved.count == 1)
        let note = try #require(saved.first)
        #expect(note.anchor.quote == "I keep avoiding it")
        #expect(note.anchor.start == 8 && note.anchor.end == 26)
        #expect(note.versionId == "v1")
        #expect(note.reviewerId == "mirror")
        #expect(note.entryId == entryId.uuidString)
        #expect(note.runId == "review:\(entryId.uuidString):v1:mirror:1")
        #expect(note.status == .active)

        // A second run gets the next run number.
        try await faux.append(.toolCall("finish_review", ["summary": "Nothing new."]))
        _ = try await service.review(entryFilename: entry, entryId: entryId, versionId: "v1", profile: profile)
        #expect(try AnnotationStore(versionStore: versions).load(for: entry).count == 1)
        await service.close()
    }

    @Test func modelErrorsSurfaceAsReviewErrors() async throws {
        let root = try makeFolder("entries")
        try "Something.".write(to: EntryVersionStore(root: root).entryFileURL(for: entry), atomically: true, encoding: .utf8)
        let faux = FauxProvider()
        let service = try makeService(root: root, faux: faux)
        _ = try await service.models()
        try await faux.append([FauxResponse.error("Network connection was lost")])
        await #expect(throws: ReviewError.failed("Couldn't reach the model. Check your connection.")) {
            try await service.review(entryFilename: entry, entryId: entryId, versionId: "v1", profile: profile)
        }
        await service.close()
    }

    @Test func unconfiguredProvidersAreReportedBeforeRunning() async throws {
        let service = try makeService(root: try makeFolder("entries"), faux: FauxProvider())
        var automatic = profile
        automatic.model = ""
        await #expect(throws: ReviewError.notConfigured) { try await service.resolveModel(for: automatic) }
        var claude = profile
        claude.model = "anthropic/claude-sonnet-5-5"
        await #expect(throws: ReviewError.providerNotConfigured("Anthropic (Claude)")) { try await service.resolveModel(for: claude) }
        try await service.credentials.setCredential(.apiKey("sk-ant-test"), for: .anthropic)
        #expect(try await service.resolveModel(for: automatic) == ModelRef(provider: .anthropic, modelId: "claude-sonnet-5-5"))
        await service.refreshCredentials()
        #expect(service.credentialStates[.anthropic] == .apiKey("…test"))
        #expect(service.credentialStates[.openAI] == ProviderCredentialState.none)
    }
}
