//
//  Annotations.swift
//  freewrite
//
//  Notes an AI reviewer leaves on a version of an entry, kept as plain JSON in
//  `Entries/[UUID]-[date]/annotations.json` (an array, oldest first):
//
//      { "id", "entryId", "versionId", "reviewerId", "runId",
//        "anchor": { "quote", "prefix", "suffix", "start", "end" },
//        "comment", "kind", "status": "active|orphaned|dismissed", "createdAt" }
//
//  Anchors combine a text quote (with ~32 characters of context either side) and
//  UTF-16 offsets, like the W3C TextQuote + TextPosition selectors. Sealed versions
//  never change, so their offsets stay valid; annotations on the current version are
//  re-anchored on load and moved along while the user types.
//

import Foundation

struct AnnotationAnchor: Codable, Equatable, Sendable {
    /// The exact annotated text.
    var quote: String
    /// Text right before / after the quote when it was anchored, used to pick between repeats.
    var prefix: String
    var suffix: String
    /// UTF-16 offsets (NSString / TextKit units).
    var start: Int
    var end: Int

    var range: NSRange { NSRange(location: start, length: max(end - start, 0)) }
}

struct Annotation: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case active
        /// The quote can't be found in the current text any more (kept, hidden).
        case orphaned
        /// Dismissed by the user (kept so a reviewer doesn't say it again).
        case dismissed
    }

    /// The kinds a reviewer can choose from; anything else is stored as given.
    static let kinds = ["observation", "question", "suggestion", "praise"]

    let id: String
    let entryId: String
    let versionId: String
    let reviewerId: String
    let runId: String
    var anchor: AnnotationAnchor
    var comment: String
    var kind: String
    var status: Status
    let createdAt: Date
}

/// Reads and writes `annotations.json` for the entries in one folder.
struct AnnotationStore: Sendable {
    static let fileName = "annotations.json"
    static let reviewsDirectoryName = "reviews"

    let versionStore: EntryVersionStore

    func fileURL(for entryFilename: String) -> URL {
        versionStore.entryDirectory(for: entryFilename).appendingPathComponent(Self.fileName)
    }

    /// Every annotation of the entry, oldest first; none when there's no file yet.
    func load(for entryFilename: String) throws -> [Annotation] {
        let url = fileURL(for: entryFilename)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Self.decoder.decode([Annotation].self, from: Data(contentsOf: url))
    }

    /// Writes the list (creating the entry folder if needed); an empty list removes the file.
    func save(_ annotations: [Annotation], for entryFilename: String) throws {
        let url = fileURL(for: entryFilename)
        if annotations.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(annotations).write(to: url, options: .atomic)
    }

    /// Read-modify-write. A file that exists but can't be read throws instead of being replaced.
    @discardableResult
    func update<T>(for entryFilename: String, _ change: (inout [Annotation]) throws -> T) throws -> T {
        var annotations = try load(for: entryFilename)
        let before = annotations
        let result = try change(&annotations)
        if annotations != before {
            try save(annotations, for: entryFilename)
        }
        return result
    }

