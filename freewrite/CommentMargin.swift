//
//  CommentMargin.swift
//  freewrite
//
//  The comment margin: reviewer notes as cards in a column on the left of the writing area,
//  each next to its highlight with a thin connector line, like comments in Word or Google Docs.
//  The editor (WritingEditor) publishes where each passage sits; `CommentCardLayout` keeps the
//  cards from overlapping. Page notes and the review summary sit above the first line.
//

import AppKit
import SwiftUI

/// Shared between the editor, the column and the connector layer. The editor writes passage
/// positions and the scroll offset; the column writes card heights; hover/active come from both.
@MainActor @Observable
final class CommentMarginModel {
    /// First line segment of each passage with a card, in the text view's (document) coordinates.
    var segments: [String: CGRect] = [:]
    /// The editor's scroll offset: the document y at the top of the visible text.
    var scrollY: CGFloat = 0
    /// Document y of the first line (the text container's top inset).
    var textTop: CGFloat = 0
    /// x of the text's left edge inside the editor.
    var textLeft: CGFloat = 0
    /// The editor (its scroll view) and the column's card area, in global coordinates.
    var editorFrame: CGRect = .zero
    var cardAreaFrame: CGRect = .zero
    var cardHeights: [String: CGFloat] = [:]
    /// The card or highlight under the pointer, and the one last clicked.
    var hoveredId: String?
    var activeId: String?
    /// Scrolls the editor to a note's passage (installed by the editor).
    @ObservationIgnored var reveal: ((String) -> Void)?

    /// The note drawn stronger: its card, highlight and line.
    var emphasizedId: String? { hoveredId ?? activeId }

    static let columnWidth: CGFloat = 280
    static let cardInset: CGFloat = 12
    static let estimatedCardHeight: CGFloat = 64
    /// Card y of the connector: the middle of the card's title row.
    static let connectorOffset: CGFloat = 17

    /// Where each card's top goes, in the card area's coordinates. Page cards (no passage) aim
    /// at the first line; passage cards at their highlight; cards whose passage isn't laid out are left out.
    func tops(for cards: [CommentCardItem]) -> [String: CGFloat] {
        let offset = editorFrame.minY - scrollY - cardAreaFrame.minY
        let items = cards.compactMap { card -> CommentCardLayout.Item? in
            let target: CGFloat
            if card.isAnchored {
                guard let segment = segments[card.id] else { return nil }
                target = segment.minY + offset
            } else {
                target = textTop + offset
            }
            return CommentCardLayout.Item(id: card.id, target: target, height: cardHeights[card.id] ?? Self.estimatedCardHeight)
        }
        return CommentCardLayout.place(items, spacing: 8, anchorId: activeId)
    }

    /// Forgets the notes of the entry/version that was on screen.
    func reset() {
        segments = [:]
        hoveredId = nil
        activeId = nil
    }
}

/// What one card shows.
struct CommentCardItem: Identifiable, Equatable {
    enum Style: Equatable {
        /// An open note: Resolve, Dismiss, Copy.
        case open
        /// Shown under "Resolved": Reopen, Copy.
        case resolved
        /// The review's closing summary: Copy only.
        case summary
    }

    let id: String
    let title: String
    let color: NSColor
    let comment: String
    var detail: String? = nil
    let style: Style
    /// Tied to a passage (else a page note or the summary, shown above the first line).
    let isAnchored: Bool
}

// MARK: - Column

struct CommentColumn: View {
    let model: CommentMarginModel
    let cards: [CommentCardItem]
    let isDark: Bool
    let reduceMotion: Bool
    let resolvedCount: Int
    let showsResolved: Bool
    let emptyMessage: String
    /// Height of the bottom strip, so the footer lines up with the bottom bar.
    let footerHeight: CGFloat
    var onSelect: (String) -> Void
    var onResolve: (String) -> Void
    var onReopen: (String) -> Void
    var onDismiss: (String) -> Void
    var onToggleResolved: () -> Void
    var onClose: () -> Void

    @State private var isHoveringResolved = false
    @State private var isHoveringClose = false

    private var textColor: Color { .gray }
    private var hoverColor: Color { isDark ? .white : .black }

    var body: some View {
        VStack(spacing: 0) {
            cardArea
            footer
        }
        .frame(width: CommentMarginModel.columnWidth)
        .background((isDark ? Color(white: 0.05) : Color(white: 0.975)).ignoresSafeArea(edges: .top))
    }

    private var cardArea: some View {
        let tops = model.tops(for: cards)
        return ZStack(alignment: .topLeading) {
            if cards.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 24)
            }
            ForEach(cards) { card in
                CommentCardView(
                    card: card,
                    isDark: isDark,
                    isEmphasized: model.emphasizedId == card.id,
                    onSelect: { onSelect(card.id) },
                    onResolve: { onResolve(card.id) },
                    onReopen: { onReopen(card.id) },
                    onDismiss: { onDismiss(card.id) },
                    onHover: { hovering in
                        if hovering {
                            model.hoveredId = card.id
                        } else if model.hoveredId == card.id {
                            model.hoveredId = nil
                        }
                    }
                )
                .frame(width: CommentMarginModel.columnWidth - 2 * CommentMarginModel.cardInset)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.cardHeights[card.id] = $0 }
                .offset(x: CommentMarginModel.cardInset, y: tops[card.id] ?? 0)
                // Passages that aren't laid out yet have no place: hidden until they are.
                .opacity(tops[card.id] == nil ? 0 : 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Cards slide into place when the active one changes; scrolling moves them directly.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.activeId)
        .clipped()
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.cardAreaFrame = $0 }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(countText)
                .foregroundColor(textColor)
            if resolvedCount > 0 {
                Text("•").foregroundColor(.gray)
                Button(action: onToggleResolved) {
                    Text(showsResolved ? "Hide Resolved" : "Resolved (\(resolvedCount))")
                        .foregroundColor(isHoveringResolved ? hoverColor : textColor)
                }
                .buttonStyle(.plain)
                .onHover { isHoveringResolved = $0 }
                .accessibilityIdentifier("toggleResolvedComments")
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "sidebar.left")
                    .foregroundColor(isHoveringClose ? hoverColor : textColor)
            }
            .buttonStyle(.plain)
            .onHover { isHoveringClose = $0 }
            .help("Hide Comments")
            .accessibilityLabel("Hide comments")
            .accessibilityIdentifier("hideCommentsButton")
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(height: footerHeight)
    }

    private var countText: String {
        let open = cards.filter { $0.style == .open }.count
        return open == 1 ? "1 comment" : "\(open) comments"
    }
}

