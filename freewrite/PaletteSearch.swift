//
//  PaletteSearch.swift
//  freewrite
//
//  Pure model and matching for the ⌘K palette (no UI, unit-tested headless).
//

import Foundation

struct PaletteDocument: Identifiable, Equatable, Sendable {
    /// The entry's id (shared by all of its versions).
    let id: UUID
    let date: String
    let isVideo: Bool
    let body: String
    /// A sealed version ("v1"); nil for the entry's current text.
    var version: String? = nil
    /// Locked notes are listed by date only; their text is never read for the palette.
    var isLocked = false

    /// First non-empty line, used as the row title.
    var title: String {
        if isLocked { return "Locked note" }
        let firstLine = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
        return firstLine.map { String($0.prefix(80)) } ?? (isVideo ? "Video Entry" : "Empty entry")
    }
}

/// What the palette offers for reviewing the version on screen (captured when it opens).
struct PaletteReviewActions: Sendable {
    struct Reviewer: Sendable {
        let id: String
        let name: String
    }

    /// The version a review would read ("v2").
    var versionId: String
    /// Empty while a review runs or nothing can be reviewed.
    var reviewers: [Reviewer]
    /// Notes on that version that Clear Review would remove.
    var noteCount: Int

    static let none = PaletteReviewActions(versionId: "", reviewers: [], noteCount: 0)
}

enum PaletteItem: Identifiable, Sendable {
    case entry(PaletteDocument, snippet: String?)
    case command(AppCommand)
    case review(PaletteReviewActions.Reviewer, versionId: String)
    case clearReview(noteCount: Int)
    case reviewerSettings
    case settings

    var id: String {
        switch self {
        case .entry(let document, _): return "entry-\(document.id.uuidString)-\(document.version ?? "current")"
        case .command(let command): return "command-\(command.rawValue)"
        case .review(let reviewer, _): return "review-\(reviewer.id)"
        case .clearReview: return "clearReview"
        case .reviewerSettings: return "reviewerSettings"
        case .settings: return "settings"
        }
    }
}

/// The palette's documents, folded (case and diacritics) once when the palette opens so each
/// keystroke only runs plain `contains` checks.
struct PaletteIndex: Sendable {
    struct Document: Sendable {
        let document: PaletteDocument
        let foldedTitle: String
        let foldedBody: String
    }

    /// Changes whenever a new index is built, so the view knows to search again.
    let id = UUID()
    let documents: [Document]
    let reviewActions: PaletteReviewActions

    init(_ documents: [PaletteDocument], reviewActions: PaletteReviewActions = .none) {
        self.reviewActions = reviewActions
        self.documents = documents.map {
            // A locked note can only be found by its title and date.
            Document(
                document: $0,
                foldedTitle: Self.fold($0.title),
                foldedBody: Self.fold($0.isLocked ? "\($0.title) \($0.date)" : $0.body)
            )
        }
    }

    static let empty = PaletteIndex([])

    static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

enum PaletteSearch {
    static let maxEntries = 50

    /// Runs `results(for:in:)` off the main actor; cancelling the calling task stops it early.
    @concurrent
    static func run(_ query: String, in index: PaletteIndex) async -> [PaletteItem] {
        results(for: query, in: index)
    }

