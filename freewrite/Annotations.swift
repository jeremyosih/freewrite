//
//  Annotations.swift
//  freewrite
//
//  Notes an AI reviewer leaves on a version of an entry, kept as plain JSON in
//  `Entries/[UUID]-[date]/annotations.json` (an array, oldest first):
//
//      { "id", "entryId", "versionId", "reviewerId", "runId",
//        "anchor": { "quote", "prefix", "suffix", "start", "end" },   (absent: a page note)
//        "comment", "kind", "status": "active|orphaned|resolved|dismissed", "createdAt",
//        "resolution": { "by": "user|reviewer", "reviewerId", "runId", "reason", "at" } }
//
//  Decoding is tolerant: older files have no "resolution", and an unknown status reads as active.
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
        /// Addressed: marked by the writer, or by a reviewer whose new review found it fixed.
        /// Kept (and shown under "Resolved") so it isn't raised again; can be reopened.
        case resolved
        /// Dismissed by the user (kept so a reviewer doesn't say it again).
        case dismissed

        /// Statuses written by a newer version of the app read as active instead of failing the file.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .active
        }
    }

    /// Who resolved a note, when and why.
    struct Resolution: Codable, Equatable, Sendable {
        enum Actor: String, Codable, Sendable {
            case user
            case reviewer
        }

        var by: Actor
        /// The reviewer (and its run) that resolved it, when `by` is `.reviewer`.
        var reviewerId: String? = nil
        var runId: String? = nil
        /// A reviewer's short reason ("fixed in v3").
        var reason: String? = nil
        var at: Date
    }

    let id: String
    let entryId: String
    let versionId: String
    let reviewerId: String
    let runId: String
    /// Where the note sits in the text; nil for a page note about the version as a whole.
    var anchor: AnnotationAnchor?
    var comment: String
    /// The note's label, any short word the agent picks ("insight", "tension", "typo", …).
    var kind: String
    var status: Status
    let createdAt: Date
    var resolution: Resolution? = nil
    /// The agent's choice of colour: "#RRGGBB" or a name (red, orange, yellow, green, mint, teal,
    /// blue, indigo, purple, pink, brown, gray). nil = the label's colour.
    var color: String? = nil
    /// "highlight" (a tint) or "squiggle" (a wavy underline). nil = the label's usual style.
    var style: String? = nil
    /// Who the agent wrote as (e.g. the prompt, "Mentor"); `reviewerId` is the agent itself.
    var author: String? = nil
    /// The writer hid this note's highlight in the text (the note itself stays open).
    var hideHighlight: Bool? = nil

    /// `kind` as one of the fixed kinds (older files may hold other words).
    var resolvedKind: AnnotationKind { AnnotationKind.resolve(kind) }

    var isPageNote: Bool { anchor == nil }

    /// Still asks for attention: not resolved or dismissed (an orphaned note may come back).
    var isOpen: Bool { status == .active || status == .orphaned }

    // MARK: Status changes

    /// Marks an open note resolved. False (nothing changes) for resolved or dismissed notes.
    @discardableResult
    mutating func resolve(_ resolution: Resolution) -> Bool {
        guard isOpen else { return false }
        status = .resolved
        self.resolution = resolution
        return true
    }

    /// Reopens a resolved note: active again (re-anchoring orphans it if its quote is gone).
    @discardableResult
    mutating func reopen() -> Bool {
        guard status == .resolved else { return false }
        status = .active
        resolution = nil
        return true
    }

    /// Dismisses any note that isn't dismissed yet.
    @discardableResult
    mutating func dismiss() -> Bool {
        guard status != .dismissed else { return false }
        status = .dismissed
        return true
    }
}

