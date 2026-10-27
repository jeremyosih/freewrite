//
//  BottomBar.swift
//  freewrite
//
//  Which controls the bottom bar shows, on which side, and in what order (Settings › Bottom Bar).
//

import SwiftUI

enum BottomBarItem: String, CaseIterable, Codable, Identifiable {
    case versions
    case wordCount
    case timer
    case recordVideo
    case recordVoiceNote
    case review
    case backspace
    case fullscreen
    case newEntry
    case history
    case lock
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .versions: return "Versions"
        case .wordCount: return "Word Count"
        case .timer: return "Timer"
        case .recordVideo: return "Record Video"
        case .recordVoiceNote: return "Record Voice Note"
        case .review: return "Review"
        case .backspace: return "Backspace Toggle"
        case .fullscreen: return "Fullscreen"
        case .newEntry: return "New Entry"
        case .history: return "History"
        case .lock: return "Lock Note"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .versions: return "square.stack"
        case .wordCount: return "text.word.spacing"
        case .timer: return "timer"
        case .recordVideo: return "video.fill"
        case .recordVoiceNote: return "mic.fill"
        case .review: return "sparkles"
        case .backspace: return "delete.left"
        case .fullscreen: return "arrow.up.left.and.arrow.down.right"
        case .newEntry: return "square.and.pencil"
        case .history: return "clock.arrow.circlepath"
        case .lock: return "lock.open"
        case .settings: return "gearshape"
        }
    }

    /// What the item looks like in the bar, for the Settings preview.
    var previewLabel: String? {
        switch self {
        case .versions: return "v1"
        case .wordCount: return "142 words"
        case .timer: return "15:00"
        case .backspace: return "Backspace is On"
        case .fullscreen: return "Fullscreen"
        case .newEntry: return "New Entry"
        case .recordVideo, .recordVoiceNote, .review, .history, .lock, .settings: return nil
        }
    }
}

enum BottomBarPlacement: String, Codable, CaseIterable {
    case left
    case right
    case hidden

    var title: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .hidden: return "Hidden"
        }
    }
}

/// Ordered list of every item with its placement. Left and right render in this order.
struct BottomBarLayout: Codable, Equatable {
    struct Slot: Codable, Equatable, Identifiable {
        var item: BottomBarItem
        var placement: BottomBarPlacement
        var id: BottomBarItem { item }
    }

    var slots: [Slot]

    static let `default` = BottomBarLayout(slots: BottomBarItem.allCases.map {
        Slot(item: $0, placement: $0 == .versions || $0 == .wordCount ? .left : .right)
    })

    var left: [BottomBarItem] { slots.filter { $0.placement == .left }.map(\.item) }
    var right: [BottomBarItem] { slots.filter { $0.placement == .right }.map(\.item) }

    /// Decodes a stored layout; unknown or duplicate items are dropped. Items added in later
    /// versions get their default side and are inserted before the stored item that follows them
    /// by default (Word Count lands on the left after Versions, Review before Backspace, History and
    /// Settings and Lock before Settings, never after the gear).
    static func decode(_ json: String) -> BottomBarLayout {
        guard let data = json.data(using: .utf8),
              let stored = try? JSONDecoder().decode(StoredLayout.self, from: data) else {
            return .default
        }
        var seen = Set<BottomBarItem>()
        var slots: [Slot] = []
        for slot in stored.slots {
            guard let item = BottomBarItem(rawValue: slot.item),
                  let placement = BottomBarPlacement(rawValue: slot.placement),
                  seen.insert(item).inserted else { continue }
            slots.append(Slot(item: item, placement: placement))
        }
        let order = BottomBarItem.allCases
        for (index, item) in order.enumerated() where !seen.contains(item) {
            let placement = BottomBarLayout.default.slots.first { $0.item == item }?.placement ?? .right
            let followers = Set(order[(index + 1)...])
            let position = slots.firstIndex { followers.contains($0.item) } ?? slots.endIndex
            slots.insert(Slot(item: item, placement: placement), at: position)
        }
        return BottomBarLayout(slots: slots)
    }

    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Lenient mirror of the stored JSON so renamed/removed items don't break decoding.
    private struct StoredLayout: Decodable {
        struct StoredSlot: Decodable {
            let item: String
            let placement: String
        }
        let slots: [StoredSlot]
    }
}

extension SettingsKey {
    static let bottomBarLayout = "bottomBarLayout"
    /// "words" or "characters": what the Word Count item shows.
    static let wordCountUnit = "wordCountUnit"
}

// MARK: - What the bar shows right now

/// The state that decides whether a placed item shows in the bar right now.
struct BottomBarContext: Equatable {
    /// A video entry is on screen.
    var isVideoEntry = false
    /// A text entry is selected and its versions are loaded.
    var hasTextEntry = false
    /// The selected note is locked and not open: nothing of it is shown.
    var isNoteClosed = false
    /// The selected note is locked, open or not.
    var isNoteLocked = false
}

