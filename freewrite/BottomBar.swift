//
//  BottomBar.swift
//  freewrite
//
//  Which controls the bottom bar shows, on which side, and in what order (Settings › Bottom Bar).
//

import SwiftUI

enum BottomBarItem: String, CaseIterable, Codable, Identifiable {
    case versions
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
        Slot(item: $0, placement: $0 == .versions ? .left : .right)
    })

    var left: [BottomBarItem] { slots.filter { $0.placement == .left }.map(\.item) }
    var right: [BottomBarItem] { slots.filter { $0.placement == .right }.map(\.item) }

    /// Decodes a stored layout; unknown or duplicate items are dropped. Items added in later
    /// versions get their default side and are inserted before the stored item that follows them
    /// by default (Review lands before Backspace, History and Settings and Lock before Settings, never after
    /// the gear).
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
