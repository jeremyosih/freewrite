//
//  TemplateTests.swift
//  freewriteTests
//

import Foundation
import Testing
@testable import freewrite

struct TemplateSearchTests {
    private let templates = [
        WritingTemplate(id: "a", name: "Morning pages", body: ""),
        WritingTemplate(id: "b", name: "Gratitude", body: ""),
        WritingTemplate(id: "c", name: "Daily review", body: ""),
        WritingTemplate(id: "d", name: "Meeting notes", body: ""),
        WritingTemplate(id: "e", name: "Résumé draft", body: ""),
    ]

    private func names(_ query: String) -> [String] {
        TemplateSearch.results(for: query, in: templates).map(\.name)
    }

    @Test func emptyQueryKeepsTheUsersOrder() {
        #expect(names("") == templates.map(\.name))
        #expect(names("  ") == templates.map(\.name))
    }

    @Test func prefixBeforeWordStartBeforeSubstringBeforeAbbreviation() {
        #expect(names("m") == ["Morning pages", "Meeting notes", "Résumé draft"])
        #expect(names("re") == ["Résumé draft", "Daily review"])
        #expect(names("view") == ["Daily review"])
        #expect(names("mn") == ["Meeting notes"])
        #expect(names("dr") == ["Résumé draft", "Daily review"])
    }

    @Test func ignoresCaseAndDiacritics() {
        #expect(names("RESUME") == ["Résumé draft"])
        #expect(names("gRaT") == ["Gratitude"])
    }

    @Test func multiWordQueries() {
        #expect(names("meeting no") == ["Meeting notes"])
        #expect(names("pages x").isEmpty)
    }

    @Test func untitledTemplatesMatchTheirDisplayName() {
        let list = [WritingTemplate(id: "x", name: "  ", body: "")]
        #expect(TemplateSearch.results(for: "unt", in: list).map(\.id) == ["x"])
    }
}

struct TemplateExpanderTests {
    private let date = DateComponents(
        calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
        year: 2026, month: 10, day: 27, hour: 8, minute: 51
    ).date!
    private let locale = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!

    @Test func expandsDateAndTime() {
        let result = TemplateExpander.expand("{{date}} at {{time}}", date: date, locale: locale, timeZone: utc)
        #expect(result.text.hasPrefix("Tuesday, October 27, 2026 at 8:51"))
        #expect(result.text.hasSuffix("AM"))
        #expect(result.caret == result.text.utf16.count)
    }

    @Test func cursorMarksTheCaretAndIsRemoved() {
        let result = TemplateExpander.expand("# Title\n\n{{cursor}}\n\nend", date: date, locale: locale, timeZone: utc)
        #expect(result.text == "# Title\n\n\n\nend")
        #expect(result.caret == 9)
    }

    @Test func caretIsInUTF16AfterExpansionAndExtraCursorsAreDropped() {
        let result = TemplateExpander.expand("😀 {{date}}: {{cursor}}x{{cursor}}", date: date, locale: locale, timeZone: utc)
        #expect(result.text == "😀 Tuesday, October 27, 2026: x")
        #expect(result.caret == ("😀 Tuesday, October 27, 2026: " as NSString).length)
    }

    @Test func unknownPlaceholdersStay() {
        #expect(TemplateExpander.expand("{{name}}").text == "{{name}}")
    }
}

struct TemplateStoreTests {
    @Test func missingOrBrokenValueMeansDefaults() {
        #expect(TemplateStore.decode("") == WritingTemplate.defaults)
        #expect(TemplateStore.decode("not json") == WritingTemplate.defaults)
        #expect(WritingTemplate.defaults.map(\.name) == ["Morning pages", "Gratitude", "Daily review", "Meeting notes"])
    }

    @Test func roundTripsOrderAndAnEmptyList() {
        let list = [WritingTemplate(id: "2", name: "B", body: "b"), WritingTemplate(id: "1", name: "A", body: "a\n{{date}}")]
        #expect(TemplateStore.decode(TemplateStore.encode(list)) == list)
        // Deleting every template is kept, not replaced by the defaults.
        #expect(TemplateStore.decode(TemplateStore.encode([])).isEmpty)
    }

    @Test func previewSkipsMarkdownMarkers() {
        #expect(WritingTemplate(name: "x", body: "\n\n## Daily review · {{date}}\n").preview == "Daily review · {{date}}")
        #expect(WritingTemplate(name: "x", body: "").preview == "")
    }

    @Test func defaultsKeepTheCaretInsideTheTemplate() {
        for template in WritingTemplate.defaults {
            #expect(template.body.contains("{{cursor}}"), "\(template.name)")
        }
    }
}

struct SlashTriggerTests {
    @Test func opensAtLineStartOrAfterWhitespaceOnly() {
        let string = "hi and/or\n x" as NSString
        #expect(SlashTrigger.opens(at: 0, in: string))
        #expect(SlashTrigger.opens(at: 3, in: string))      // after a space
        #expect(!SlashTrigger.opens(at: 6, in: string))     // "and|/or"
        #expect(SlashTrigger.opens(at: 10, in: string))     // after a newline
        #expect(SlashTrigger.opens(at: 11, in: string))     // after a space on the next line
        #expect(!SlashTrigger.opens(at: 20, in: string))
    }

    @Test func queryIsTheTextBetweenSlashAndCaret() {
        let string = "x /meet more" as NSString
        #expect(SlashTrigger.query(in: string, slashAt: 2, queryStart: 3, caret: NSRange(location: 7, length: 0)) == "meet")
        #expect(SlashTrigger.query(in: string, slashAt: 2, queryStart: 3, caret: NSRange(location: 3, length: 0)) == "")
        #expect(SlashTrigger.query(in: string, slashAt: 2, queryStart: 3, caret: NSRange(location: 12, length: 0)) == "meet more")
    }

    @Test func closesWhenTheCaretLeavesOrTheSlashIsGone() {
        let string = "x /meet" as NSString
        #expect(SlashTrigger.query(in: string, slashAt: 2, queryStart: 3, caret: NSRange(location: 2, length: 0)) == nil)
        #expect(SlashTrigger.query(in: string, slashAt: 2, queryStart: 3, caret: NSRange(location: 4, length: 2)) == nil)
        #expect(SlashTrigger.query(in: "x meet" as NSString, slashAt: 2, queryStart: 3, caret: NSRange(location: 5, length: 0)) == nil)
        #expect(SlashTrigger.query(in: "/a\nb" as NSString, slashAt: 0, queryStart: 1, caret: NSRange(location: 4, length: 0)) == nil)
        let long = ("/" + String(repeating: "a", count: SlashTrigger.maxQueryLength + 1)) as NSString
        #expect(SlashTrigger.query(in: long, slashAt: 0, queryStart: 1, caret: NSRange(location: long.length, length: 0)) == nil)
    }

    @Test func withoutASlashTheQueryStartsAtTheCaret() {
        let string = "hello gra" as NSString
        #expect(SlashTrigger.query(in: string, slashAt: nil, queryStart: 6, caret: NSRange(location: 9, length: 0)) == "gra")
    }

    @Test func whitespaceWithNoMatchesCloses() {
        #expect(SlashTrigger.shouldClose(query: "or ", resultCount: 0))
        #expect(!SlashTrigger.shouldClose(query: "meeting ", resultCount: 1))
        #expect(!SlashTrigger.shouldClose(query: "zzz", resultCount: 0))
    }
}
