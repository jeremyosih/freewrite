//
//  Templates.swift
//  freewrite
//
//  Writing templates: inserted by typing "/" in the editor (or ⌘K › Insert Template…) and
//  edited in Settings › Templates. Stored as JSON in `UserDefaults["templates"]`; a missing
//  key means the built-in defaults. Pure model, matching and placeholder expansion (unit-tested).
//

import Foundation

struct WritingTemplate: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    /// Inserted as is, after `TemplateExpander` fills in `{{date}}`, `{{time}}` and `{{cursor}}`.
    var body: String

    init(id: String = UUID().uuidString, name: String, body: String) {
        self.id = id
        self.name = name
        self.body = body
    }

    /// The name shown in lists and the slash menu.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Template" : trimmed
    }

    /// First non-empty line of the body without markdown markers, for list subtitles.
    var preview: String {
        let line = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let stripped = line.drop { "#>-*• ".contains($0) }
        return String(stripped.prefix(60))
    }

    static let defaults: [WritingTemplate] = [
        WritingTemplate(
            id: "morning-pages",
            name: "Morning pages",
            body: """
            # Morning pages · {{date}}

            Three pages, longhand pace, no stopping. Whatever is on your mind:

            {{cursor}}
            """
        ),
        WritingTemplate(
            id: "gratitude",
            name: "Gratitude",
            body: """
            ## Grateful for · {{date}}

            1. {{cursor}}
            2.
            3.
            """
        ),
        WritingTemplate(
            id: "daily-review",
            name: "Daily review",
            body: """
            ## Daily review · {{date}}

            **What went well?**
            {{cursor}}

            **What was hard?**

            **What will I do differently tomorrow?**
            """
        ),
        WritingTemplate(
            id: "meeting-notes",
            name: "Meeting notes",
            body: """
            ## Meeting · {{date}}, {{time}}

            **With:**
            **Topic:** {{cursor}}

            ### Notes
            -

            ### Next steps
            - [ ]
            """
        ),
    ]
}

extension SettingsKey {
    static let templates = "templates"
}

enum TemplateStore {
    static let key = SettingsKey.templates

    /// An empty or unreadable value means the defaults.
    static func decode(_ json: String) -> [WritingTemplate] {
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let templates = try? JSONDecoder().decode([WritingTemplate].self, from: data) else {
            return WritingTemplate.defaults
        }
        return templates
    }

    static func encode(_ templates: [WritingTemplate]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(templates) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func load(_ defaults: UserDefaults = .standard) -> [WritingTemplate] {
        decode(defaults.string(forKey: key) ?? "")
    }
}

// MARK: - Placeholders

enum TemplateExpander {
    struct Result: Equatable {
        let text: String
        /// Where the caret goes (UTF-16 offset into `text`): the first `{{cursor}}`, else the end.
        let caret: Int
    }

    /// `{{date}}` → "Tuesday, October 27, 2026", `{{time}}` → "9:41 AM" (in `locale`),
    /// `{{cursor}}` → removed, marking the caret. Unknown `{{…}}` are left as typed.
    static func expand(_ body: String, date: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> Result {
        let dateStyle = Date.FormatStyle(date: .complete, time: .omitted, locale: locale, timeZone: timeZone)
        let timeStyle = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)
        var text = body
            .replacingOccurrences(of: "{{date}}", with: date.formatted(dateStyle))
            .replacingOccurrences(of: "{{time}}", with: date.formatted(timeStyle))
        let marker = "{{cursor}}"
        guard let range = text.range(of: marker) else {
            return Result(text: text, caret: text.utf16.count)
        }
        let caret = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
        text.removeSubrange(range)
        // Only the first one marks the caret; any others are just dropped.
        text = text.replacingOccurrences(of: marker, with: "")
        return Result(text: text, caret: caret)
    }
}

// MARK: - Matching

enum TemplateSearch {
    /// Empty query: every template in the user's order. Otherwise, case- and diacritic-insensitive:
    /// names starting with the query, then names with a word starting with it, then names
    /// containing it, then word-start abbreviations ("mn" → Meeting notes). Ties keep the user's order.
    static func results(for query: String, in templates: [WritingTemplate]) -> [WritingTemplate] {
        let folded = PaletteIndex.fold(query.trimmingCharacters(in: .whitespaces))
        guard !folded.isEmpty else { return templates }
        let compact = Array(folded.filter { !$0.isWhitespace })
        var buckets: [[WritingTemplate]] = [[], [], [], []]
        for template in templates {
            let name = PaletteIndex.fold(template.displayName)
            if name.hasPrefix(folded) {
                buckets[0].append(template)
            } else if name.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).contains(where: { $0.hasPrefix(folded) })
                        || name.contains(" " + folded) {
                buckets[1].append(template)
            } else if name.contains(folded) {
                buckets[2].append(template)
            } else if PaletteSearch.matchesWordStarts(compact, in: Array(name)) {
                buckets[3].append(template)
            }
        }
        return buckets.flatMap { $0 }
    }
}

// MARK: - Slash trigger

/// Where a slash command starts and what it has typed so far, worked out from the editor's
/// string and caret (UTF-16, like NSString). Pure so it can be tested without a text view.
enum SlashTrigger {
    /// Queries longer than this close the menu (the "/" was just a slash).
    static let maxQueryLength = 40

    /// "/" typed at `location` opens the menu only at the start of a line or after whitespace.
    static func opens(at location: Int, in string: NSString) -> Bool {
        guard location >= 0, location <= string.length else { return false }
        guard location > 0 else { return true }
        let previous = string.character(at: location - 1)
        guard let scalar = Unicode.Scalar(previous) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// The query between the trigger and the caret, or nil when the menu should close: the "/"
    /// is gone, the caret left the query, the query spans a line break or got too long.
    /// `queryStart` is just after the "/" (or the caret where Insert Template… opened the menu).
    static func query(in string: NSString, slashAt slash: Int?, queryStart: Int, caret: NSRange) -> String? {
        guard caret.length == 0, caret.location >= queryStart, caret.location <= string.length else { return nil }
        if let slash {
            guard slash >= 0, slash < string.length, string.character(at: slash) == 0x2F /* / */ else { return nil }
        }
        let query = string.substring(with: NSRange(location: queryStart, length: caret.location - queryStart))
        guard query.count <= maxQueryLength, !query.contains(where: \.isNewline) else { return nil }
        return query
    }

    /// A query that ends in whitespace and matches nothing closes the menu, so "/ " or "and/or "
    /// keep typing normally.
    static func shouldClose(query: String, resultCount: Int) -> Bool {
        resultCount == 0 && (query.last?.isWhitespace ?? false)
    }
}