// MARK: - Card

struct CommentCardView: View {
    let card: CommentCardItem
    let isDark: Bool
    let isEmphasized: Bool
    var onSelect: () -> Void
    var onResolve: () -> Void
    var onReopen: () -> Void
    var onDismiss: () -> Void
    var onHover: (Bool) -> Void

    private var kindColor: Color { Color(nsColor: card.color) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if card.style == .resolved {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Circle()
                        .fill(kindColor)
                        .frame(width: 7, height: 7)
                }
                Text(card.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                actions
            }
            .frame(height: 18)
            Text(card.comment)
                .font(.system(size: 13))
                .lineLimit(card.style == .resolved && !isEmphasized ? 2 : nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let detail = card.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isDark ? Color(white: 0.13) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isEmphasized ? kindColor.opacity(0.9) : Color.primary.opacity(isDark ? 0.14 : 0.09),
                    lineWidth: isEmphasized ? 1.25 : 0.5)
        )
        .shadow(color: .black.opacity(isEmphasized ? (isDark ? 0.5 : 0.14) : (isDark ? 0.25 : 0.05)), radius: isEmphasized ? 10 : 3, y: isEmphasized ? 3 : 1)
        .opacity(card.style == .resolved && !isEmphasized ? 0.7 : 1)
        .foregroundStyle(isDark ? Color(white: 0.9) : Color(white: 0.2))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover(perform: onHover)
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(card.title): \(card.comment)")
        .accessibilityAddTraits(isEmphasized ? .isSelected : [])
        .accessibilityAction(named: "Show in text", onSelect)
        .accessibilityIdentifier("commentCard-\(card.id)")
    }

    @ViewBuilder
    private var actions: some View {
        switch card.style {
        case .open:
            iconButton("checkmark", help: "Resolve", action: onResolve)
                .accessibilityIdentifier("resolveComment-\(card.id)")
        case .resolved:
            iconButton("arrow.uturn.backward", help: "Reopen", action: onReopen)
                .accessibilityIdentifier("reopenComment-\(card.id)")
        case .summary:
            EmptyView()
        }
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More actions")
    }

    @ViewBuilder
    private var menuItems: some View {
        switch card.style {
        case .open:
            Button("Resolve", action: onResolve)
            Button("Dismiss Note", action: onDismiss)
        case .resolved:
            Button("Reopen", action: onReopen)
            Button("Dismiss Note", action: onDismiss)
        case .summary:
            EmptyView()
        }
        Button("Copy Comment") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(card.comment, forType: .string)
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Connectors

/// The lines from cards to their passages, drawn over the whole window and never hit-tested.
/// Only passages and cards that are both on screen get a line.
struct CommentConnectorLayer: View {
    let model: CommentMarginModel
    let cards: [CommentCardItem]

    var body: some View {
        // Read here (not in the Canvas closure) so SwiftUI redraws when any of it changes.
        let tops = model.tops(for: cards)
        let segments = model.segments
        let editor = model.editorFrame
        let area = model.cardAreaFrame
        let scrollY = model.scrollY
        let textLeft = model.textLeft
        let emphasized = model.emphasizedId
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            Canvas { context, _ in
                for card in cards where card.isAnchored {
                    guard let top = tops[card.id], let segment = segments[card.id] else { continue }
                    let cardY = area.minY + top + CommentMarginModel.connectorOffset
                    let highlight = segment.offsetBy(dx: editor.minX, dy: editor.minY - scrollY)
                    // Both ends must be visible: the card in its area, the passage in the editor.
                    guard cardY > area.minY, cardY < area.maxY,
                          highlight.midY > editor.minY, highlight.midY < editor.maxY else { continue }
                    let isEmphasized = emphasized == card.id
                    let points = CommentConnector.points(
                        cardRightX: area.maxX - CommentMarginModel.cardInset,
                        cardY: cardY,
                        textLeftX: editor.minX + textLeft - 4,
                        highlight: highlight,
                        emphasized: isEmphasized
                    ).map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
                    // An S-curve across the gutter (points 0–3 are its ends and control points), so
                    // lines of stacked cards stay apart; the emphasized one then runs under its line.
                    var path = Path()
                    path.move(to: points[0])
                    path.addCurve(to: points[3], control1: points[1], control2: points[2])
                    if points.count > 4 {
                        path.addLine(to: points[4])
                    }
                    let color = Color(nsColor: card.color).opacity(isEmphasized ? 0.9 : (card.style == .resolved ? 0.2 : 0.4))
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: isEmphasized ? 1.5 : 1, lineJoin: .round))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
