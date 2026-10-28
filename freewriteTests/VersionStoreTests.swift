//
//  VersionStoreTests.swift
//  freewriteTests
//

import Foundation
import Testing
@testable import freewrite

struct EntryVersionStoreTests {
    private let fileManager = FileManager.default
    private let entry = "[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04].md"
    private let base = "[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04]"

    private func makeFolder() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("freewrite-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(text: String = "first draft") throws -> EntryVersionStore {
        let store = EntryVersionStore(root: try makeFolder())
        try text.write(to: store.entryFileURL(for: entry), atomically: true, encoding: .utf8)
        return store
    }

    private func makeAudio(in store: EntryVersionStore, _ contents: String = "audio") throws -> URL {
        let url = store.root.appendingPathComponent("recording-\(UUID().uuidString).m4a")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    @Test func plainEntryHasOneImplicitVersion() throws {
        let store = try makeStore()
        #expect(try store.savedManifest(for: entry) == nil)
        let versions = store.versions(for: entry)
        #expect(versions.map(\.id) == ["v1"])
        #expect(versions[0].source == .typed)
        #expect(versions[0].createdAt == EntryVersionStore.timestamp(inEntryFilename: entry))
        #expect(try store.text(of: "v1", for: entry) == "first draft")
        // Reading never creates the Entries folder.
        #expect(!fileManager.fileExists(atPath: store.entriesURL.path))
        #expect(throws: EntryVersionStore.Failure.unknownVersion("v2")) {
            try store.text(of: "v2", for: entry)
        }
    }

