//
//  CommandPalette.swift
//  freewrite
//
//  ⌘K palette: search every entry's full text (video transcripts and sealed versions too)
//  plus app actions. Matching lives in PaletteSearch.swift.
//

import SwiftUI
import AppKit

struct CommandPaletteView: View {
    /// nil while the entries are still being read.
    let index: PaletteIndex?
    let shortcutsJSON: String
    let onSelect: (PaletteItem) -> Void
    let onDismiss: () -> Void

    private struct SearchKey: Equatable {
        let query: String
        let indexID: UUID?
    }

    @State private var query = ""
    @State private var results: [PaletteItem] = []
    /// What `results` was computed for; "No matches" only shows once the current search finished.
    @State private var resultsKey: SearchKey?
    /// Tracked by id so results arriving later don't change what Return opens.
    @State private var highlightedID: String?
    /// Pointer location at the last keyboard move or list change. Hover only moves the highlight
    /// once the pointer leaves it, so rows scrolling under a resting pointer can't steal it.
    @State private var pinnedPointer: CGPoint?
    @State private var listHeight: CGFloat = 0
    /// ↩ pressed before the current query's search finished (the value is "alternate");
    /// performed as soon as its results arrive, so Return never opens a stale result.
    @State private var pendingSubmit: Bool?

    private var searchKey: SearchKey { SearchKey(query: query, indexID: index?.id) }

    /// The highlighted item, falling back to the first one.
    private var highlightedItem: PaletteItem? {
        if let highlightedID, let item = results.first(where: { $0.id == highlightedID }) {
            return item
        }
        return results.first
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Clear hit area: clicking outside the card closes the palette.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    PaletteSearchField(
                        text: $query,
                        onMove: move,
                        onJump: jump,
                        onSubmit: submit,
                        onCancel: onDismiss
                    )
                    .frame(maxWidth: .infinity)
                    if index == nil {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()

                if results.isEmpty {
                    Text(index == nil ? "Loading entries…" : resultsKey == searchKey ? "No matches" : " ")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    resultsList
                }
            }
            .frame(width: 580)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.2), radius: 30, y: 12)
            .padding(.top, 90)
            .accessibilityAddTraits(.isModal)
        }
        .onAppear(perform: pinPointer)
        .onChange(of: query) {
            highlightedID = nil
            pinPointer()
        }
        // Restarts (and cancels the previous search) on every keystroke and when the entries arrive.
        .task(id: searchKey) {
            let key = searchKey
            let found = await PaletteSearch.run(key.query, in: index ?? .empty)
            guard !Task.isCancelled else { return }
            results = found
            resultsKey = key
            pinPointer()
            if let alternate = pendingSubmit {
                pendingSubmit = nil
                submit(alternate: alternate)
            }
        }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(results) { item in
                        row(for: item, highlighted: item.id == highlightedItem?.id)
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(item) }
                            .onContinuousHover { phase in
                                guard case .active = phase else { return }
                                let pointer = NSEvent.mouseLocation
                                guard pointer != pinnedPointer else { return }
                                pinnedPointer = nil
                                if highlightedID != item.id { highlightedID = item.id }
                            }
                            .accessibilityAction { onSelect(item) }
                    }
                }
                .padding(6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            // Shrink to the rows; scroll only past 380 pt.
            .frame(height: min(max(listHeight, 1), 380))
            .onChange(of: highlightedItem?.id) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    @ViewBuilder
    private func row(for item: PaletteItem, highlighted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon(for: item))
                .frame(width: 16)
                .foregroundStyle(highlighted ? Color.accentColor : .secondary)
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
                .fill(highlighted ? Color.accentColor.opacity(0.2) : .clear)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }

    private func icon(for item: PaletteItem) -> String {
        switch item {
        case .entry(let document, _):
            if document.isLocked { return "lock.fill" }
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

    private func pinPointer() {
        pinnedPointer = NSEvent.mouseLocation
    }

    /// ↑/↓: moves the highlight, wrapping at both ends.
    private func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        let current = results.firstIndex(where: { $0.id == highlightedItem?.id }) ?? 0
        highlight(results[(current + delta + count) % count])
    }

    /// ⌘↑/⌘↓: first or last row.
    private func jump(toEnd: Bool) {
        guard let item = toEnd ? results.last : results.first else { return }
        highlight(item)
    }

    private func highlight(_ item: PaletteItem) {
        highlightedID = item.id
        pinPointer()
        AccessibilityNotification.Announcement(PaletteSearch.title(for: item)).post()
    }

    /// ↩ opens the highlighted row. ⌘↩ on a sealed version opens the entry's current version instead.
    private func submit(alternate: Bool) {
        guard resultsKey == searchKey else {
            pendingSubmit = alternate
            return
        }
        guard let item = highlightedItem else { return }
        if alternate, case .entry(var document, _) = item, document.version != nil {
            document.version = nil
            onSelect(.entry(document, snippet: nil))
        } else {
            onSelect(item)
        }
    }
}

/// The search field. An AppKit text field so ↑/↓/↩/Esc arrive as text commands
/// (`moveUp:`, `insertNewline:`, …) instead of depending on SwiftUI focus and key-press timing.
private struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let onMove: (Int) -> Void
    let onJump: (_ toEnd: Bool) -> Void
    let onSubmit: (_ alternate: Bool) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> PaletteTextField {
        let field = PaletteTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 16)
        field.placeholderString = "Search entries or actions"
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search entries and actions")
        field.setAccessibilityIdentifier("commandPaletteSearch")
        return field
    }

    func updateNSView(_ field: PaletteTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteSearchField

        init(parent: PaletteSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Let an input method finish composing first.
            if textView.hasMarkedText() { return false }
            // ⌘↩ has no standard binding (the field editor sends `noop:`), so check the event itself.
            if let event = NSApp.currentEvent, event.type == .keyDown,
               event.keyCode == 36 || event.keyCode == 76,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                parent.onSubmit(true)
                return true
            }
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveToBeginningOfDocument(_:)): parent.onJump(false)
            case #selector(NSResponder.moveToEndOfDocument(_:)): parent.onJump(true)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(false)
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}

/// Takes first responder as soon as it's in a window.
private final class PaletteTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }
}