extension Annotation {
    /// Tolerant of older and hand-edited files: no resolution, a missing kind or status.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        entryId = try container.decodeIfPresent(String.self, forKey: .entryId) ?? ""
        versionId = try container.decode(String.self, forKey: .versionId)
        reviewerId = try container.decodeIfPresent(String.self, forKey: .reviewerId) ?? ""
        runId = try container.decodeIfPresent(String.self, forKey: .runId) ?? ""
        anchor = try container.decodeIfPresent(AnnotationAnchor.self, forKey: .anchor)
        comment = try container.decodeIfPresent(String.self, forKey: .comment) ?? ""
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? AnnotationKind.insight.rawValue
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .active
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        resolution = try? container.decodeIfPresent(Resolution.self, forKey: .resolution)
        color = try? container.decodeIfPresent(String.self, forKey: .color)
        style = try? container.decodeIfPresent(String.self, forKey: .style)
        author = try? container.decodeIfPresent(String.self, forKey: .author)
        hideHighlight = try? container.decodeIfPresent(Bool.self, forKey: .hideHighlight)
    }
}

/// What a note is about. Each kind has its own highlight colour in the editor; reviewers
/// pick one per note from the kinds their profile allows.
enum AnnotationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Spelling, grammar and typos.
    case grammar
    /// Vague, tangled or wordy passages.
    case clarity
    /// Order, repetition, where the piece starts, jumps in the thread.
    case structure
    /// A pattern, feeling or theme noticed in the writing.
    case insight
    /// An open question to write about next.
    case question
    /// What works and is worth keeping.
    case praise

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grammar: return "Grammar"
        case .clarity: return "Clarity"
        case .structure: return "Structure"
        case .insight: return "Insight"
        case .question: return "Question"
        case .praise: return "Praise"
        }
    }

    /// One line for the model and for Settings.
    var guidance: String {
        switch self {
        case .grammar: return "a spelling, grammar or typo mistake; say what's wrong in a few words"
        case .clarity: return "a vague, tangled or wordy passage that hides the idea"
        case .structure: return "order, repetition, a buried opening or a jump in the thread"
        case .insight: return "a pattern, feeling or theme you notice in the writing"
        case .question: return "an open question the writer could explore next"
        case .praise: return "something that works and is worth keeping"
        }
    }

    /// Older and looser words for each kind; `resolve` maps them here.
    private static let aliases: [String: AnnotationKind] = [
        "spelling": .grammar, "typo": .grammar, "grammar mistake": .grammar, "punctuation": .grammar,
        "suggestion": .clarity, "wording": .clarity, "style": .clarity, "word choice": .clarity,
        "flow": .structure, "order": .structure, "repetition": .structure,
        "observation": .insight, "pattern": .insight, "theme": .insight, "feeling": .insight,
        "prompt": .question,
        "strength": .praise, "encouragement": .praise,
    ]

    /// The kind a word names (case and surrounding spaces ignored, aliases accepted), or nil.
    static func parse(_ raw: String?) -> AnnotationKind? {
        guard let word = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !word.isEmpty else { return nil }
        return AnnotationKind(rawValue: word) ?? aliases[word]
    }

    /// Like `parse`, falling back to `insight` (the plain highlighter) for anything unknown,
    /// so every stored note still shows.
    static func resolve(_ raw: String?) -> AnnotationKind {
        parse(raw) ?? .insight
    }

    /// `kinds` in their canonical order, without repeats; all kinds when it's empty.
    static func normalized(_ kinds: [AnnotationKind]) -> [AnnotationKind] {
        let set = Set(kinds)
        let ordered = allCases.filter(set.contains)
        return ordered.isEmpty ? allCases : ordered
    }
}

/// Reads and writes `annotations.json` for the entries in one folder.
struct AnnotationStore: Sendable {
    static let fileName = "annotations.json"
    static let reviewsDirectoryName = "reviews"

    enum Failure: LocalizedError, Equatable {
        /// The entry's file is gone (deleted, or moved to another folder).
        case entryMissing

        var errorDescription: String? { "This entry no longer exists in the entries folder." }
    }

    let versionStore: EntryVersionStore

