//
//  AnnotationTests.swift
//  freewriteTests
//

import Foundation
import Testing
@testable import freewrite

struct AnnotationAnchoringTests {
    private func anchor(_ quote: String, prefix: String? = nil, suffix: String? = nil, in text: String) throws -> AnnotationAnchor {
        try AnnotationAnchoring.anchor(quote: quote, prefix: prefix, suffix: suffix, in: text).get()
    }

    @Test func uniqueQuoteGetsUTF16OffsetsAndContext() throws {
        let text = "Morning 🌧️. I keep avoiding it, the call to Dad."
        let found = try anchor("I keep avoiding it", in: text)
        let expectedStart = ("Morning 🌧️. " as NSString).length
        #expect(found.start == expectedStart)
        #expect(found.end == expectedStart + ("I keep avoiding it" as NSString).length)
        #expect((text as NSString).substring(with: found.range) == "I keep avoiding it")
        #expect(found.prefix == "Morning 🌧️. ")
        #expect(found.suffix == ", the call to Dad.")
    }

    @Test func missingAndEmptyQuotesFail() {
        let text = "Plain text."
        #expect(throws: AnnotationAnchoring.Failure.notFound) { try anchor("not here", in: text) }
        #expect(throws: AnnotationAnchoring.Failure.emptyQuote) { try anchor("  ", in: text) }
    }

    @Test func repeatedQuoteNeedsContext() throws {
        let text = "I'm tired. Work again. I'm tired. Home now."
        #expect(throws: AnnotationAnchoring.Failure.ambiguous(count: 2)) { try anchor("I'm tired", in: text) }
        let second = try anchor("I'm tired", suffix: "Home now", in: text)
        #expect(second.start == ("I'm tired. Work again. " as NSString).length)
        let first = try anchor("I'm tired", suffix: ". Work", in: text)
        #expect(first.start == 0)
    }

    @Test func looseMatchToleratesWhitespaceAndCurlyQuotes() throws {
        let text = "She said \u{201C}don\u{2019}t\nworry\u{201D} and left."
        let found = try anchor("\"don't worry\"", in: text)
        #expect(found.quote == "\u{201C}don\u{2019}t\nworry\u{201D}")
    }

    @Test func resolveFollowsTheQuoteAfterEditsBeforeIt() throws {
        let text = "One. The quiet part. Two."
        let found = try anchor("quiet part", in: text)
        let edited = "Zero. " + text
        let range = try #require(AnnotationAnchoring.resolve(found, in: edited))
        #expect((edited as NSString).substring(with: range) == "quiet part")
        #expect(AnnotationAnchoring.resolve(found, in: "One. Two.") == nil)
    }

