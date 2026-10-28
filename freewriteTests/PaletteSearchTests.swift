//
//  PaletteSearchTests.swift
//  freewriteTests
//

import Foundation
import Testing
@testable import freewrite

struct PaletteSearchTests {
    private func document(_ body: String, version: String? = nil, id: UUID = UUID()) -> PaletteDocument {
        PaletteDocument(id: id, date: "Oct 27", isVideo: false, body: body, version: version)
    }

    private func titles(_ items: [PaletteItem]) -> [String] {
        items.map(PaletteSearch.title(for:))
    }

    @Test func emptyQueryListsRecentCurrentEntriesThenEveryAction() {
        let entries = (0..<10).map { document("Entry \($0)") } + [document("Old draft", version: "v1")]
        let results = PaletteSearch.results(for: "  ", in: PaletteIndex(entries))
        #expect(titles(Array(results.prefix(8))) == (0..<8).map { "Entry \($0)" })
        let actions = results.dropFirst(8)
        #expect(actions.count == AppCommand.allCases.count + 1) // every command but the palette, Agents…, Settings
        #expect(!actions.contains { $0.id == "command-commandPalette" })
        #expect(actions.last?.id == "settings")
    }

    @Test func matchingIgnoresCaseAndDiacritics() {
        let index = PaletteIndex([document("Le café était fermé"), document("Nothing here")])
        #expect(titles(PaletteSearch.entries(index, query: "CAFE")) == ["Le café était fermé"])
        #expect(titles(PaletteSearch.entries(index, query: "Étáit")) == ["Le café était fermé"])
    }

    @Test func everyTermMustMatch() {
        let index = PaletteIndex([document("apples and pears"), document("apples only"), document("pears only")])
        #expect(titles(PaletteSearch.entries(index, query: "pears apples")) == ["apples and pears"])
    }

    @Test func titleHitsComeFirstAndKeepNewestFirstOrder() {
        let index = PaletteIndex([
            document("Morning\nthe garden was quiet"),
            document("Garden plans"),
            document("Evening\nback in the garden"),
            document("Garden again"),
        ])
        let results = PaletteSearch.entries(index, query: "garden")
        #expect(titles(results) == ["Garden plans", "Garden again", "Morning", "Evening"])
        guard case .entry(_, let titleSnippet) = results[0], case .entry(_, let bodySnippet) = results[2] else {
            Issue.record("expected entries"); return
        }
        #expect(titleSnippet == nil)
        #expect(bodySnippet == "Morning the garden was quiet")
    }

    @Test func snippetTrimsLongBodiesAroundTheFirstTerm() {
        let body = String(repeating: "a ", count: 50) + "needle" + String(repeating: " b", count: 50)
        let snippet = PaletteSearch.snippet(in: body, around: "NEEDLE")
        #expect(snippet?.hasPrefix("…") == true)
        #expect(snippet?.hasSuffix("…") == true)
        #expect(snippet?.contains("needle") == true)
    }

    @Test func sealedVersionsOnlyShowWhenSearching() {
        let id = UUID()
        let index = PaletteIndex([document("current text", id: id), document("first draft text", version: "v1", id: id)])
        #expect(PaletteSearch.entries(index, query: "").count == 1)
        let hits = PaletteSearch.entries(index, query: "draft")
        #expect(hits.map(\.id) == ["entry-\(id.uuidString)-v1"])
    }

    @Test func entryResultsAreCapped() {
        let index = PaletteIndex((0..<80).map { document("note \($0)") })
        #expect(PaletteSearch.entries(index, query: "note").count == PaletteSearch.maxEntries)
    }

    @Test func actionsMatchBySubstringThenWordStarts() {
        #expect(titles(PaletteSearch.commands(query: "version")) == ["New Version"])
        #expect(titles(PaletteSearch.commands(query: "nv")) == ["New Version"])
        #expect(titles(PaletteSearch.commands(query: "rec vid")) == ["Record Video"])
        #expect(titles(PaletteSearch.commands(query: "SETT")) == ["Settings…"])
        // Scattered letters that don't start words don't match.
        #expect(PaletteSearch.commands(query: "the").isEmpty)
    }

    @Test func queriesShowAtMostFourActionsBeforeEntries() {
        let index = PaletteIndex([document("Record of the day")])
        let results = PaletteSearch.results(for: "record", in: index)
        #expect(titles(results) == ["Record Video", "Record Voice Note", "Record of the day"])
        let many = PaletteSearch.results(for: "e", in: PaletteIndex([]))
        #expect(many.count == 4)
    }

    @Test func reviewersCanBeRunFromThePalette() {
        let actions = PaletteReviewActions(
            versionId: "v2",
            reviewers: [.init(id: "editor", name: "Editor"), .init(id: "mirror", name: "Mirror")],
            noteCount: 3
        )
        let index = PaletteIndex([document("Editorial thoughts")], reviewActions: actions)
        #expect(titles(PaletteSearch.results(for: "ask an agent", in: index)) == ["Ask an Agent…", "Ask an Agent: Editor", "Ask an Agent: Mirror"])
        #expect(titles(PaletteSearch.results(for: "aaam", in: index)).first == "Ask an Agent: Mirror")
        #expect(titles(PaletteSearch.results(for: "clear", in: index)) == ["Clear Review (3 notes)"])
        let empty = titles(PaletteSearch.results(for: "", in: index))
        #expect(empty.contains("Ask an Agent: Editor") && empty.contains("Agents…"))
    }

    @Test func noReviewersWithoutSomethingToReview() {
        let titles = titles(PaletteSearch.results(for: "review", in: PaletteIndex([])))
        #expect(!titles.contains { $0.hasPrefix("Ask an Agent: ") || $0.hasPrefix("Clear Review") })
        #expect(titles.contains("Agents…"))
    }

    @Test func cancelledSearchStopsEarly() async {
        let index = PaletteIndex((0..<1_000).map { document("note \($0)") })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return PaletteSearch.entries(index, query: "note")
        }
        #expect(await task.value.isEmpty)
    }
}
