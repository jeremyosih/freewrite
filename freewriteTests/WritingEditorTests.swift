//
//  WritingEditorTests.swift
//  freewriteTests
//

import Foundation
import Testing
@testable import freewrite

struct MarkdownStylerTests {
    private func spans(_ text: String) -> [MarkdownSpan] {
        MarkdownStyler.spans(in: text as NSString)
    }

    private func ranges(_ style: MarkdownStyle, in text: String) -> [String] {
        let string = text as NSString
        return spans(text).filter { $0.style == style }.map { string.substring(with: $0.range) }
    }

    @Test func headings() {
        let text = "# One\nplain\n### Three\n####### seven\n#nospace"
        #expect(ranges(.heading(1), in: text) == ["# One"])
        #expect(ranges(.heading(3), in: text) == ["### Three"])
        #expect(spans(text).filter { if case .heading = $0.style { true } else { false } }.count == 2)
        #expect(ranges(.syntax, in: text) == ["# ", "### "])
    }

    @Test func inlineStyles() {
        let text = "a **bold** and *it* and _it2_ and ~~gone~~ and `co*de*`"
        #expect(ranges(.bold, in: text) == ["**bold**"])
        #expect(ranges(.italic, in: text) == ["*it*", "_it2_"])
        #expect(ranges(.strikethrough, in: text) == ["~~gone~~"])
        #expect(ranges(.code, in: text) == ["`co*de*`"])
        #expect(ranges(.syntax, in: text) == ["`", "`", "**", "**", "*", "*", "_", "_", "~~", "~~"])
    }

    @Test func doesNotMatchWordsOrListMarkers() {
        let text = "* item\nsnake_case_name and 2 * 3 * 4"
        #expect(ranges(.italic, in: text).isEmpty)
        #expect(ranges(.listMarker, in: text) == ["*"])
    }

    @Test func blocks() {
        let text = "> quoted line\n- dash\n  12. numbered\n-nope"
        #expect(ranges(.quote, in: text) == ["> quoted line"])
        #expect(ranges(.listMarker, in: text) == ["-", "12."])
        #expect(ranges(.syntax, in: text) == ["> "])
    }

    @Test func links() {
        let text = "see [the site](https://example.com) now"
        #expect(ranges(.link, in: text) == ["the site"])
        #expect(ranges(.syntax, in: text) == ["[", "](https://example.com)"])
    }

    @Test func escapedPunctuationIsNotStyled() {
        #expect(ranges(.italic, in: #"\*literal\* and \_x\_"#).isEmpty)
        #expect(ranges(.bold, in: #"\**not bold**"#).isEmpty)
        #expect(ranges(.code, in: #"\`not code` here"#).isEmpty)
        #expect(ranges(.strikethrough, in: #"\~~kept~~"#).isEmpty)
        #expect(ranges(.link, in: #"\[label](url)"#).isEmpty)
        #expect(ranges(.syntax, in: #"\*literal\*"#).isEmpty)
        // An escaped delimiter inside emphasis is just text.
        #expect(ranges(.bold, in: #"**a \** b**"#) == [#"**a \** b**"#])
    }

    @Test func doubledBackslashesDoNotEscape() {
        // `\\` is an escaped backslash, so the `*` after it is a real delimiter.
        #expect(ranges(.italic, in: #"\\*it*"#) == ["*it*"])
        #expect(ranges(.code, in: #"\\`code`"#) == ["`code`"])
        // Three backslashes: an escaped backslash, then an escaped `*`.
        #expect(ranges(.italic, in: #"\\\*it*"#).isEmpty)
    }

    @Test func backslashesInsideCodeAreLiteral() {
        #expect(ranges(.code, in: #"`C:\` and `x`"#) == [#"`C:\`"#, "`x`"])
    }

    @Test func emphasisAroundInlineCode() {
        let text = "**before `code` after** and _see `x`_"
        #expect(ranges(.bold, in: text) == ["**before `code` after**"])
        #expect(ranges(.italic, in: text) == ["_see `x`_"])
        #expect(ranges(.code, in: text) == ["`code`", "`x`"])
        // Code is applied after emphasis so its font wins inside the code range only.
        let styles = spans(text).map(\.style)
        let lastEmphasis = styles.lastIndex { $0 == .bold || $0 == .italic }!
        let firstCode = styles.firstIndex(of: .code)!
        #expect(firstCode > lastEmphasis)
    }

    @Test func delimitersInsideCodeDoNotPair() {
        let text = "**a `**` b**"
        #expect(ranges(.bold, in: text) == ["**a `**` b**"])
        #expect(ranges(.code, in: text) == ["`**`"])
    }

    @Test func onlyStylesTouchedLines() {
        let text = "**a**\n**b**\n**c**" as NSString
        let middle = MarkdownStyler.spans(in: text, range: NSRange(location: 7, length: 0))
        #expect(middle.filter { $0.style == .bold }.map { text.substring(with: $0.range) } == ["**b**"])
    }

    @Test func utf16Ranges() {
        let text = "😀 **é**"
        #expect(ranges(.bold, in: text) == ["**é**"])
        #expect(spans(text).first { $0.style == .bold }?.range == NSRange(location: 3, length: 5))
    }
}

struct HighlightAdjustTests {
    private let range = NSRange(location: 10, length: 5)  // [10, 15)

    private func adjust(insert length: Int, at location: Int) -> NSRange? {
        EditorHighlight.adjust(range, for: NSRange(location: location, length: length), changeInLength: length)
    }

    private func adjust(delete length: Int, at location: Int) -> NSRange? {
        EditorHighlight.adjust(range, for: NSRange(location: location, length: 0), changeInLength: -length)
    }

    @Test func insertions() {
        #expect(adjust(insert: 3, at: 2) == NSRange(location: 13, length: 5))   // before
        #expect(adjust(insert: 3, at: 10) == NSRange(location: 13, length: 5))  // at start
        #expect(adjust(insert: 3, at: 12) == NSRange(location: 10, length: 8))  // inside
        #expect(adjust(insert: 3, at: 15) == NSRange(location: 10, length: 5))  // at end
        #expect(adjust(insert: 3, at: 20) == NSRange(location: 10, length: 5))  // after
    }

    @Test func deletions() {
        #expect(adjust(delete: 4, at: 2) == NSRange(location: 6, length: 5))    // before
        #expect(adjust(delete: 2, at: 11) == NSRange(location: 10, length: 3))  // inside
        #expect(adjust(delete: 4, at: 8) == NSRange(location: 8, length: 3))    // eats the head
        #expect(adjust(delete: 4, at: 13) == NSRange(location: 10, length: 3))  // eats the tail
        #expect(adjust(delete: 9, at: 8) == nil)                                // removes it
    }

    @Test func replacementAcrossStart() {
        // "abcd" at [8, 12) replaced by "XY": edited range is [8, 10), delta -2.
        let moved = EditorHighlight.adjust(range, for: NSRange(location: 8, length: 2), changeInLength: -2)
        #expect(moved == NSRange(location: 10, length: 3))
    }

    @Test func dropsRemovedHighlights() {
        let highlights = [
            EditorHighlight(id: "a", range: NSRange(location: 0, length: 3), color: .yellow, comment: ""),
            EditorHighlight(id: "b", range: NSRange(location: 10, length: 3), color: .yellow, comment: ""),
        ]
        let moved = EditorHighlight.adjust(highlights, for: NSRange(location: 0, length: 0), changeInLength: -4)
        #expect(moved.map(\.id) == ["b"])
        #expect(moved.first?.range == NSRange(location: 6, length: 3))
    }
}
