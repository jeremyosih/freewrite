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
    /// Scrolls the editor to any passage and flashes it (links that point at a quote).
    @ObservationIgnored var revealRange: ((NSRange) -> Void)?
    /// How far the cards are scrolled up inside the column, for cards pushed below its bottom
    /// (e.g. many page notes on a short entry). Applied only up to `maxCardLift`.
    var cardLiftRequest: CGFloat = 0
    /// How far the lowest card reaches below the card area (0 when everything fits).
    var maxCardLift: CGFloat = 0
    /// The lift actually applied to every card (and its connector).
    var cardLift: CGFloat { min(max(cardLiftRequest, 0), maxCardLift) }
    /// The window showing this column, so its scroll monitor ignores every other window.
    @ObservationIgnored weak var window: NSWindow?

    /// Scrolls the column just enough that the card at `top` (card-area coordinates, before the
    /// lift) with `height` is fully visible.
    func revealCard(top: CGFloat, height: CGFloat) {
        let visibleTop = top - cardLift
        if visibleTop < Self.cardInset {
            cardLiftRequest = max(0, top - Self.cardInset)
        } else if visibleTop + height > cardAreaFrame.height - Self.cardInset {
            cardLiftRequest = min(maxCardLift, top + height - cardAreaFrame.height + Self.cardInset)
        }
    }

    /// How far the lowest card reaches below the card area for these card tops.
    func overflow(of tops: [String: CGFloat]) -> CGFloat {
        let bottom = tops.map { $0.value + (cardHeights[$0.key] ?? Self.estimatedCardHeight) }.max() ?? 0
        return max(0, bottom + Self.cardInset - cardAreaFrame.height)
    }

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
        cardLiftRequest = 0
    }
}

/// What one card shows.
struct CommentCardItem: Identifiable, Equatable {
    enum Style: Equatable {
        /// An open note: Resolve, Dismiss, Copy.
        case open
        /// Shown under "Resolved": Reopen, Copy.
        case resolved
        /// The agent's reply that ends a review: Copy only.
        case summary
    }

    let id: String
    let title: String
    let color: NSColor
    let comment: String
    var detail: String? = nil
    /// Who wrote it ("Friend · Claude Code"), under the comment.
    var byline: String? = nil
    /// Whether the passage's highlight is hidden; nil when there's nothing to toggle (page notes,
    /// resolved notes, the reply).
    var highlightHidden: Bool? = nil
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
    var onToggleHighlight: (String) -> Void
    var onToggleResolved: () -> Void
    var onClose: () -> Void
    /// Highlights in the text on or off (every note at once).
    var showsHighlights = true
    var onToggleHighlights: () -> Void = {}