    /// Empty query: recent entries, then every action. Otherwise: up to 4 matching actions, then entries.
    static func results(for query: String, in index: PaletteIndex) -> [PaletteItem] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return Array(entries(index, query: "").prefix(8)) + commands(query: "", reviewActions: index.reviewActions)
        }
        return Array(commands(query: query, reviewActions: index.reviewActions).prefix(4)) + entries(index, query: query)
    }

    /// Every term must appear (case- and diacritic-insensitive). Title hits rank first; ties keep
    /// the incoming (newest-first) order.
    static func entries(_ index: PaletteIndex, query: String) -> [PaletteItem] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else {
            // Sealed versions only show up when searching.
            return index.documents.lazy.filter { $0.document.version == nil }
                .prefix(maxEntries).map { .entry($0.document, snippet: nil) }
        }
        let folded = terms.map(PaletteIndex.fold)
        var titleHits: [PaletteIndex.Document] = []
        var bodyHits: [PaletteIndex.Document] = []
        for (offset, document) in index.documents.enumerated() {
            if offset % 200 == 0 && Task.isCancelled { return [] }
            guard folded.allSatisfy(document.foldedBody.contains) else { continue }
            if folded.allSatisfy(document.foldedTitle.contains) {
                titleHits.append(document)
            } else {
                bodyHits.append(document)
            }
        }
        // Snippets are only built for the rows that will be shown.
        let titleItems = titleHits.prefix(maxEntries).map { PaletteItem.entry($0.document, snippet: nil) }
        let bodyItems = bodyHits.prefix(maxEntries - titleItems.count).map {
            PaletteItem.entry($0.document, snippet: snippet(in: $0.document.body, around: terms[0]))
        }
        return titleItems + bodyItems
    }

    /// Titles containing the query come first, then titles matching it by word starts
    /// ("nv" → New Version, "rec vid" → Record Video, "rwe" → Review with Editor).
    static func commands(query: String, reviewActions: PaletteReviewActions = .none) -> [PaletteItem] {
        let reviewItems: [PaletteItem] = reviewActions.reviewers.map { .review($0, versionId: reviewActions.versionId) }
            + (reviewActions.noteCount > 0 ? [.clearReview(noteCount: reviewActions.noteCount)] : [])
            + [.reviewerSettings]
        let all: [PaletteItem] = AppCommand.allCases.filter { $0 != .commandPalette }.map { .command($0) } + reviewItems + [.settings]
        let folded = PaletteIndex.fold(query.trimmingCharacters(in: .whitespaces))
        guard !folded.isEmpty else { return all }
        let compact = Array(folded.filter { !$0.isWhitespace })
        var substringHits: [PaletteItem] = []
        var wordHits: [PaletteItem] = []
        for item in all {
            let title = PaletteIndex.fold(title(for: item))
            if title.contains(folded) {
                substringHits.append(item)
            } else if matchesWordStarts(compact, in: Array(title)) {
                wordHits.append(item)
            }
        }
        return substringHits + wordHits
    }

    static func title(for item: PaletteItem) -> String {
        switch item {
        case .entry(let document, _): return document.title
        case .command(let command): return command.title
        case .review(let reviewer, _): return "Review with \(reviewer.name)"
        case .clearReview(let count): return "Clear Review (\(count == 1 ? "1 note" : "\(count) notes"))"
        case .reviewerSettings: return "Reviewers & Models…"
        case .settings: return "Settings…"
        }
    }

    /// `query` is a subsequence of `title` where every character either starts a word or directly
    /// follows the previous matched character.
    static func matchesWordStarts(_ query: [Character], in title: [Character]) -> Bool {
        func isWordStart(_ i: Int) -> Bool {
            i == 0 || !(title[i - 1].isLetter || title[i - 1].isNumber)
        }
        func match(_ q: Int, from t: Int, previous: Int?) -> Bool {
            if q == query.count { return true }
            var i = t
            while i < title.count {
                if title[i] == query[q], i == (previous.map { $0 + 1 } ?? -1) || isWordStart(i),
                   match(q + 1, from: i + 1, previous: i) {
                    return true
                }
                i += 1
            }
            return false
        }
        return !query.isEmpty && match(0, from: 0, previous: nil)
    }

    static func snippet(in body: String, around term: String) -> String? {
        guard let range = body.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = body.index(range.lowerBound, offsetBy: -40, limitedBy: body.startIndex) ?? body.startIndex
        let end = body.index(range.upperBound, offsetBy: 60, limitedBy: body.endIndex) ?? body.endIndex
        let text = body[start..<end].replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return (start > body.startIndex ? "…" : "") + text + (end < body.endIndex ? "…" : "")
    }
}
