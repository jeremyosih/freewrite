//
//  AnnotationKindTests.swift
//  freewriteTests
//

import Foundation
import Testing
@testable import freewrite

struct AnnotationKindTests {
    private let entry = "[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04].md"

    @Test func parsesKindsAndAliases() {
        #expect(AnnotationKind.parse("grammar") == .grammar)
        #expect(AnnotationKind.parse("  Clarity \n") == .clarity)
        #expect(AnnotationKind.parse("typo") == .grammar)
        #expect(AnnotationKind.parse("suggestion") == .clarity)
        #expect(AnnotationKind.parse("observation") == .insight)
        #expect(AnnotationKind.parse("praise") == .praise)
        #expect(AnnotationKind.parse("nonsense") == nil)
        #expect(AnnotationKind.parse("") == nil)
        #expect(AnnotationKind.parse(nil) == nil)
    }

    @Test func oldKindsInAnnotationsMapToTheClosestOrNeutral() throws {
        let anchor = AnnotationAnchor(quote: "a", prefix: "", suffix: "", start: 0, end: 1)
        func note(_ kind: String) -> Annotation {
            Annotation(id: "A", entryId: "E", versionId: "v1", reviewerId: "mirror", runId: "r", anchor: anchor,
                       comment: "c", kind: kind, status: .active, createdAt: Date(timeIntervalSince1970: 0))
        }
        #expect(note("observation").resolvedKind == .insight)
        #expect(note("question").resolvedKind == .question)
        #expect(note("suggestion").resolvedKind == .clarity)
        #expect(note("praise").resolvedKind == .praise)
        #expect(note("something-else").resolvedKind == .insight)

        // The stored word survives a round trip; only its reading changes.
        let data = try JSONEncoder().encode([note("observation")])
        let decoded = try JSONDecoder().decode([Annotation].self, from: data)
        #expect(decoded.first?.kind == "observation")
    }

    @Test func normalizedKeepsCanonicalOrderAndIsNeverEmpty() {
        #expect(AnnotationKind.normalized([.praise, .grammar, .praise]) == [.grammar, .praise])
        #expect(AnnotationKind.normalized([]) == AnnotationKind.allCases)
    }

    private func makeToolbox(text: String, kinds: [AnnotationKind]?, defaultKind: AnnotationKind?) throws -> ReviewToolbox {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freewrite-kinds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = EntryVersionStore(root: root)
        try text.write(to: store.entryFileURL(for: entry), atomically: true, encoding: .utf8)
        let run = ReviewRunContext(entryFilename: entry, entryId: "E", versionId: "v1", reviewerId: "editor",
                                   reviewerName: "Editor", runId: "review:E:v1:editor:1", scope: .latest,
                                   kinds: kinds, defaultKind: defaultKind)
        return ReviewToolbox(versionStore: store, run: run)
    }

    @Test func addAnnotationValidatesKindAndFallsBackToTheDefault() throws {
        let toolbox = try makeToolbox(text: "Their going home. It was fine. Mostly.",
                                      kinds: [.grammar, .clarity, .structure], defaultKind: .clarity)
        let picked = try toolbox.addAnnotation(.init(quote: "Their", comment: "There.", kind: "Grammar"), id: "A1")
        #expect(!picked.contains("Note:"))
        let missing = try toolbox.addAnnotation(.init(quote: "It was fine", comment: "Vague."), id: "A2")
        #expect(!missing.contains("Note:"))
        let unknown = try toolbox.addAnnotation(.init(quote: "Mostly", comment: "Hm.", kind: "vibes"), id: "A3")
        #expect(unknown.contains("isn't a kind"))
        let forbidden = try toolbox.addAnnotation(.init(quote: "going home", comment: "Nice.", kind: "praise"), id: "A4")
        #expect(forbidden.contains("can't leave praise"))

        let saved = Dictionary(uniqueKeysWithValues: try toolbox.annotations.load(for: entry).map { ($0.id, $0.kind) })
        #expect(saved == ["A1": "grammar", "A2": "clarity", "A3": "clarity", "A4": "clarity"])

        // A bad kind on update keeps the old one; a good one changes it.
        let kept = try toolbox.updateAnnotation(id: "A1", comment: nil, kind: "praise")
        #expect(kept.contains("kept its kind"))
        _ = try toolbox.updateAnnotation(id: "A2", comment: nil, kind: "structure")
        let updated = Dictionary(uniqueKeysWithValues: try toolbox.annotations.load(for: entry).map { ($0.id, $0.kind) })
        #expect(updated["A1"] == "grammar")
        #expect(updated["A2"] == "structure")
    }

