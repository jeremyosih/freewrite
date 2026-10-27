//
//  WordCount.swift
//  freewrite
//
//  Words and characters of the text on screen, for the bottom bar's Word Count item.
//

import Foundation

/// Counts as written: markdown markers aren't stripped, but punctuation-only runs (`#`, `**`,
/// `-`) aren't words, so `# **Bold** idea` is 2 words.
/// - A word is a run of letters, digits and combining marks. An apostrophe, hyphen or underscore
///   inside it keeps it one word (`don't`, `well-known`, `snake_case`), and so does `.`/`,`
///   between digits (`3.14`, `1,000`).
/// - Chinese and Japanese (Han, Hiragana, Katakana) are written without spaces: each of those
///   characters is a word. Korean uses spaces and counts like Latin text.
/// - Emoji and other symbols aren't words.
/// - Characters are grapheme clusters (what the caret steps over), spaces and line breaks included:
///   👍🏽 and e + ◌́ are one character each.
struct TextCount: Equatable, Sendable {
    var words = 0
    var characters = 0

    init() {}

    init(_ text: String) {
        characters = text.count
        var inWord = false
        // A joiner (apostrophe, hyphen…) right after a word: the word goes on if a letter follows.
        var pendingJoiner = false
        var previousWasDigit = false
        for scalar in text.unicodeScalars {
            let properties = scalar.properties
            if Self.isSpacelessScript(scalar) {
                words += 1
                inWord = false
                pendingJoiner = false
                previousWasDigit = false
                continue
            }
            let isDigit = properties.numericType != nil
            if properties.isAlphabetic || isDigit || (inWord && !pendingJoiner && Self.isMark(properties)) {
                if !inWord {
                    words += 1
                    inWord = true
                }
                pendingJoiner = false
            } else if inWord && !pendingJoiner
                        && (Self.wordJoiners.contains(scalar) || (previousWasDigit && Self.numberJoiners.contains(scalar))) {
                pendingJoiner = true
            } else {
                inWord = false
                pendingJoiner = false
            }
            previousWasDigit = isDigit
        }
    }

    /// Counts off the main actor (long entries take a few milliseconds).
    @concurrent
    static func measure(_ text: String) async -> TextCount {
        TextCount(text)
    }

    enum Unit: String, CaseIterable, Sendable {
        case words
        case characters

        var toggled: Unit { self == .words ? .characters : .words }
    }

    /// "142 words", "1 word", "1,204 characters".
    func label(_ unit: Unit, locale: Locale = .current) -> String {
        let value = unit == .words ? words : characters
        let number = value.formatted(.number.locale(locale))
        switch unit {
        case .words: return value == 1 ? "\(number) word" : "\(number) words"
        case .characters: return value == 1 ? "\(number) character" : "\(number) characters"
        }
    }

    private static let wordJoiners: Set<Unicode.Scalar> = ["'", "\u{2019}", "-", "\u{2010}", "_"]
    private static let numberJoiners: Set<Unicode.Scalar> = [".", ","]

    private static func isMark(_ properties: Unicode.Scalar.Properties) -> Bool {
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// Han ideographs, Hiragana, Katakana (incl. half-width) and the iteration marks.
    private static func isSpacelessScript(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isIdeographic { return true }
        switch scalar.value {
        case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D: return true
        default: return false
        }
    }
}