    private func annotation(_ anchor: AnnotationAnchor, version: String = "v1", status: Annotation.Status = .active) -> Annotation {
        Annotation(id: UUID().uuidString, entryId: "E", versionId: version, reviewerId: "mirror", runId: "r",
                   anchor: anchor, comment: "c", kind: "observation", status: status, createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test func reanchorOrphansAndRevives() throws {
        let text = "Alpha beta gamma."
        let note = annotation(try anchor("beta", in: text))
        let orphaned = AnnotationAnchoring.reanchor([note], versionId: "v1", in: "Alpha gamma.")
        #expect(orphaned[0].status == .orphaned)
        let revived = AnnotationAnchoring.reanchor(orphaned, versionId: "v1", in: "Alpha, beta!")
        #expect(revived[0].status == .active)
        #expect(revived[0].anchor.start == 7)
        // Other versions and dismissed notes are left alone.
        let dismissed = annotation(note.anchor, status: .dismissed)
        let other = annotation(note.anchor, version: "v2")
        let untouched = AnnotationAnchoring.reanchor([dismissed, other], versionId: "v1", in: "nothing")
        #expect(untouched == [dismissed, other])
    }

    @Test func followEditKeepsTheRightRepeat() throws {
        let text = "tired. tired. tired."
        let middle = annotation(try anchor("tired", prefix: "tired. ", suffix: ". tired", in: text))
        #expect(middle.anchor.start == 7)
        let typed = "So tired. tired. tired."
        let moved = AnnotationAnchoring.followEdit([middle], versionId: "v1", from: text, to: typed)
        #expect(moved[0].anchor.start == 10)
        #expect(moved[0].status == .active)
        // Typing inside the quote changes it: no longer found there, nor anywhere else verbatim → the
        // nearest remaining "tired" with matching context wins, which is still a valid anchor.
        let broken = AnnotationAnchoring.followEdit([middle], versionId: "v1", from: text, to: "tired. tir-ed. tired.")
        #expect(broken[0].status == .active)
        #expect(broken[0].anchor.start != 7)
    }

    @Test func editRangeMatchesTextStorage() throws {
        let edit = try #require(AnnotationAnchoring.edit(from: "abcdef", to: "abXYZef"))
        #expect(edit.range == NSRange(location: 2, length: 3))
        #expect(edit.delta == 1)
        #expect(AnnotationAnchoring.edit(from: "same", to: "same") == nil)
    }
}

struct AnnotationStoreTests {
    private let entry = "[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04].md"

    private func makeStore(withEntry: Bool = true) throws -> AnnotationStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freewrite-annotations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let versions = EntryVersionStore(root: root)
        if withEntry {
            try "Text.".write(to: versions.entryFileURL(for: entry), atomically: true, encoding: .utf8)
        }
        return AnnotationStore(versionStore: versions)
    }

    @Test func jsonRoundTripAndShape() throws {
        let store = try makeStore()
        #expect(try store.load(for: entry).isEmpty)
        let note = Annotation(
            id: "A1", entryId: "6910BBDE-75FC-415C-ABB9-C76644B037B2", versionId: "v2", reviewerId: "coach",
            runId: "review:6910:v2:coach:1",
            anchor: AnnotationAnchor(quote: "I keep avoiding it", prefix: "before ", suffix: " after", start: 7, end: 25),
            comment: "Third time this week.", kind: "observation", status: .active,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        try store.save([note], for: entry)
        #expect(try store.load(for: entry) == [note])

        let url = store.fileURL(for: entry)
        #expect(url.path.hasSuffix("Entries/[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04]/annotations.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let anchor = try #require(json[0]["anchor"] as? [String: Any])
        #expect(anchor["quote"] as? String == "I keep avoiding it")
        #expect(anchor["start"] as? Int == 7)
        #expect(json[0]["status"] as? String == "active")
        #expect(json[0]["createdAt"] as? String == "2027-01-15T08:00:00Z")

        try store.save([], for: entry)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func corruptFileIsNotOverwritten() throws {
        let store = try makeStore()
        let url = store.fileURL(for: entry)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try store.update(for: entry) { $0.removeAll() } }
        #expect(try String(contentsOf: url, encoding: .utf8) == "not json")
    }

    @Test func summariesAreFoundPerVersion() throws {
        let store = try makeStore()
        try store.saveSummary("First look.", reviewerName: "Mirror", versionId: "v1", entryFilename: entry,
                              now: Date(timeIntervalSince1970: 100))
        try store.saveSummary("Second look.", reviewerName: "Mirror", versionId: "v1", entryFilename: entry,
                              now: Date(timeIntervalSince1970: 200))
        #expect(store.latestSummary(versionId: "v1", entryFilename: entry) == "Second look.")
        #expect(store.latestSummary(versionId: "v2", entryFilename: entry) == nil)
    }

    @Test func writesForAMissingEntryDontRecreateItsFolder() throws {
        let store = try makeStore(withEntry: false)
        let note = Annotation(
            id: "A1", entryId: "6910BBDE-75FC-415C-ABB9-C76644B037B2", versionId: "v1", reviewerId: "coach", runId: "r",
            anchor: AnnotationAnchor(quote: "Text", prefix: "", suffix: ".", start: 0, end: 4),
            comment: "Hi.", kind: "observation", status: .active, createdAt: Date())
        #expect(throws: AnnotationStore.Failure.entryMissing) { try store.save([note], for: entry) }
        #expect(throws: AnnotationStore.Failure.entryMissing) {
            try store.saveSummary("Late.", reviewerName: "Coach", versionId: "v1", entryFilename: entry)
        }
        #expect(!FileManager.default.fileExists(atPath: store.versionStore.entryDirectory(for: entry).path))
    }
}

struct ReviewToolboxTests {
    private let entry = "[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04].md"