    @Test func aNewVersionCanStartFromAnyVersion() throws {
        let store = try makeStore()
        // v1 "first draft" → v2 from v1 (copy) → edit → v3 blank → v4 from v2.
        let second = try store.sealCurrent(entryFilename: entry, from: "v1")
        #expect(second.version("v2")?.parent == "v1")
        #expect(read(store.entryFileURL(for: entry)) == "first draft")
        try "first draft, tightened".write(to: store.entryFileURL(for: entry), atomically: true, encoding: .utf8)
        let third = try store.sealCurrent(entryFilename: entry)
        #expect(third.version("v3")?.parent == nil)
        try "something else".write(to: store.entryFileURL(for: entry), atomically: true, encoding: .utf8)
        let fourth = try store.sealCurrent(entryFilename: entry, from: "v2")
        #expect(read(store.entryFileURL(for: entry)) == "first draft, tightened")
        #expect(fourth.tree.map { "\($0.version.id):\($0.depth)" } == ["v1:0", "v2:1", "v4:2", "v3:0"])
        let log = store.log(for: entry).filter { $0.op == .versionCreate }
        #expect(log.map(\.version) == ["v2", "v3", "v4"])
        #expect(log.map(\.from) == ["v1", nil, "v2"])
        #expect(log.map(\.sealed) == ["v1", "v2", "v3"])
        #expect(log.allSatisfy { $0.actor == EntryEvent.user })
        #expect(throws: EntryVersionStore.Failure.unknownVersion("v9")) {
            try store.sealCurrent(entryFilename: entry, from: "v9")
        }
    }

    @Test func sealingKeepsTheTextAndStartsAnEmptyVersion() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manifest = try store.sealCurrent(entryFilename: entry, now: now)

        #expect(manifest.current == "v2")
        #expect(manifest.versions.map(\.id) == ["v1", "v2"])
        #expect(manifest.versions[1].createdAt == now)
        #expect(read(store.root.appendingPathComponent("Entries/\(base)/versions/v1.md")) == "first draft")
        #expect(read(store.entryFileURL(for: entry)) == "")
        #expect(try store.text(of: "v1", for: entry) == "first draft")
        #expect(try store.text(of: "v2", for: entry) == "")

        try "second draft".write(to: store.entryFileURL(for: entry), atomically: true, encoding: .utf8)
        let third = try store.sealCurrent(entryFilename: entry)
        #expect(third.current == "v3")
        #expect(try store.text(of: "v2", for: entry) == "second draft")
        #expect(try store.text(of: "v1", for: entry) == "first draft")
        #expect(store.manifest(for: entry).sealedVersions.map(\.id) == ["v1", "v2"])
    }

    @Test func refusesToSealAnEmptyVersion() throws {
        let store = try makeStore(text: "  \n ")
        #expect(throws: EntryVersionStore.Failure.emptyVersion) {
            try store.sealCurrent(entryFilename: entry)
        }
        #expect(!fileManager.fileExists(atPath: store.entriesURL.path))
    }

    @Test func corruptManifestIsNeverOverwritten() throws {
        let store = try makeStore()
        let url = store.manifestURL(for: entry)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{not json".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) {
            try store.sealCurrent(entryFilename: entry)
        }
        #expect(read(url) == "{not json")
        #expect(read(store.entryFileURL(for: entry)) == "first draft")
    }

    @Test func manifestRoundTripsAsDocumentedJSON() throws {
        let store = try makeStore()
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        var first = EntryVersion(n: 1, createdAt: created, source: .voiceNote, audio: "audio/v1.m4a")
        first.previousAudio = nil
        let manifest = EntryManifest(current: "v2", versions: [first, EntryVersion(n: 2, createdAt: created)])
        try store.saveManifest(manifest, for: entry)
        #expect(try store.savedManifest(for: entry) == manifest)

        let json = try #require(read(store.manifestURL(for: entry)))
        #expect(json.contains(#""current" : "v2""#))
        #expect(json.contains(#""source" : "voice-note""#))
        #expect(json.contains(#""audio" : "audio/v1.m4a""#))
        #expect(json.contains(#""createdAt" : "2027-01-15T08:00:00Z""#))
        #expect(!json.contains("previousAudio"))
    }

    @Test func voiceNoteOnEmptyEntryBecomesAVoiceNoteVersion() throws {
        let store = try makeStore(text: "")
        let recording = try makeAudio(in: store)
        let attachment = try store.attachVoiceNote(from: recording, to: entry)

        #expect(attachment.versionId == "v1")
        #expect(attachment.audioPath == "audio/v1.m4a")
        #expect(attachment.audioURL == store.root.appendingPathComponent("Entries/\(base)/audio/v1.m4a"))
        #expect(!fileManager.fileExists(atPath: recording.path))
        #expect(read(attachment.audioURL) == "audio")
        let saved = try #require(try store.savedManifest(for: entry))
        #expect(saved.versions == [EntryVersion(n: 1, createdAt: saved.versions[0].createdAt, source: .voiceNote, audio: "audio/v1.m4a")])
        #expect(saved.hasVoiceNote && saved.isInteresting)

        try store.saveTranscript("hello there", forAudio: attachment.audioPath, entryFilename: entry)
        #expect(read(store.root.appendingPathComponent("Entries/\(base)/audio/v1.transcript.md")) == "hello there")
    }

    @Test func voiceNoteOnLaterVersionAttachesToTheCurrentOne() throws {
        let store = try makeStore()
        try store.sealCurrent(entryFilename: entry)
        try "typing in v2".write(to: store.entryFileURL(for: entry), atomically: true, encoding: .utf8)

        let attachment = try store.attachVoiceNote(from: try makeAudio(in: store), to: entry)
        #expect(attachment.versionId == "v2")
        #expect(attachment.audioPath == "audio/v2.m4a")
        let v2 = try #require(attachment.manifest.version("v2"))
        #expect(v2.source == .typed)  // it already had text
        #expect(attachment.manifest.version("v1")?.audio == nil)

        // A second note for the same version keeps the first one.
        let again = try store.attachVoiceNote(from: try makeAudio(in: store, "second"), to: entry)
        #expect(again.audioPath == "audio/v2-2.m4a")
        let updated = try #require(again.manifest.version("v2"))
        #expect(updated.audio == "audio/v2-2.m4a")
        #expect(updated.previousAudio == ["audio/v2.m4a"])
        #expect(updated.allAudio == ["audio/v2.m4a", "audio/v2-2.m4a"])
        #expect(try store.savedManifest(for: entry) == again.manifest)
    }

    @Test func deletingRemovesTheEntryFolder() throws {
        let store = try makeStore()
        try store.sealCurrent(entryFilename: entry)
        _ = try store.attachVoiceNote(from: try makeAudio(in: store), to: entry)
        #expect(fileManager.fileExists(atPath: store.entryDirectory(for: entry).path))

        try store.deleteEntryDirectory(for: entry)
        #expect(!fileManager.fileExists(atPath: store.entryDirectory(for: entry).path))
        #expect(try store.savedManifest(for: entry) == nil)
        // Deleting an entry that never had versions is fine.
        try store.deleteEntryDirectory(for: "[AAAAAAAA-75FC-415C-ABB9-C76644B037B2]-[2026-02-21-08-01-04].md")
    }

    @Test func listsSavedManifests() throws {
        let store = try makeStore()
        let other = "[AAAAAAAA-75FC-415C-ABB9-C76644B037B2]-[2026-02-21-08-01-04].md"
        try "plain".write(to: store.entryFileURL(for: other), atomically: true, encoding: .utf8)
        #expect(store.savedManifests().isEmpty)

        try store.sealCurrent(entryFilename: entry)
        let manifests = store.savedManifests()
        #expect(Array(manifests.keys) == [entry])
        #expect(manifests[entry]?.versions.count == 2)
    }

    @Test func storageTransferCarriesVersions() throws {
        let store = try makeStore()
        try store.sealCurrent(entryFilename: entry)
        _ = try store.attachVoiceNote(from: try makeAudio(in: store), to: entry)
        let destination = try makeFolder()

        #expect(StorageTransfer.items(in: store.root) == [
            "Entries/\(base)/audio/v2.m4a",
            "Entries/\(base)/entry.json",
            "Entries/\(base)/log.jsonl",
            "Entries/\(base)/versions/v1.md",
            entry,
        ].sorted())

        let report = StorageTransfer.transfer(from: store.root, to: destination, mode: .move)
        #expect(report.succeeded && report.notRemoved.isEmpty)
        #expect(!fileManager.fileExists(atPath: store.entriesURL.path))

        let moved = EntryVersionStore(root: destination)
        #expect(moved.versions(for: entry).map(\.id) == ["v1", "v2"])
        #expect(try moved.text(of: "v1", for: entry) == "first draft")
        #expect(moved.manifest(for: entry).currentVersion?.audio == "audio/v2.m4a")
        #expect(StorageTransfer.overlaps(store.root, store.root.appendingPathComponent("Entries/inside")))
    }
}