    @Test func runsStoredBeforeKindsAllowEverything() throws {
        let toolbox = try makeToolbox(text: "Nice line.", kinds: nil, defaultKind: nil)
        #expect(toolbox.allowedKinds == AnnotationKind.allCases)
        #expect(toolbox.defaultKind == .insight)
        _ = try toolbox.addAnnotation(.init(quote: "Nice", comment: "Yes.", kind: "praise"), id: "P")
        #expect(try toolbox.annotations.load(for: entry).first?.kind == "praise")
    }

    @Test func agentsPickTheirOwnLabelColourAndStyle() throws {
        let toolbox = try makeToolbox(text: "Their going home. It was fine.", kinds: nil, defaultKind: nil)
        let added = try toolbox.addAnnotation(.init(quote: "Their", comment: "There.", kind: "typo", color: "#ff0000", style: "squiggle", author: "Editor"), id: "T1")
        #expect(!added.contains("Note:"))
        let odd = try toolbox.addAnnotation(.init(quote: "It was fine", comment: "Vague.", color: "sparkly", style: "neon"), id: "T2")
        #expect(odd.contains("isn't a colour") && odd.contains("isn't a style"))
        let saved = Dictionary(uniqueKeysWithValues: try toolbox.annotations.load(for: entry).map { ($0.id, $0) })
        #expect(saved["T1"]?.kind == "typo" && saved["T1"]?.color == "#ff0000" && saved["T1"]?.style == "squiggle" && saved["T1"]?.author == "Editor")
        #expect(saved["T2"]?.kind == "note" && saved["T2"]?.color == nil && saved["T2"]?.style == nil)
        _ = try toolbox.updateAnnotation(id: "T2", comment: nil, kind: "tension", color: "teal", style: "highlight")
        let updated = try toolbox.annotations.load(for: entry).first { $0.id == "T2" }
        #expect(updated?.kind == "tension" && updated?.color == "teal" && updated?.style == "highlight")
        let log = toolbox.versionStore.log(for: entry)
        #expect(log.map(\.op) == [.noteAdd, .noteAdd, .noteUpdate])
        #expect(log.first?.author == "Editor" && log.first?.note == "T1" && log.first?.version == "v1")
        #expect(log.first?.summary.contains("note.add T1 on v1: typo \"Their\"") == true)
    }

    @Test func noteStyleFollowsTheAgentsChoices() throws {
        func note(_ kind: String, color: String? = nil, style: String? = nil) -> Annotation {
            Annotation(id: "x", entryId: "", versionId: "v1", reviewerId: "claude-code", runId: "", anchor: nil,
                       comment: "", kind: kind, status: .active, createdAt: Date(), color: color, style: style)
        }
        #expect(NoteStyle(note("grammar")).isSquiggle)
        #expect(!NoteStyle(note("grammar", style: "highlight")).isSquiggle)
        #expect(NoteStyle(note("tension")).label == "Tension")
        #expect(NoteStyle(note("tension")).color == NoteStyle(note("Tension")).color)
        #expect(NoteStyle(note("x", color: "red")).color == .systemRed)
        #expect(NoteStyle.parse("#0f0") != nil && NoteStyle.parse("#00ff00") != nil && NoteStyle.parse("nope") == nil)
    }

    @Test func briefListsTheReviewersKinds() throws {
        let toolbox = try makeToolbox(text: "Short.", kinds: [.insight, .question], defaultKind: .insight)
        let brief = toolbox.brief()
        #expect(brief.contains("- insight:"))
        #expect(brief.contains("- question:"))
        #expect(!brief.contains("- grammar:"))
    }
}
