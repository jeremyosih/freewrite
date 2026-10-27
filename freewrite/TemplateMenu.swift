//
//  TemplateMenu.swift
//  freewrite
//
//  The "/" template menu: typing "/" at the start of a line or after a space in the editor opens
//  a small card of templates under the caret line (a `BarMenuCard`, like the bar menus). The
//  editor's coordinator drives it (query, ↑/↓, ↩, Esc); ContentView draws it over the window.
//

import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class TemplateMenuController {
    struct Session: Equatable {
        /// Where the "/" is (UTF-16); nil when Insert Template… opened the menu without one.
        var slash: Int?
        /// Just after the "/" (or the caret where the menu opened).
        var queryStart: Int
        var query = ""
    }

    private(set) var session: Session?
    private(set) var results: [WritingTemplate] = []
    var highlightedID: String?
    /// The trigger's line, in the window content view's top-left coordinates.
    private(set) var anchorRect: CGRect = .zero

    @ObservationIgnored private var templates: [WritingTemplate] = []
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var clickMonitor: Any?
    @ObservationIgnored private var resignObserver: (any NSObjectProtocol)?
    /// The card's frame (same coordinates as `anchorRect`), so clicks on it don't close it.
    @ObservationIgnored var cardFrame: CGRect = .zero

    /// Set by the editor: replaces "/query" with the template.
    @ObservationIgnored var insertHandler: ((WritingTemplate) -> Void)?
    /// Set by the editor: opens the menu at the caret (Insert Template…). False when it can't.
    @ObservationIgnored var openAtCaretHandler: (() -> Bool)?
    /// Set by ContentView: called after a template went into the text (applies its font/size).
    @ObservationIgnored var didInsertHandler: ((WritingTemplate) -> Void)?
    /// Set by ContentView: "Edit Templates…" opens Settings › Templates.
    @ObservationIgnored var editTemplatesHandler: (() -> Void)?

    var isOpen: Bool { session != nil }

    /// With Backspace off, backspace may still edit the query, but never the "/" or the text before it.
    var allowsBackspace: Bool { !(session?.query.isEmpty ?? true) }

    // MARK: Editor side

    func open(slash: Int?, queryStart: Int, anchor: CGRect, in window: NSWindow?) {
        templates = TemplateStore.load()
        session = Session(slash: slash, queryStart: queryStart)
        anchorRect = anchor
        results = templates
        highlightedID = results.first.map(Self.actionID)
        self.window = window
        installMonitors()
    }

    /// The query or the caret line changed.
    func update(query: String, anchor: CGRect) {
        guard var session else { return }
        if anchor != anchorRect { anchorRect = anchor }
        guard query != session.query else { return }
        let results = TemplateSearch.results(for: query, in: templates)
        if SlashTrigger.shouldClose(query: query, resultCount: results.count) {
            close()
            return
        }
        session.query = query
        self.session = session
        self.results = results
        if !results.contains(where: { Self.actionID($0) == highlightedID }) {
            highlightedID = results.first.map(Self.actionID)
        }
    }

    func close() {
        guard session != nil else { return }
        session = nil
        results = []
        highlightedID = nil
        cardFrame = .zero
        removeMonitors()
    }

    func move(_ step: Int) {
        highlightedID = content.action(after: highlightedID, step: step)?.id
    }

    /// ↩: inserts (or runs) the highlighted row. False when nothing is highlighted.
    func chooseHighlighted() -> Bool {
        guard let action = content.enabledActions.first(where: { $0.id == highlightedID }) else { return false }
        action.perform()
        return true
    }

    /// Insert Template…: opens the menu at the caret without typing a "/".
    @discardableResult
    func openAtCaret() -> Bool {
        openAtCaretHandler?() ?? false
    }

    // MARK: Card

    var content: BarMenuContent {
        let query = session?.query ?? ""
        let actions = results.map { template in
            BarMenuAction(id: Self.actionID(template), title: template.displayName) { [weak self] in
                self?.insertHandler?(template)
            }
        }
        var sections = [BarMenuSection(
            id: "templates",
            header: query.isEmpty ? "Templates" : nil,
            actions: actions,
            footer: actions.isEmpty ? (templates.isEmpty ? "No templates yet" : "No matching templates") : nil
        )]
        // Only with an empty query, so ↩ after a typo never opens Settings.
        if query.isEmpty, editTemplatesHandler != nil {
            sections.append(BarMenuSection(id: "edit", actions: [
                BarMenuAction(id: "template-edit", title: "Edit Templates…", trailingSymbol: "arrow.up.forward") { [weak self] in
                    self?.close()
                    self?.editTemplatesHandler?()
                },
            ]))
        }
        return BarMenuContent(width: 240, sections: sections)
    }

    private static func actionID(_ template: WritingTemplate) -> String {
        "template-\(template.id)"
    }

    // MARK: Closing from outside

    /// A click anywhere but the card closes the menu (and still lands where it was aimed);
    /// so does the window losing key status.
    private func installMonitors() {
        removeMonitors()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window === window,
                      let contentView = window.contentView else { return }
                var point = contentView.convert(event.locationInWindow, from: nil)
                if !contentView.isFlipped {
                    point.y = contentView.bounds.height - point.y
                }
                if !self.cardFrame.contains(point) {
                    self.close()
                }
            }
            return event
        }
        if let window {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
    }

    private func removeMonitors() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }

    /// Converts a rect in screen coordinates to the window content view's top-left coordinates.
    static func contentRect(fromScreen rect: CGRect, in window: NSWindow) -> CGRect {
        guard let contentView = window.contentView else { return .zero }
        var local = contentView.convert(window.convertFromScreen(rect), from: nil)
        if !contentView.isFlipped {
            local.origin.y = contentView.bounds.height - local.maxY
        }
        return local
    }
}