    /// Writes never recreate the folder of an entry whose `.md` file is gone (a late write
    /// from a review of a deleted or moved entry).
    private func requireEntry(_ entryFilename: String) throws {
        guard FileManager.default.fileExists(atPath: versionStore.entryFileURL(for: entryFilename).path) else {
            throw Failure.entryMissing
        }
    }

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
        try requireEntry(entryFilename)
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
        try requireEntry(entryFilename)
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
        latestReviews(entryFilename: entryFilename)[versionId]?.summary
    }

    /// A reviewer's closing summary, as saved in `reviews/`.
    struct ReviewSummary: Equatable, Sendable {
        let reviewerName: String
        let summary: String
    }

    /// The newest summary of each version, by version id.
    func latestReviews(entryFilename: String) -> [String: ReviewSummary] {
        let directory = versionStore.entryDirectory(for: entryFilename)
            .appendingPathComponent(Self.reviewsDirectoryName, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [String: ReviewSummary] = [:]
        // Newest first (the names start with a timestamp), so the first summary of a version wins.
        for url in files.filter({ $0.pathExtension == "md" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let heading = text.split(separator: "\n", maxSplits: 1).first, heading.hasPrefix("# "),
                  let on = heading.range(of: " on ", options: .backwards) else { continue }
            let versionId = String(heading[on.upperBound...])
            guard result[versionId] == nil else { continue }
            let name = String(heading[heading.index(heading.startIndex, offsetBy: 2)..<on.lowerBound])
            result[versionId] = ReviewSummary(
                reviewerName: name, summary: text.dropFirst(heading.count).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
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

    /// Re-anchors `annotations` of `versionId` against `text`: found ones get their offsets
    /// updated (an orphan becomes active again), open ones whose quote is gone are orphaned.
    /// Resolved notes keep their status (their offsets still follow the quote when it's there).
    /// Dismissed notes, page notes and other versions are untouched.
    static func reanchor(_ annotations: [Annotation], versionId: String, in text: String) -> [Annotation] {
        annotations.map { annotation in
            guard annotation.versionId == versionId, annotation.status != .dismissed,
                  let anchor = annotation.anchor else { return annotation }
            var updated = annotation
            if let range = resolve(anchor, in: text) {
                updated.anchor?.start = range.location
                updated.anchor?.end = NSMaxRange(range)
                if updated.status == .orphaned { updated.status = .active }
            } else if updated.status == .active {
                updated.status = .orphaned
            }
            return updated
        }
    }

    /// Copies anchors (and active/orphaned status) the editor moved into `stored`, matching by
    /// id, so notes a review added or resolved meanwhile stay as they are on disk. A note the
    /// file has as resolved or dismissed keeps that status; only its offsets follow the text.
    static func mergeAnchors(_ updated: [Annotation], into stored: inout [Annotation]) {
        let byId = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in stored.indices {
            guard stored[index].status != .dismissed, let mine = byId[stored[index].id],
                  stored[index].anchor != nil, let anchor = mine.anchor else { continue }
            stored[index].anchor = anchor
            if stored[index].isOpen, mine.isOpen {
                stored[index].status = mine.status
            }
        }
    }

    /// Follows a typing edit from `old` to `new` text: offsets shift with the edit
    /// (`EditorHighlight.adjust`), then each quote is checked at its new place and
    /// searched for if it moved or changed.
    static func followEdit(_ annotations: [Annotation], versionId: String, from old: String, to new: String) -> [Annotation] {
        guard old != new, let edit = edit(from: old, to: new) else { return annotations }
        let shifted = annotations.map { annotation -> Annotation in
            guard annotation.versionId == versionId, annotation.status != .dismissed, let anchor = annotation.anchor,
                  let range = EditorHighlight.adjust(anchor.range, for: edit.range, changeInLength: edit.delta) else {
                return annotation
            }
            var moved = annotation
            moved.anchor?.start = range.location
            moved.anchor?.end = NSMaxRange(range)
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