    /// Writes a reviewer's closing summary to `reviews/<timestamp>-<reviewer>.md`.
    @discardableResult
    func saveSummary(_ summary: String, reviewerName: String, versionId: String, entryFilename: String, now: Date = Date()) throws -> URL {
        let directory = versionStore.entryDirectory(for: entryFilename)
            .appendingPathComponent(Self.reviewsDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let slug = reviewerName.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        let url = directory.appendingPathComponent("\(formatter.string(from: now))-\(slug.isEmpty ? "review" : slug).md")
        let body = "# \(reviewerName) on \(versionId)\n\n\(summary.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The newest saved summary of a version, if any (text after the heading).
    func latestSummary(versionId: String, entryFilename: String) -> String? {
        let directory = versionStore.entryDirectory(for: entryFilename)
            .appendingPathComponent(Self.reviewsDirectoryName, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files.filter({ $0.pathExtension == "md" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let heading = text.split(separator: "\n", maxSplits: 1).first,
                  heading.hasSuffix(" on \(versionId)") else { continue }
            return text.dropFirst(heading.count).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Anchoring

enum AnnotationAnchoring {
    /// UTF-16 units of context kept on each side of a quote.
    static let contextLength = 32

    enum Failure: LocalizedError, Equatable {
        case emptyQuote
        case notFound
        case ambiguous(count: Int)

        var errorDescription: String? {
            switch self {
            case .emptyQuote:
                return "The quote is empty. Copy a short passage from the version text, exactly as written."
            case .notFound:
                return "That quote isn't in this version. Copy it exactly from read_version (same words, punctuation and case), keep it short, and don't add ellipses."
            case .ambiguous(let count):
                return "That quote appears \(count) times in this version. Pass a longer quote, or a prefix/suffix (the few words right before/after it) to say which one."
            }
        }
    }

    /// Finds `quote` in `text` and builds an anchor with offsets and context computed here
    /// (the model never does offset arithmetic). Exact matches win; otherwise whitespace
    /// and straight/curly quote differences are tolerated. Repeats are told apart with
    /// `prefix`/`suffix`.
    static func anchor(quote: String, prefix: String? = nil, suffix: String? = nil, in text: String) -> Result<AnnotationAnchor, Failure> {
        let quote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return .failure(.emptyQuote) }
        let string = text as NSString
        var matches = occurrences(of: quote, in: string)
        if matches.isEmpty {
            matches = looseOccurrences(of: quote, in: string)
        }
        guard !matches.isEmpty else { return .failure(.notFound) }

        let chosen: NSRange
        if matches.count == 1 {
            chosen = matches[0]
        } else {
            let wantsPrefix = prefix?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let wantsSuffix = suffix?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !wantsPrefix.isEmpty || !wantsSuffix.isEmpty else { return .failure(.ambiguous(count: matches.count)) }
            let scored = matches.map { ($0, contextScore(of: $0, in: string, prefix: wantsPrefix, suffix: wantsSuffix)) }
            let best = scored.map(\.1).max() ?? 0
            let winners = scored.filter { $0.1 == best }
            guard best > 0, winners.count == 1 else { return .failure(.ambiguous(count: matches.count)) }
            chosen = winners[0].0
        }
        return .success(makeAnchor(for: chosen, in: string))
    }

    /// The anchor of `range` in `text`, with context taken from the text itself.
    static func makeAnchor(for range: NSRange, in string: NSString) -> AnnotationAnchor {
        let before = string.rangeOfComposedCharacterSequences(
            for: NSRange(location: max(range.location - contextLength, 0), length: min(contextLength, range.location)))
        let afterStart = NSMaxRange(range)
        let after = string.rangeOfComposedCharacterSequences(
            for: NSRange(location: afterStart, length: min(contextLength, string.length - afterStart)))
        return AnnotationAnchor(
            quote: string.substring(with: range),
            prefix: string.substring(with: NSRange(location: before.location, length: max(range.location - before.location, 0))),
            suffix: string.substring(with: NSRange(location: afterStart, length: max(NSMaxRange(after) - afterStart, 0))),
            start: range.location,
            end: NSMaxRange(range)
        )
    }

    /// Where the anchor is in `text` now: its stored offsets if the quote is still there,
    /// else the occurrence of the quote whose context (then position) fits best; nil when
    /// the quote is gone.
    static func resolve(_ anchor: AnnotationAnchor, in text: String) -> NSRange? {
        let string = text as NSString
        let stored = anchor.range
        if !anchor.quote.isEmpty, NSMaxRange(stored) <= string.length, string.substring(with: stored) == anchor.quote {
            return stored
        }
        let matches = occurrences(of: anchor.quote, in: string)
        guard !matches.isEmpty else { return nil }
        if matches.count == 1 { return matches[0] }
        return matches.max { lhs, rhs in
            let left = contextScore(of: lhs, in: string, prefix: anchor.prefix, suffix: anchor.suffix)
            let right = contextScore(of: rhs, in: string, prefix: anchor.prefix, suffix: anchor.suffix)
            if left != right { return left < right }
            // Same context: prefer the one closest to where it used to be.
            return abs(lhs.location - anchor.start) > abs(rhs.location - anchor.start)
        }
    }

    /// Re-anchors `annotations` of `versionId` against `text`: found ones become active
    /// (offsets updated), missing ones orphaned. Dismissed notes and other versions are untouched.
    static func reanchor(_ annotations: [Annotation], versionId: String, in text: String) -> [Annotation] {
        annotations.map { annotation in
            guard annotation.versionId == versionId, annotation.status != .dismissed else { return annotation }
            var updated = annotation
            if let range = resolve(annotation.anchor, in: text) {
                updated.anchor.start = range.location
                updated.anchor.end = NSMaxRange(range)
                updated.status = .active
            } else {
                updated.status = .orphaned
            }
            return updated
        }
    }

    /// Follows a typing edit from `old` to `new` text: offsets shift with the edit
    /// (`EditorHighlight.adjust`), then each quote is checked at its new place and
    /// searched for if it moved or changed.
    static func followEdit(_ annotations: [Annotation], versionId: String, from old: String, to new: String) -> [Annotation] {
        guard old != new, let edit = edit(from: old, to: new) else { return annotations }
        let shifted = annotations.map { annotation -> Annotation in
            guard annotation.versionId == versionId, annotation.status != .dismissed,
                  let range = EditorHighlight.adjust(annotation.anchor.range, for: edit.range, changeInLength: edit.delta) else {
                return annotation
            }
            var moved = annotation
            moved.anchor.start = range.location
            moved.anchor.end = NSMaxRange(range)
            return moved
        }
        return reanchor(shifted, versionId: versionId, in: new)
    }

    /// The single edit turning `old` into `new`: the changed UTF-16 range in `new`
    /// (as NSTextStorage reports it) and the length delta.
    static func edit(from old: String, to new: String) -> (range: NSRange, delta: Int)? {
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)
        guard oldUnits != newUnits else { return nil }
        let limit = min(oldUnits.count, newUnits.count)
        var prefix = 0
        while prefix < limit, oldUnits[prefix] == newUnits[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] { suffix += 1 }
        let delta = newUnits.count - oldUnits.count
        return (NSRange(location: prefix, length: newUnits.count - prefix - suffix), delta)
    }

    // MARK: Matching

    static func occurrences(of quote: String, in string: NSString) -> [NSRange] {
        guard !quote.isEmpty else { return [] }
        var result: [NSRange] = []
        var searchRange = NSRange(location: 0, length: string.length)
        while searchRange.length > 0 {
            let found = string.range(of: quote, options: .literal, range: searchRange)
            guard found.location != NSNotFound else { break }
            result.append(found)
            let next = found.location + max(found.length, 1)
            searchRange = NSRange(location: next, length: string.length - next)
        }
        return result
    }

    /// Matches that ignore runs of whitespace and straight/curly quote differences.
    private static func looseOccurrences(of quote: String, in string: NSString) -> [NSRange] {
        let words = quote.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return [] }
        let pattern = words.map { word in
            word.map { character -> String in
                switch character {
                case "'", "\u{2018}", "\u{2019}": return "['\u{2018}\u{2019}]"
                case "\"", "\u{201C}", "\u{201D}": return "[\"\u{201C}\u{201D}]"
                default: return NSRegularExpression.escapedPattern(for: String(character))
                }
            }.joined()
        }.joined(separator: "\\s+")
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: string as String, range: NSRange(location: 0, length: string.length)).map(\.range)
    }

    /// How many characters of `prefix`/`suffix` agree with the text around `range`.
    private static func contextScore(of range: NSRange, in string: NSString, prefix: String, suffix: String) -> Int {
        let beforeStart = max(range.location - (prefix as NSString).length, 0)
        let before = string.substring(with: NSRange(location: beforeStart, length: range.location - beforeStart))
        let afterStart = NSMaxRange(range)
        let after = string.substring(with: NSRange(location: afterStart, length: min((suffix as NSString).length, string.length - afterStart)))
        return commonSuffixLength(before, prefix.trimmingCharacters(in: .whitespacesAndNewlines))
            + commonPrefixLength(after, suffix.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Context is compared from the quote outwards, ignoring the spaces and punctuation that
    /// usually sit between a quote and the words a model passes as prefix/suffix.
    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || character.isPunctuation
    }

    private static func commonPrefixLength(_ text: String, _ wanted: String) -> Int {
        zip(text.drop(while: isSeparator), wanted.drop(while: isSeparator)).prefix(while: { $0 == $1 }).count
    }

    private static func commonSuffixLength(_ text: String, _ wanted: String) -> Int {
        zip(text.reversed().drop(while: isSeparator), wanted.reversed().drop(while: isSeparator)).prefix(while: { $0 == $1 }).count
    }
}