/// Puts the card `gap` below the trigger's line, its text aligned with the "/", kept `margin`
/// inside the container. When there isn't room below, it flips above the line; a card taller
/// than either side gets the bigger one (and scrolls).
struct TemplateMenuPlacement: Layout {
    var anchor: CGRect
    var gap: CGFloat = 6
    var margin: CGFloat = 8
    var maxHeight: CGFloat = 320
    /// Row text is inset 14pt in the card; shift left so it lines up with the "/".
    var textInset: CGFloat = 14

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let card = subviews.first else { return }
        let below = min(bounds.height - anchor.maxY - gap - margin, maxHeight)
        let above = min(anchor.minY - gap - margin, maxHeight)
        let natural = card.sizeThatFits(ProposedViewSize(width: nil, height: maxHeight))
        let placeBelow = natural.height <= below || below >= above
        let room = max(placeBelow ? below : above, 60)
        let size = card.sizeThatFits(ProposedViewSize(width: nil, height: room))
        let height = min(size.height, room)
        let x = min(max(anchor.minX - textInset, margin), max(bounds.width - margin - size.width, margin))
        let y = placeBelow ? anchor.maxY + gap : max(anchor.minY - gap - height, margin)
        card.place(
            at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
            proposal: ProposedViewSize(width: size.width, height: height)
        )
    }
}

/// The open template menu, drawn over the whole window by ContentView.
struct TemplateMenuOverlay: View {
    @Bindable var controller: TemplateMenuController
    let isDark: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            if controller.isOpen {
                let origin = proxy.frame(in: .global).origin
                TemplateMenuPlacement(anchor: controller.anchorRect.offsetBy(dx: -origin.x, dy: -origin.y)) {
                    BarMenuCard(
                        content: controller.content,
                        isDark: isDark,
                        highlighted: $controller.highlightedID,
                        onChoose: { action in
                            guard action.isEnabled else { return }
                            action.perform()
                        }
                    )
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        controller.cardFrame = frame
                    }
                    .accessibilityIdentifier("templateMenu")
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: controller.isOpen)
    }
}
