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
        #expect(revived[0].anchor?.start == 7)
        // Other versions and dismissed notes are left alone.
        let dismissed = annotation(try #require(note.anchor), status: .dismissed)
        let other = annotation(try #require(note.anchor), version: "v2")
        let untouched = AnnotationAnchoring.reanchor([dismissed, other], versionId: "v1", in: "nothing")
        #expect(untouched == [dismissed, other])
    }

    @Test func followEditKeepsTheRightRepeat() throws {
        let text = "tired. tired. tired."
        let middle = annotation(try anchor("tired", prefix: "tired. ", suffix: ". tired", in: text))
        #expect(middle.anchor?.start == 7)
        let typed = "So tired. tired. tired."
        let moved = AnnotationAnchoring.followEdit([middle], versionId: "v1", from: text, to: typed)
        #expect(moved[0].anchor?.start == 10)
        #expect(moved[0].status == .active)
        // Typing inside the quote changes it: no longer found there, nor anywhere else verbatim → the
        // nearest remaining "tired" with matching context wins, which is still a valid anchor.
        let broken = AnnotationAnchoring.followEdit([middle], versionId: "v1", from: text, to: "tired. tir-ed. tired.")
        #expect(broken[0].status == .active)
        #expect(broken[0].anchor?.start != 7)
    }

    @Test func resolvedNotesKeepTheirStatusAndFollowTheText() throws {
        let text = "Alpha beta gamma."
        var note = annotation(try anchor("beta", in: text))
        note.resolve(.init(by: .user, at: Date(timeIntervalSince1970: 1)))
        let moved = AnnotationAnchoring.followEdit([note], versionId: "v1", from: text, to: "Oh. " + text)
        #expect(moved[0].status == .resolved)
        #expect(moved[0].anchor?.start == 10)
        // Its quote gone, a resolved note stays resolved (it isn't orphaned).
        #expect(AnnotationAnchoring.reanchor([note], versionId: "v1", in: "Alpha gamma.")[0].status == .resolved)
        // Page notes have nothing to anchor.
        let page = Annotation(id: "P", entryId: "E", versionId: "v1", reviewerId: "mirror", runId: "r",
                              anchor: nil, comment: "c", kind: "insight", status: .active, createdAt: Date())
        #expect(AnnotationAnchoring.reanchor([page], versionId: "v1", in: "") == [page])
        #expect(AnnotationAnchoring.followEdit([page], versionId: "v1", from: "a", to: "ab") == [page])
    }

    @Test func statusTransitions() throws {
        var note = annotation(try anchor("beta", in: "Alpha beta."))
        // Applies a status change to `note`, returning whether it changed anything.
        func change(_ body: (inout Annotation) -> Bool) -> Bool { body(&note) }
        let byUser = Annotation.Resolution(by: .user, at: Date(timeIntervalSince1970: 5))
        #expect(change { $0.resolve(byUser) })
        #expect(note.status == .resolved && note.resolution == byUser)
        #expect(!change { $0.resolve(byUser) })  // already resolved
        #expect(change { $0.reopen() })
        #expect(note.status == .active && note.resolution == nil)
        #expect(!change { $0.reopen() })  // only resolved notes reopen
        note.status = .orphaned
        #expect(change { $0.resolve(byUser) })  // an orphan can be resolved
        #expect(change { $0.dismiss() })
        #expect(!change { $0.dismiss() })
        #expect(!change { $0.resolve(byUser) })  // dismissed notes stay dismissed
        #expect(!note.isOpen)
    }

    @Test func mergingMovedAnchorsKeepsStatusesSetMeanwhile() throws {
        let text = "Alpha beta gamma."
        let typed = annotation(try anchor("beta", in: text))
        var moved = typed
        moved.anchor?.start = 9
        moved.anchor?.end = 13
        // A review resolved the note while the editor's moved anchors were waiting to be saved.
        var stored = [typed]
        stored[0].resolve(.init(by: .reviewer, reviewerId: "mirror", runId: "r2", reason: "fixed", at: Date()))
        AnnotationAnchoring.mergeAnchors([moved], into: &stored)
        #expect(stored[0].status == .resolved)
        #expect(stored[0].anchor?.start == 9)
        // Open notes take the editor's status (orphaned while its quote is gone).
        var orphan = moved
        orphan.status = .orphaned
        var open = [typed]
        AnnotationAnchoring.mergeAnchors([orphan], into: &open)
        #expect(open[0].status == .orphaned)
        // Dismissed notes aren't touched at all.
        var dismissed = [typed]
        dismissed[0].dismiss()
        let before = dismissed
        AnnotationAnchoring.mergeAnchors([moved], into: &dismissed)
        #expect(dismissed == before)
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

    @Test func olderFilesDecodeAndPageNotesRoundTrip() throws {
        let store = try makeStore()
        let url = store.fileURL(for: entry)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Written before resolve and page notes existed, plus a status from some future version.
        let old = """
        [{"id":"A1","entryId":"E","versionId":"v1","reviewerId":"coach","runId":"r",
          "anchor":{"quote":"Text","prefix":"","suffix":".","start":0,"end":4},
          "comment":"Hi.","kind":"observation","status":"dismissed","createdAt":"2026-02-20T08:00:00Z"},
         {"id":"A2","entryId":"E","versionId":"v1","reviewerId":"coach","runId":"r",
          "anchor":{"quote":"Text","prefix":"","suffix":".","start":0,"end":4},
          "comment":"Later.","status":"snoozed","createdAt":"2026-02-20T08:00:00Z"}]
        """
        try old.write(to: url, atomically: true, encoding: .utf8)
        let loaded = try store.load(for: entry)
        #expect(loaded.map(\.status) == [.dismissed, .active])
        #expect(loaded[1].kind == "insight")
        #expect(loaded.allSatisfy { $0.resolution == nil && !$0.isPageNote })

        var page = Annotation(id: "P1", entryId: "E", versionId: "v1", reviewerId: "coach", runId: "r2",
                              anchor: nil, comment: "The ending lands.", kind: "praise", status: .active,
                              createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        page.resolve(.init(by: .reviewer, reviewerId: "coach", runId: "r3", reason: "kept in v2", at: Date(timeIntervalSince1970: 1_800_000_100)))
        try store.save([page], for: entry)
        #expect(try store.load(for: entry) == [page])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        #expect(json[0]["anchor"] == nil)
        #expect(json[0]["status"] as? String == "resolved")
        let resolution = try #require(json[0]["resolution"] as? [String: Any])
        #expect(resolution["by"] as? String == "reviewer")
        #expect(resolution["reason"] as? String == "kept in v2")
        #expect(resolution["at"] as? String == "2027-01-15T08:01:40Z")
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
        try store.saveSummary("Shorter now.", reviewerName: "Line Editor", versionId: "v2", entryFilename: entry,
                              now: Date(timeIntervalSince1970: 300))
        let latest = store.latestReviews(entryFilename: entry)
        #expect(latest["v2"] == .init(reviewerName: "Line Editor", summary: "Shorter now."))
        #expect(latest["v1"]?.summary == "Second look.")
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
        #expect(saved[0].anchor?.start == 7 && saved[0].anchor?.end == 18)
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

    @Test func pageNotesNeedACommentAndAKnownVersion() throws {
        let toolbox = try makeToolbox(text: "A page.")
        let result = try toolbox.addPageNote(.init(comment: "Try writing the ending first.", kind: "question"), id: "P1")
        #expect(result.contains("page note P1"))
        _ = try toolbox.addPageNote(.init(comment: "Try writing the ending first."), id: "P1")  // replayed
        let saved = try toolbox.annotations.load(for: entry)
        #expect(saved.count == 1)
        #expect(saved[0].isPageNote && saved[0].kind == "question" && saved[0].status == .active)
        #expect(throws: ReviewToolFailure.self) { try toolbox.addPageNote(.init(comment: "  "), id: "P2") }
        #expect(throws: ReviewToolFailure.self) { try toolbox.addPageNote(.init(versionId: "v7", comment: "x"), id: "P3") }
        #expect(try toolbox.listAnnotations(versionId: nil).contains("page note"))
    }

    @Test func resolvingFollowsTheRules() throws {
        let first = try makeToolbox(text: "I keep avoding it.")
        _ = try first.addAnnotation(.init(quote: "avoding", comment: "Typo: avoiding.", kind: "grammar"), id: "M1")
        _ = try first.addAnnotation(.init(quote: "I keep", comment: "Unwanted."), id: "M2")
        try first.annotations.update(for: entry) { $0[1].dismiss() }
        let coachRun = ReviewRunContext(entryFilename: entry, entryId: "E", versionId: "v1", reviewerId: "coach",
                                        reviewerName: "Coach", runId: "review:E:v1:coach:1", scope: .latest)
        let coach = ReviewToolbox(versionStore: first.versionStore, run: coachRun)
        _ = try coach.addAnnotation(.init(quote: "it", comment: "Which it?"), id: "C1")

        // Same run: notes it just added are removed, not resolved.
        #expect(throws: ReviewToolFailure.self) { try first.resolveAnnotation(id: "M1", reason: "fixed") }

        // A later run of the same reviewer.
        var laterRun = first.run
        laterRun.runId = "review:E:v1:mirror:2"
        let later = ReviewToolbox(versionStore: first.versionStore, run: laterRun, now: { Date(timeIntervalSince1970: 42) })
        let brief = later.brief()
        #expect(brief.contains("<earlier_notes>") && brief.contains("M1") && brief.contains("C1"))
        #expect(brief.contains("You have 1 open note(s) to check."))
        #expect(throws: ReviewToolFailure.self) { try later.resolveAnnotation(id: "M1", reason: "  ") }
        #expect(throws: ReviewToolFailure.self) { try later.resolveAnnotation(id: "C1", reason: "answered") }  // not theirs
        #expect(throws: ReviewToolFailure.self) { try later.resolveAnnotation(id: "M2", reason: "x") }  // dismissed
        #expect(throws: ReviewToolFailure.self) { try later.resolveAnnotation(id: "nope", reason: "x") }
        #expect(try later.resolveAnnotation(id: "M1", reason: "fixed the typo") == "Resolved M1.")
        #expect(try later.resolveAnnotation(id: "M1", reason: "again") == "M1 is already resolved.")
        let note = try #require(try later.annotations.load(for: entry).first { $0.id == "M1" })
        #expect(note.status == .resolved)
        #expect(note.resolution == .init(by: .reviewer, reviewerId: "mirror", runId: "review:E:v1:mirror:2",
                                          reason: "fixed the typo", at: Date(timeIntervalSince1970: 42)))
        #expect(try later.listAnnotations(versionId: "v1").contains("resolved by reviewer mirror: fixed the typo"))
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

struct PromptStoreTests {
    @Test func missingOrBrokenJSONGivesDefaults() {
        #expect(PromptStore.decode("") == AgentPrompt.defaults)
        #expect(PromptStore.decode("{nope") == AgentPrompt.defaults)
        #expect(AgentPrompt.defaults.map(\.id) == ["friend", "mentor", "editor"])
    }

    @Test func roundTripKeepsEdits() {
        var prompts = AgentPrompt.defaults
        prompts[0].prompt = "Be brief."
        prompts.append(AgentPrompt(name: "Custom", prompt: "Ask me one question."))
        #expect(PromptStore.decode(PromptStore.encode(prompts)) == prompts)
        #expect(PromptStore.decode("[]") == [])
    }

    @Test func oldAgentFieldsAreIgnored() throws {
        let json = """
        [{"id":"editor","name":"Editor","prompt":"x","model":"openai/gpt-5.5","instructions":"old"},{"id":"bare","name":"Bare"}]
        """
        let prompts = try JSONDecoder().decode([AgentPrompt].self, from: Data(json.utf8))
        #expect(prompts == [AgentPrompt(id: "editor", name: "Editor", prompt: "x"), AgentPrompt(id: "bare", name: "Bare", prompt: "")])
    }

    @Test func mcpNamesAreUniqueSlugs() {
        let prompts = [
            AgentPrompt(name: "Mentor", prompt: ""), AgentPrompt(name: "My Editor!", prompt: ""),
            AgentPrompt(name: "mentor", prompt: ""), AgentPrompt(name: "  ", prompt: ""),
        ]
        #expect(PromptStore.named(prompts).map(\.name) == ["mentor", "my-editor", "mentor-2", "prompt"])
    }
}

struct FreewriteLinkTests {
    private let id = UUID(uuidString: "6910BBDE-75FC-415C-ABB9-C76644B037B2")!

    @Test func parsesBothForms() throws {
        let app = try #require(FreewriteLink(url: URL(string: "freewrite://e/\(id.uuidString)/v2/n/an_1")!))
        #expect(app == FreewriteLink(entryId: id, versionId: "v2", noteId: "an_1"))
        let web = try #require(FreewriteLink(url: URL(string: "http://127.0.0.1:29890/e/\(id.uuidString)?q=a%20%26%20b&p=x")!))
        #expect(web == FreewriteLink(entryId: id, quote: "a & b", prefix: "x"))
        #expect(FreewriteLink(url: URL(string: "freewrite://e/not-a-uuid")!) == nil)
        #expect(FreewriteLink(url: URL(string: "http://127.0.0.1:29890/x")!) == nil)
    }

    @Test func roundTripsThroughItsURLs() throws {
        let link = FreewriteLink(entryId: id, versionId: "v3", quote: "1 + 1 = 2 & more?", suffix: "!")
        #expect(FreewriteLink(url: try #require(URL(string: link.appURL))) == link)
        #expect(FreewriteLink(url: try #require(URL(string: link.webURL))) == link)
    }

    @Test func picksTheOccurrenceWithMatchingContext() {
        let text = "I was tired. Then work. I was tired again."
        let range = FreewriteLink.range(of: "I was tired", prefix: "work. ", suffix: nil, in: text)
        #expect(range == NSRange(location: 24, length: 11))
        #expect(FreewriteLink.range(of: "i WAS tired", prefix: nil, suffix: nil, in: text) == NSRange(location: 0, length: 11))
        #expect(FreewriteLink.range(of: "absent", prefix: nil, suffix: nil, in: text) == nil)
    }
}