    @State private var isHoveringResolved = false
    @State private var isHoveringClose = false
    @State private var isHoveringHighlights = false

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
        let overflow = model.overflow(of: tops)
        let lift = model.cardLift
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
                    onToggleHighlight: { onToggleHighlight(card.id) },
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
                .offset(x: CommentMarginModel.cardInset, y: (tops[card.id] ?? 0) - lift)
                // Passages that aren't laid out yet have no place: hidden until they are.
                .opacity(tops[card.id] == nil ? 0 : 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Cards slide into place when the active one changes; scrolling moves them directly.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.activeId)
        .clipped()
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.cardAreaFrame = $0 }
        .onChange(of: overflow, initial: true) { _, overflow in model.maxCardLift = overflow }
        // A selected card is pinned at its passage; keep it on screen when the column was scrolled.
        .onChange(of: model.activeId) { _, id in
            guard let id, let top = model.tops(for: cards)[id] else { return }
            model.revealCard(top: top, height: model.cardHeights[id] ?? CommentMarginModel.estimatedCardHeight)
        }
        .background(WindowReader { model.window = $0 })
        // Cards that don't fit below the column's bottom can't be reached by scrolling the text
        // (a short entry has nothing to scroll), so the column scrolls them up itself.
        .onAppear { installCardScrollMonitor() }
        .onDisappear { removeCardScrollMonitor() }
    }

    @State private var cardScrollMonitor: Any?

    private func installCardScrollMonitor() {
        guard cardScrollMonitor == nil else { return }
        cardScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [model] event in
            guard model.maxCardLift > 0 || model.activeId != nil, let window = event.window, window === model.window,
                  let content = window.contentView else { return event }
            // SwiftUI's global frames are window coordinates with y from the top.
            let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            guard model.cardAreaFrame.contains(point) else { return event }
            // Scrolling the column unpins the selected card: pinned at its passage it can push the
            // cards before it above the column, out of reach on a short entry. Unpinned, cards only
            // ever sit at or below their passage, so the lift reaches every one of them.
            if model.activeId != nil {
                model.activeId = nil
            }
            guard model.maxCardLift > 0 else { return event }
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
            model.cardLiftRequest = min(max(model.cardLift - delta, 0), model.maxCardLift)
            return nil
        }
    }

    private func removeCardScrollMonitor() {
        if let cardScrollMonitor { NSEvent.removeMonitor(cardScrollMonitor) }
        cardScrollMonitor = nil
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
            Button(action: onToggleHighlights) {
                Image(systemName: showsHighlights ? "eye" : "eye.slash")
                    .foregroundColor(isHoveringHighlights ? hoverColor : textColor)
            }
            .buttonStyle(.plain)
            .onHover { isHoveringHighlights = $0 }
            .help(showsHighlights ? "Hide Highlights" : "Show Highlights")
            .accessibilityLabel(showsHighlights ? "Hide highlights in the text" : "Show highlights in the text")
            .accessibilityIdentifier("toggleHighlightsButton")
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
    var onToggleHighlight: () -> Void = {}
    var onHover: (Bool) -> Void

    private var kindColor: Color { Color(nsColor: card.color) }

    /// Replies are markdown (headings and lists show as plain lines, emphasis and links render);
    /// notes are plain text.
    private var displayedComment: AttributedString {
        guard card.style == .summary,
              let markdown = try? AttributedString(
                markdown: card.comment,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(card.comment)
        }
        return markdown
    }

    /// Resolved notes and long replies stay short until their card is clicked or hovered.
    private var collapsedLineLimit: Int? {
        guard !isEmphasized else { return nil }
        switch card.style {
        case .resolved: return 2
        case .summary: return 8
        case .open: return nil
        }
    }

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
            Text(displayedComment)
                .font(.system(size: 13))
                .lineLimit(collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let detail = card.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let byline = card.byline {
                Text(byline)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        if let hidden = card.highlightHidden {
            iconButton(hidden ? "eye.slash" : "eye", help: hidden ? "Show Highlight" : "Hide Highlight", action: onToggleHighlight)
                .opacity(hidden ? 1 : 0.75)
                .accessibilityIdentifier("toggleHighlight-\(card.id)")
        }
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
            if let hidden = card.highlightHidden {
                Button(hidden ? "Show Highlight" : "Hide Highlight", action: onToggleHighlight)
            }
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
/// Only passages and cards that are both on screen get a line, and only cards level with their
/// passage (or the hovered/active one).
struct CommentConnectorLayer: View {
    let model: CommentMarginModel
    let cards: [CommentCardItem]

    /// How far (pt) a card may sit from its passage and still show its line without being hovered.
    static let restingLineReach: CGFloat = 28

    var body: some View {
        // Read here (not in the Canvas closure) so SwiftUI redraws when any of it changes.
        let tops = model.tops(for: cards)
        let segments = model.segments
        let editor = model.editorFrame
        let area = model.cardAreaFrame
        let scrollY = model.scrollY
        let textLeft = model.textLeft
        let emphasized = model.emphasizedId
        let lift = model.cardLift
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            Canvas { context, _ in
                for card in cards where card.isAnchored {
                    guard let top = tops[card.id], let segment = segments[card.id] else { continue }
                    let cardY = area.minY + top - lift + CommentMarginModel.connectorOffset
                    let highlight = segment.offsetBy(dx: editor.minX, dy: editor.minY - scrollY)
                    // Both ends must be visible: the card in its area, the passage in the editor.
                    guard cardY > area.minY, cardY < area.maxY,
                          highlight.midY > editor.minY, highlight.midY < editor.maxY else { continue }
                    let isEmphasized = emphasized == card.id
                    // Like Docs: a card pushed away from its passage only gets its line while it's
                    // hovered or active; drawing all of them turns the gutter into a tangle.
                    guard isEmphasized || abs(cardY - highlight.midY) <= Self.restingLineReach else { continue }
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