extension BottomBarItem {
    /// Whether the item renders in `context`. An item that's pending (camera preflight, a running
    /// review, a microphone prompt) still shows: its content changes in place, it never goes away.
    func isVisible(in context: BottomBarContext) -> Bool {
        switch self {
        // Writing-only controls.
        case .backspace, .lock: return !context.isVideoEntry
        // Nothing of a locked note is shown until it's opened.
        case .versions, .wordCount, .recordVoiceNote:
            return !context.isVideoEntry && context.hasTextEntry && !context.isNoteClosed
        // Locked notes are never sent to a reviewer, open or not.
        case .review: return !context.isVideoEntry && !context.isNoteLocked
        case .timer, .recordVideo, .fullscreen, .newEntry, .history, .settings: return true
        }
    }
}

/// One control in a bar group: an item, or the "…" button holding the items that don't fit.
enum BottomBarSlot: Hashable {
    case item(BottomBarItem)
    case overflow
}

/// Which slots each side renders. Every slot renders something, so a group only needs a `•`
/// before each slot after the first (and before the first when the status slot is showing).
enum BottomBarModel {
    /// Bar items that move into "…" first when the bar is too narrow. Settings and the version
    /// menu always stay.
    static let overflowOrder: [BottomBarItem] = [
        .fullscreen, .wordCount, .backspace, .newEntry, .timer, .recordVideo, .recordVoiceNote, .review, .lock, .history,
    ]

    /// Visible items that may move into "…", in the order they do.
    static func overflowCandidates(layout: BottomBarLayout, context: BottomBarContext) -> [BottomBarItem] {
        let visible = Set((layout.left + layout.right).filter { $0.isVisible(in: context) })
        return overflowOrder.filter(visible.contains)
    }

    /// The left and right slots with `overflow` moved into "…" (placed before the gear so
    /// Settings stays last on the right; only there when something is in it).
    static func groups(
        layout: BottomBarLayout,
        context: BottomBarContext,
        overflow: [BottomBarItem] = []
    ) -> (left: [BottomBarSlot], right: [BottomBarSlot]) {
        let moved = Set(overflow.filter { $0.isVisible(in: context) })
        func slots(_ items: [BottomBarItem]) -> [BottomBarSlot] {
            items.filter { $0.isVisible(in: context) && !moved.contains($0) }.map { .item($0) }
        }
        let left = slots(layout.left)
        var right = slots(layout.right)
        if !moved.isEmpty {
            right.insert(.overflow, at: right.firstIndex(of: .item(.settings)) ?? right.endIndex)
        }
        return (left, right)
    }

    /// Whether a `•` goes before the slot at `index`: between slots, and after the status slot.
    static func separatorBefore(_ index: Int, afterStatus: Bool) -> Bool {
        index > 0 || afterStatus
    }
}

// MARK: - Settings pane

struct BottomBarSettingsView: View {
    @AppStorage(SettingsKey.bottomBarLayout) private var layoutJSON = ""

    private var layout: BottomBarLayout { BottomBarLayout.decode(layoutJSON) }

    var body: some View {
        Form {
            Section {
                BottomBarPreview(layout: layout)
            } header: {
                Text("Preview")
            }

            Section {
                List {
                    ForEach(layout.slots) { slot in
                        HStack {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                            Label(slot.item.title, systemImage: slot.item.systemImage)
                                .foregroundStyle(slot.placement == .hidden ? .secondary : .primary)
                            Spacer()
                            Picker(slot.item.title, selection: placementBinding(for: slot.item)) {
                                ForEach(BottomBarPlacement.allCases, id: \.self) { placement in
                                    Text(placement.title).tag(placement)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove(perform: move)
                }
                .frame(minHeight: CGFloat(layout.slots.count) * 34)
            } header: {
                Text("Items")
            } footer: {
                Text("Drag to reorder. Each side shows its items in this order. Hidden items stay available from the menu bar, ⌘K and their shortcuts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Restore Defaults") { layoutJSON = "" }
            }
        }
        .formStyle(.grouped)
    }

    private func placementBinding(for item: BottomBarItem) -> Binding<BottomBarPlacement> {
        Binding(
            get: { layout.slots.first(where: { $0.item == item })?.placement ?? .hidden },
            set: { placement in
                var updated = layout
                if let index = updated.slots.firstIndex(where: { $0.item == item }) {
                    updated.slots[index].placement = placement
                }
                layoutJSON = updated.encoded()
            }
        )
    }

    private func move(from source: IndexSet, to destination: Int) {
        var updated = layout
        updated.slots.move(fromOffsets: source, toOffset: destination)
        layoutJSON = updated.encoded()
    }
}

private struct BottomBarPreview: View {
    let layout: BottomBarLayout

    var body: some View {
        HStack {
            group(layout.left)
            Spacer(minLength: 16)
            group(layout.right)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 24)
    }

    @ViewBuilder
    private func group(_ items: [BottomBarItem]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                if index > 0 {
                    Text("•")
                }
                if let label = item.previewLabel {
                    Text(label).lineLimit(1)
                } else {
                    Image(systemName: item.systemImage)
                }
            }
        }
    }
}
