//
//  MarkdownStyling.swift
//  freewrite
//
//  Pure logic behind the writing editor: which ranges of a
//  markdown string get which style, and how highlight ranges move when the
//  text is edited. Everything works in UTF-16 `NSRange`s so it lines up with
//  NSTextStorage and NSTextView.
//

import AppKit

enum MarkdownStyle: Equatable, Sendable {
    case heading(Int)       // 1...6
    case bold
    case italic
    case code
    case quote
    case listMarker
    case strikethrough
    case link
    case syntax             // markdown punctuation (`#`, `**`, `` ` ``, `](url)`…), drawn dimmed
}

struct MarkdownSpan: Equatable, Sendable {
    let style: MarkdownStyle
    let range: NSRange
}

enum MarkdownStyler {
    private static let heading = regex(#"^(#{1,6}[ \t]+)(?=\S)[^\n]*"#)
    private static let quote = regex(#"^(>[ \t]?)[^\n]*"#)
    private static let listMarker = regex(#"^[ \t]*([-*+]|\d{1,9}[.)])(?=[ \t])"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)(?:.+?)(?<=\S)\1"#)
    private static let starItalic = regex(#"(?<![*\w])\*(?=[^\s*])(?:.+?)(?<=[^\s*])\*(?![*\w])"#)
    private static let underscoreItalic = regex(#"(?<![_\w])_(?=[^\s_])(?:.+?)(?<=[^\s_])_(?![_\w])"#)
    private static let strikethrough = regex(#"~~(?=\S)(?:.+?)(?<=\S)~~"#)
    private static let link = regex(#"\[([^\]\n]+)\]\(([^)\s]+)\)"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are literals; a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    /// Spans for the whole lines covered by `range`, in application order:
    /// block styles, then inline styles, then `.syntax` last so markers stay dimmed.
    static func spans(in string: NSString, range: NSRange? = nil) -> [MarkdownSpan] {
        let target = string.paragraphRange(for: range ?? NSRange(location: 0, length: string.length))
        guard target.length > 0 else { return [] }

        var spans: [MarkdownSpan] = []
        var syntax: [NSRange] = []

        heading.enumerateMatches(in: string as String, range: target) { match, _, _ in
            guard let match else { return }
            let marker = match.range(at: 1)
            let level = string.substring(with: marker).filter { $0 == "#" }.count
            spans.append(MarkdownSpan(style: .heading(level), range: match.range))
            syntax.append(marker)
        }
        quote.enumerateMatches(in: string as String, range: target) { match, _, _ in
            guard let match else { return }
            spans.append(MarkdownSpan(style: .quote, range: match.range))
            syntax.append(match.range(at: 1))
        }
        listMarker.enumerateMatches(in: string as String, range: target) { match, _, _ in
            guard let match else { return }
            spans.append(MarkdownSpan(style: .listMarker, range: match.range(at: 1)))
        }

        // Inline patterns run on a copy of the lines where code spans and backslash escapes are
        // blanked out: `\*` or a `**` inside code can't open or close emphasis, while emphasis
        // around code (`**a `code` b**`) still matches. Ranges line up because blanking keeps lengths.
        let scan = scanInline(string, in: target)
        for code in scan.code {
            syntax.append(contentsOf: delimiters(of: code, width: 1))
        }
        let inline = scan.masked as String
        func shifted(_ range: NSRange) -> NSRange {
            NSRange(location: range.location + target.location, length: range.length)
        }
        let inlineRange = NSRange(location: 0, length: scan.masked.length)

        let delimited: [(NSRegularExpression, MarkdownStyle, Int)] = [
            (bold, .bold, 2),
            (starItalic, .italic, 1),
            (underscoreItalic, .italic, 1),
            (strikethrough, .strikethrough, 2),
        ]
        for (expression, style, width) in delimited {
            expression.enumerateMatches(in: inline, range: inlineRange) { match, _, _ in
                guard let match else { return }
                let range = shifted(match.range)
                spans.append(MarkdownSpan(style: style, range: range))
                syntax.append(contentsOf: delimiters(of: range, width: width))
            }
        }

        link.enumerateMatches(in: inline, range: inlineRange) { match, _, _ in
            guard let match else { return }
            let whole = shifted(match.range)
            let label = shifted(match.range(at: 1))
            spans.append(MarkdownSpan(style: .link, range: label))
            syntax.append(NSRange(location: whole.location, length: 1))  // [
            let tail = NSMaxRange(label)
            syntax.append(NSRange(location: tail, length: NSMaxRange(whole) - tail))  // ](url)
        }

        // Code after emphasis so its font wins inside the code range only.
        spans.append(contentsOf: scan.code.map { MarkdownSpan(style: .code, range: $0) })

        spans.append(contentsOf: syntax.map { MarkdownSpan(style: .syntax, range: $0) })
        return spans
    }

    private static let backslash = UInt16(UInt8(ascii: "\\"))
    private static let backtick = UInt16(UInt8(ascii: "`"))
    private static let newline = UInt16(UInt8(ascii: "\n"))
    /// Stand-in for blanked characters: not whitespace, not a word character, not a delimiter.
    private static let blank = "\u{1}"

    /// Code spans in `target` (absolute ranges) and a copy of `target` with code spans and
    /// backslash escapes blanked out. A backslash escapes the ASCII punctuation after it
    /// (including another backslash); escapes don't apply inside code spans.
    static func scanInline(_ string: NSString, in target: NSRange) -> (code: [NSRange], masked: NSString) {
        let masked = NSMutableString(string: string.substring(with: target))
        let length = masked.length
        var code: [NSRange] = []
        var blanked: [NSRange] = []
        var i = 0
        while i < length {
            let character = masked.character(at: i)
            if character == backslash, i + 1 < length, isASCIIPunctuation(masked.character(at: i + 1)) {
                blanked.append(NSRange(location: i, length: 2))
                i += 2
                continue
            }
            if character == backtick {
                var end = i + 1
                while end < length, masked.character(at: end) != backtick, masked.character(at: end) != newline {
                    end += 1
                }
                if end < length, masked.character(at: end) == backtick, end > i + 1 {
                    let span = NSRange(location: i, length: end + 1 - i)
                    code.append(NSRange(location: span.location + target.location, length: span.length))
                    blanked.append(span)
                    i = end + 1
                    continue
                }
            }
            i += 1
        }
        for range in blanked {
            masked.replaceCharacters(in: range, with: String(repeating: blank, count: range.length))
        }
        return (code, masked)
    }

    private static func isASCIIPunctuation(_ character: UInt16) -> Bool {
        (0x21...0x2F).contains(character) || (0x3A...0x40).contains(character)
            || (0x5B...0x60).contains(character) || (0x7B...0x7E).contains(character)
    }

    private static func delimiters(of range: NSRange, width: Int) -> [NSRange] {
        [
            NSRange(location: range.location, length: width),
            NSRange(location: NSMaxRange(range) - width, length: width),
        ]
    }
}

// MARK: - Highlights

/// A range of the editor's text to tint, with a comment shown on hover.
/// `range` is in UTF-16 units of the editor's string.
struct EditorHighlight: Identifiable, Equatable {
    let id: String
    var range: NSRange
    let color: NSColor
    let comment: String
}

extension EditorHighlight {
    /// Moves `range` to follow an edit. `editedRange` is the range of the new text
    /// (as reported by NSTextStorage) and `changeInLength` its length delta.
    /// Text inserted strictly inside the range grows it; text inserted at either
    /// edge stays outside. Returns nil when the edit removed the whole range.
    static func adjust(_ range: NSRange, for editedRange: NSRange, changeInLength delta: Int) -> NSRange? {
        let editStart = editedRange.location
        let oldEditEnd = editStart + editedRange.length - delta
        let newEditEnd = NSMaxRange(editedRange)
        let start = range.location
        let end = NSMaxRange(range)

        if oldEditEnd <= start {
            // Entirely before (or touching the start): shift.
            return NSRange(location: start + delta, length: range.length)
        }
        if editStart >= end {
            // Entirely after (or touching the end): untouched.
            return range
        }
        if editStart <= start && oldEditEnd >= end {
            return nil
        }
        if editStart <= start {
            // Edit eats the head of the range.
            return NSRange(location: newEditEnd, length: end + delta - newEditEnd)
        }
        if oldEditEnd >= end {
            // Edit eats the tail of the range.
            return NSRange(location: start, length: editStart - start)
        }
        // Edit strictly inside.
        return NSRange(location: start, length: range.length + delta)
    }

    /// Applies `adjust` to every highlight, dropping the ones the edit removed.
    static func adjust(_ highlights: [EditorHighlight], for editedRange: NSRange, changeInLength delta: Int) -> [EditorHighlight] {
        highlights.compactMap { highlight in
            guard let range = adjust(highlight.range, for: editedRange, changeInLength: delta) else { return nil }
            var moved = highlight
            moved.range = range
            return moved
        }
    }
}