    private func makeToolbox(text: String, reviewer: String = "mirror") throws -> ReviewToolbox {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freewrite-toolbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = EntryVersionStore(root: root)
        try text.write(to: store.entryFileURL(for: entry), atomically: true, encoding: .utf8)
        let run = ReviewRunContext(entryFilename: entry, entryId: "E", versionId: "v1", reviewerId: reviewer,
                                   reviewerName: reviewer.capitalized, runId: "review:E:v1:\(reviewer):1", scope: .latest)
        return ReviewToolbox(versionStore: store, run: run)
    }

    @Test func addAnnotationValidatesAndIsIdempotent() throws {
        let toolbox = try makeToolbox(text: "I keep avoiding it. Tomorrow, maybe.")
        let new = ReviewToolbox.NewAnnotation(quote: "avoiding it", comment: "You name it plainly.")
        _ = try toolbox.addAnnotation(new, id: "A1")
        _ = try toolbox.addAnnotation(new, id: "A1")  // replayed call
        let saved = try toolbox.annotations.load(for: entry)
        #expect(saved.count == 1)
        #expect(saved[0].anchor.start == 7 && saved[0].anchor.end == 18)
        #expect(saved[0].runId == "review:E:v1:mirror:1")

        let missing = ReviewToolbox.NewAnnotation(quote: "never written", comment: "x")
        #expect(throws: ReviewToolFailure.self) { try toolbox.addAnnotation(missing, id: "A2") }
        let unknownVersion = ReviewToolbox.NewAnnotation(versionId: "v9", quote: "avoiding", comment: "x")
        #expect(throws: ReviewToolFailure.self) { try toolbox.addAnnotation(unknownVersion, id: "A3") }
    }

    @Test func reviewersOnlyChangeTheirOwnNotes() throws {
        let mirror = try makeToolbox(text: "A line worth noting.")
        _ = try mirror.addAnnotation(.init(quote: "worth noting", comment: "Yes."), id: "M1")
        let coach = ReviewToolbox(versionStore: mirror.versionStore, run: ReviewRunContext(
            entryFilename: entry, entryId: "E", versionId: "v1", reviewerId: "coach", reviewerName: "Coach",
            runId: "review:E:v1:coach:1", scope: .latest))
        #expect(throws: ReviewToolFailure.self) { try coach.removeAnnotation(id: "M1") }
        _ = try mirror.updateAnnotation(id: "M1", comment: "Still yes.", kind: "praise")
        #expect(try mirror.annotations.load(for: entry).first?.comment == "Still yes.")
        _ = try mirror.removeAnnotation(id: "M1")
        #expect(try mirror.annotations.load(for: entry).isEmpty)
    }

    @Test func readVersionSlicesAndDiffShowsChanges() throws {
        let toolbox = try makeToolbox(text: "first line\nsecond line")
        let sealed = try toolbox.versionStore.sealCurrent(entryFilename: entry)
        #expect(sealed.current == "v2")
        try "first line\nchanged line".write(to: toolbox.versionStore.entryFileURL(for: entry), atomically: true, encoding: .utf8)
        let slice = try toolbox.readVersion("v1", start: 6, end: 10)
        #expect(slice.hasSuffix("---\nline"))
        let diff = try toolbox.diffVersions(from: "v1", to: "v2")
        #expect(diff.contains("- second line"))
        #expect(diff.contains("+ changed line"))
        #expect(diff.contains("  first line"))
        #expect(try toolbox.listVersions().contains("v2 ·"))
    }
}

struct ReviewerStoreTests {
    @Test func missingOrBrokenJSONGivesDefaults() {
        #expect(ReviewerStore.decode("") == ReviewerProfile.defaults)
        #expect(ReviewerStore.decode("{nope") == ReviewerProfile.defaults)
        #expect(ReviewerProfile.defaults.map(\.id) == ["mirror", "editor", "coach"])
    }

    @Test func roundTripKeepsEdits() {
        var profiles = ReviewerProfile.defaults
        profiles[0].model = "anthropic/claude-opus-5-5"
        profiles[0].thinkingLevel = "high"
        profiles.append(ReviewerProfile(name: "Custom", instructions: "Be brief.", color: .pink, autoRunOnNewVersion: true))
        #expect(ReviewerStore.decode(ReviewerStore.encode(profiles)) == profiles)
        #expect(ReviewerStore.decode("[]") == [])
    }
}
