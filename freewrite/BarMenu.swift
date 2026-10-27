//
//  BarMenu.swift
//  freewrite
//
//  Floating menus of the bottom bar (versions, Review with…, voice notes, permissions, overflow):
//  a rounded card above the control that opened it, no arrow. ContentView draws the open menu
//  in one overlay over the writing area, positioned from anchor preferences of the bar controls,
//  so nothing is clipped by the bar and there is no separate window to keep in sync.
//

import SwiftUI

/// Which menu is open. Only one at a time.
enum BarMenuKind: Hashable {
    case versions
    case review
    case voiceNotes
    case videoPermission
    case microphonePermission
    case overflow
}

/// Places a bar menu can hang from. Controls publish theirs with `.barMenuAnchor(_:)`.
enum BarMenuAnchor: Hashable {
    case item(BottomBarItem)
    case voiceNotes
    case overflow
    /// The right side of the bar; always there, used when the control is hidden.
    case barRight
}

struct BarMenuAnchorKey: PreferenceKey {
    static let defaultValue: [BarMenuAnchor: Anchor<CGRect>] = [:]

    static func reduce(value: inout [BarMenuAnchor: Anchor<CGRect>], nextValue: () -> [BarMenuAnchor: Anchor<CGRect>]) {
        value.merge(nextValue()) { current, _ in current }
    }
}

extension View {
    /// Lets a bar menu hang from this view.
    func barMenuAnchor(_ anchor: BarMenuAnchor) -> some View {
        anchorPreference(key: BarMenuAnchorKey.self, value: .bounds) { [anchor: $0] }
    }
}

struct BarMenuAction: Identifiable {
    let id: String
    let title: String
    /// Coloured dot before the title (reviewer colour).
    var dot: Color? = nil
    /// Trailing secondary text (shortcut, date).
    var detail: String? = nil
    /// Trailing symbol, e.g. `arrow.up.forward` for actions that leave the app.
    var trailingSymbol: String? = nil
    var isChecked = false
    var isEnabled = true
    let perform: () -> Void
}

struct BarMenuSection: Identifiable {
    let id: String
    var header: String? = nil
    /// Small print under the header.
    var note: String? = nil
    /// A paragraph of body text (permission explanations, the latest review summary).
    var paragraph: String? = nil
    /// Any other view, shown after the paragraph (the kind legend in Review with…).
    var accessory: AnyView? = nil
    var actions: [BarMenuAction] = []
    /// Status line under the actions.
    var footer: String? = nil
}

struct BarMenuContent {
    var width: CGFloat
    var sections: [BarMenuSection]

    /// Actions reachable with ↑/↓, in order.
    var enabledActions: [BarMenuAction] {
        sections.flatMap(\.actions).filter(\.isEnabled)
    }

    /// The action after (or before, with `step` -1) `current`, wrapping; the first/last one when
    /// nothing is highlighted yet.
    func action(after current: String?, step: Int) -> BarMenuAction? {
        let actions = enabledActions
        guard !actions.isEmpty else { return nil }
        guard let current, let index = actions.firstIndex(where: { $0.id == current }) else {
            return step > 0 ? actions.first : actions.last
        }
        return actions[(index + step + actions.count) % actions.count]
    }
}

/// The card itself.
struct BarMenuCard: View {
    let content: BarMenuContent
    let isDark: Bool
    @Binding var highlighted: String?
    let onChoose: (BarMenuAction) -> Void

    private let radius: CGFloat = 12

    var body: some View {
        ViewThatFits(in: .vertical) {
            sections
            ScrollView { sections }
                .scrollIndicators(.automatic)
        }
        .frame(width: content.width)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(isDark ? Color(white: 0.13) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(isDark ? 0.14 : 0.09), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: .black.opacity(isDark ? 0.45 : 0.12), radius: 18, y: 6)
        .shadow(color: .black.opacity(isDark ? 0.3 : 0.06), radius: 2, y: 1)
        .foregroundStyle(isDark ? Color(white: 0.9) : Color(white: 0.2))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(content.sections.enumerated()), id: \.element.id) { index, section in
                if index > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(isDark ? 0.12 : 0.08))
                        .frame(height: 0.5)
                        .padding(.vertical, 5)
                }
                sectionView(section)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func sectionView(_ section: BarMenuSection) -> some View {
        if let header = section.header {
            Text(header)
                .font(.system(size: 11, weight: .medium))
                .opacity(0.55)
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, section.note == nil ? 4 : 1)
        }
        if let note = section.note {
            Text(note)
                .font(.system(size: 11))
                .opacity(0.45)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
        }
        if let paragraph = section.paragraph {
            Text(paragraph)
                .font(.system(size: 12))
                .opacity(0.8)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
        }
        if let accessory = section.accessory {
            accessory
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
        }
        ForEach(section.actions) { action in
            row(action)
        }
        if let footer = section.footer {
            Text(footer)
                .font(.system(size: 12))
                .opacity(0.55)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
        }
    }

    private func row(_ action: BarMenuAction) -> some View {
        let isHighlighted = action.isEnabled && highlighted == action.id
        return Button {
            onChoose(action)
        } label: {
            HStack(spacing: 8) {
                if let dot = action.dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 8, height: 8)
                }
                Text(action.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 12)
                if let detail = action.detail {
                    Text(detail)
                        .font(.system(size: 12).monospacedDigit())
                        .opacity(0.5)
                        .lineLimit(1)
                }
                if let symbol = action.trailingSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .medium))
                        .opacity(0.5)
                }
                if action.isChecked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHighlighted ? (isDark ? 0.12 : 0.06) : 0))
                    .padding(.horizontal, 6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.4)
        .accessibilityIdentifier(action.id)
        .accessibilityAddTraits(action.isChecked ? .isSelected : [])
        .onHover { hovering in
            if hovering {
                highlighted = action.id
            } else if highlighted == action.id {
                highlighted = nil
            }
        }
    }
}

/// Puts the card `gap` above `anchor`, horizontally centred on it and kept `margin` inside the
/// container; a card taller than the room above the anchor gets that height (and scrolls).
struct BarMenuPlacement: Layout {
    var anchor: CGRect
    var gap: CGFloat = 8
    var margin: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let card = subviews.first else { return }
        let room = max(anchor.minY - gap - margin, 60)
        let size = card.sizeThatFits(ProposedViewSize(width: nil, height: room))
        let height = min(size.height, room)
        let x = min(max(anchor.midX - size.width / 2, margin), max(bounds.width - margin - size.width, margin))
        let y = max(anchor.minY - gap - height, margin)
        card.place(
            at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
            proposal: ProposedViewSize(width: size.width, height: height)
        )
    }
}
