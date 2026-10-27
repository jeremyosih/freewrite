//
//  CommandPalette.swift
//  freewrite
//
//  ⌘K palette: search every entry's full text (video transcripts and sealed versions too)
//  plus app actions.
//

import SwiftUI

struct PaletteDocument: Identifiable, Equatable, Sendable {
    /// The entry's id (shared by all of its versions).
    let id: UUID
    let date: String
    let isVideo: Bool
    let body: String
    /// A sealed version ("v1"); nil for the entry's current text.
    var version: String? = nil

    /// First non-empty line, used as the row title.
    var title: String {
        let firstLine = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
        return firstLine.map { String($0.prefix(80)) } ?? (isVideo ? "Video Entry" : "Empty entry")
    }
}

enum PaletteItem: Identifiable {
    case entry(PaletteDocument, snippet: String?)
    case command(AppCommand)
    case settings

    var id: String {
        switch self {
        case .entry(let document, _): return "entry-\(document.id.uuidString)-\(document.version ?? "current")"
        case .command(let command): return "command-\(command.rawValue)"
        case .settings: return "settings"
        }
    }
}

enum PaletteSearch {
    /// Every term must appear (case- and diacritic-insensitive). Title hits rank first; ties keep
    /// the incoming (newest-first) order.
    static func entries(_ documents: [PaletteDocument], query: String) -> [PaletteItem] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else {
            // Sealed versions only show up when searching.
            return documents.filter { $0.version == nil }.prefix(50).map { .entry($0, snippet: nil) }
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var titleHits: [PaletteItem] = []
        var bodyHits: [PaletteItem] = []
        for document in documents {
            guard terms.allSatisfy({ document.body.range(of: $0, options: options) != nil }) else { continue }
            let title = document.title
            if terms.allSatisfy({ title.range(of: $0, options: options) != nil }) {
                titleHits.append(.entry(document, snippet: nil))
            } else {
                bodyHits.append(.entry(document, snippet: snippet(in: document.body, around: terms[0])))
            }
        }
        return Array((titleHits + bodyHits).prefix(50))
    }

    static func commands(query: String) -> [PaletteItem] {
        let all: [PaletteItem] = AppCommand.allCases.filter { $0 != .commandPalette }.map { .command($0) } + [.settings]
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        return all.filter { item in
            title(for: item).range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    static func title(for item: PaletteItem) -> String {
        switch item {
        case .entry(let document, _): return document.title
        case .command(let command): return command.title
        case .settings: return "Settings…"
        }
    }

    private static func snippet(in body: String, around term: String) -> String? {
        guard let range = body.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = body.index(range.lowerBound, offsetBy: -40, limitedBy: body.startIndex) ?? body.startIndex
        let end = body.index(range.upperBound, offsetBy: 60, limitedBy: body.endIndex) ?? body.endIndex
        let text = body[start..<end].replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return (start > body.startIndex ? "…" : "") + text + (end < body.endIndex ? "…" : "")
    }
}

struct CommandPaletteView: View {
    let documents: [PaletteDocument]?
    let shortcutsJSON: String
    let colorScheme: ColorScheme
    let onSelect: (PaletteItem) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    /// Search results, recomputed only when the query or the documents change.
    @State private var results: [PaletteItem] = []
    /// Tracked by id so results arriving later don't change what Return opens.
    @State private var highlightedID: String?
    @FocusState private var searchFocused: Bool

    /// Empty query: recent entries, then every action. Otherwise: matching actions, then entries.
    private static func search(_ query: String, in documents: [PaletteDocument]) -> [PaletteItem] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return Array(PaletteSearch.entries(documents, query: "").prefix(8)) + PaletteSearch.commands(query: "")
        }
        return Array(PaletteSearch.commands(query: query).prefix(4)) + PaletteSearch.entries(documents, query: query)
    }

    private func updateResults() {
        results = Self.search(query, in: documents ?? [])
    }

    /// The highlighted item, falling back to the first one.
    private var highlightedItemID: String? {
        if let highlightedID, results.contains(where: { $0.id == highlightedID }) {
            return highlightedID
        }
        return results.first?.id
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(colorScheme == .light ? 0.12 : 0.4)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search entries or actions", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($searchFocused)
                        .accessibilityIdentifier("commandPaletteSearch")
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onKeyPress(.escape) { onDismiss(); return .handled }
                        .onSubmit(selectHighlighted)
                    if documents == nil {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()

                let items = results
                if items.isEmpty {
                    Text(documents == nil ? "Loading entries…" : "No matches")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(items) { item in
                                    row(for: item, highlighted: item.id == highlightedItemID)
                                        .id(item.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture { onSelect(item) }
                                        .onHover { if $0 { highlightedID = item.id } }
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 380)
                        .onChange(of: highlightedID) { _, id in
                            if let id {
                                proxy.scrollTo(id)
                            }
                        }
                    }
                }
            }
            .frame(width: 580)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.2), radius: 30, y: 12)
            .padding(.top, 90)
        }
        .onAppear {
            updateResults()
            searchFocused = true
        }
        .onChange(of: query) {
            highlightedID = nil
            updateResults()
        }
        .onChange(of: documents) { updateResults() }
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private func row(for item: PaletteItem, highlighted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon(for: item))
                .frame(width: 16)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(PaletteSearch.title(for: item))
                    .font(.system(size: 14))
                    .lineLimit(1)
                if case .entry(_, let snippet?) = item {
                    Text(snippet)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(trailing(for: item))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(highlighted ? Color.primary.opacity(0.08) : .clear)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }

    private func icon(for item: PaletteItem) -> String {
        switch item {
        case .entry(let document, _):
            if document.isVideo { return "video" }
            return document.version == nil ? "doc.text" : "clock.arrow.circlepath"
        case .command: return "command"
        case .settings: return "gearshape"
        }
    }

    private func trailing(for item: PaletteItem) -> String {
        switch item {
        case .entry(let document, _): return document.version.map { "\($0) · \(document.date)" } ?? document.date
        case .command(let command): return ShortcutStore.shortcut(for: command, in: shortcutsJSON)?.displayString ?? ""
        case .settings: return "⌘,"
        }
    }

    private func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        let current = results.firstIndex(where: { $0.id == highlightedItemID }) ?? 0
        highlightedID = results[(current + delta + count) % count].id
    }

    private func selectHighlighted() {
        guard let item = results.first(where: { $0.id == highlightedItemID }) else { return }
        onSelect(item)
    }
}
