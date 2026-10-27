//
//  WritingEditor.swift
//  freewrite
//
//  The writing surface: a TextKit 2 NSTextView with live markdown styling
//  (syntax stays visible, the saved string is never changed) and hover-comment
//  highlights drawn as rendering attributes.
//

import AppKit
import SwiftUI

struct WritingEditor: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let lineSpacing: CGFloat
    let textColor: NSColor
    let isDark: Bool
    var highlights: [EditorHighlight] = []
    /// Offers "Dismiss Note" when right-clicking a highlight; receives its id.
    var onDismissHighlight: ((String) -> Void)? = nil
    /// The editor takes focus again whenever this changes (e.g. the selected entry).
    var focusKey: AnyHashable? = nil
    /// False while something else (the ⌘K palette) owns the keyboard.
    var canTakeFocus: Bool = true
    /// False shows the text read-only (selectable, not editable), e.g. a sealed version.
    var isEditable: Bool = true
    /// Breathing room before the first line (and after the last); it scrolls with the text.
    var verticalInset: CGFloat = 0
    /// The "/" template menu, opened by typing "/" at the start of a line or after a space.
    var templateMenu: TemplateMenuController? = nil

    /// `.custom`-style lookup: PostScript name, then family name, then the system font.
    static func font(named name: String, size: CGFloat) -> NSFont {
        NSFont(name: name, size: size)
            ?? NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size)
            ?? .systemFont(ofSize: size)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = WritingTextView(usingTextLayoutManager: true)
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.importsGraphics = false
        textView.allowsUndo = true
        // No Apple Intelligence Writing Tools (the button on a selection and the context-menu item).
        textView.writingToolsBehavior = .none
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: verticalInset)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Entry text")
        textView.setAccessibilityIdentifier("editor")

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        // The view is already laid out below the hidden title bar; don't add another inset.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.documentView = textView

        let coordinator = context.coordinator
        coordinator.attach(to: textView, in: scrollView)
        coordinator.setTemplateMenu(templateMenu)
        coordinator.apply(EditorTheme(self))
        coordinator.load(text)
        coordinator.setHighlights(highlights)
        coordinator.onDismissHighlight = onDismissHighlight
        coordinator.focusKey = focusKey
        coordinator.canTakeFocus = canTakeFocus
        textView.focusWhenAttached = canTakeFocus
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        if let textView = scrollView.documentView as? NSTextView,
           textView.textContainerInset.height != verticalInset {
            textView.textContainerInset = NSSize(width: 0, height: verticalInset)
        }
        coordinator.binding = $text
        coordinator.onDismissHighlight = onDismissHighlight
        coordinator.setEditable(isEditable)
        coordinator.setTemplateMenu(templateMenu)

        let theme = EditorTheme(self)
        if theme != coordinator.theme {
            coordinator.apply(theme)
        }
        // Only an outside change (another entry loaded) replaces the string, so the
        // caret survives ordinary SwiftUI updates. A new entry always reloads, even with
        // identical text, so the previous entry's undo stack can't edit it.
        if text != coordinator.lastText || focusKey != coordinator.focusKey {
            coordinator.load(text)
        }
        if highlights != coordinator.sourceHighlights {
            coordinator.setHighlights(highlights)
        }
        let regainedFocus = canTakeFocus && !coordinator.canTakeFocus
        coordinator.canTakeFocus = canTakeFocus
        if focusKey != coordinator.focusKey || regainedFocus {
            coordinator.focusKey = focusKey
            if canTakeFocus {
                coordinator.focus()
            }
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.closePopover()
        coordinator.templateMenu?.close()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var binding: Binding<String>?
        var theme: EditorTheme?
        var lastText = ""
        var focusKey: AnyHashable?
        var canTakeFocus = true
        var onDismissHighlight: ((String) -> Void)?
        /// Highlights as last passed in, and as currently drawn (moved along with edits).
        private(set) var sourceHighlights: [EditorHighlight] = []
        private var drawnHighlights: [EditorHighlight] = []

        private weak var textView: WritingTextView?
        private let undoManager = UndoManager()
        private(set) weak var templateMenu: TemplateMenuController?
        /// Where a "/" that may open the template menu is being typed (set just before the edit).
        private var pendingSlash: Int?
        private var popover: NSPopover?
        private var popoverHighlightId: String?

        func attach(to textView: WritingTextView, in scrollView: NSScrollView) {
            self.textView = textView
            textView.delegate = self
            textView.textStorage?.delegate = self
            textView.onHover = { [weak self] point in
                self?.hover(at: point)
            }
            textView.highlightMenuItem = { [weak self] point in
                self?.dismissMenuItem(at: point)
            }
            textView.underlineSegments = { [weak self] in
                self?.underlineSegments() ?? []
            }
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrolled),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        // MARK: Text

        func load(_ text: String) {
            guard let textView else { return }
            lastText = text
            closePopover()
            templateMenu?.close()
            textView.string = text  // styled by the storage delegate
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scroll(.zero)
            undoManager.removeAllActions()
            drawnHighlights = sourceHighlights
            drawHighlights()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            let string = textView.string
            lastText = string
            binding?.wrappedValue = string
            refreshTemplateMenu()
            pendingSlash = nil
        }

        func setEditable(_ isEditable: Bool) {
            guard let textView, textView.isEditable != isEditable else { return }
            textView.isEditable = isEditable
            if !isEditable {
                templateMenu?.close()
            }
        }

        // MARK: Template menu

        func setTemplateMenu(_ menu: TemplateMenuController?) {
            guard menu !== templateMenu else { return }
            templateMenu?.close()
            templateMenu = menu
            menu?.insertHandler = { [weak self] template in
                self?.insertTemplate(template)
            }
            menu?.openAtCaretHandler = { [weak self] in
                self?.openTemplateMenuAtCaret() ?? false
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            // A "/" typed at the start of a line or after whitespace opens the menu once it's in.
            pendingSlash = nil
            if replacementString == "/", range.length == 0, textView.isEditable, !textView.hasMarkedText(),
               let menu = templateMenu, !menu.isOpen,
               SlashTrigger.opens(at: range.location, in: textView.string as NSString) {
                pendingSlash = range.location
            }
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            refreshTemplateMenu()
        }

        /// Opens the menu after a trigger "/", keeps its query and position current, or closes it
        /// when the caret left the query.
        private func refreshTemplateMenu() {
            guard let textView, let menu = templateMenu else { return }
            let string = textView.string as NSString
            // Selection and text notifications can come in either order; open on the first one
            // that sees the "/" in place (textDidChange drops the pending trigger after).
            if let slash = pendingSlash, !menu.isOpen, slash < string.length, string.character(at: slash) == 0x2F,
               textView.selectedRange() == NSRange(location: slash + 1, length: 0) {
                pendingSlash = nil
                menu.open(slash: slash, queryStart: slash + 1, anchor: anchorRect(at: slash, hasSlash: true), in: textView.window)
            }
            guard let session = menu.session else { return }
            guard textView.isEditable,
                  let query = SlashTrigger.query(in: string, slashAt: session.slash, queryStart: session.queryStart, caret: textView.selectedRange()) else {
                menu.close()
                return
            }
            menu.update(query: query, anchor: anchorRect(at: session.slash ?? session.queryStart, hasSlash: session.slash != nil))
        }

        /// The line of the "/" (or the caret), in the window content view's top-left coordinates.
        private func anchorRect(at location: Int, hasSlash: Bool) -> CGRect {
            guard let textView, let window = textView.window else { return .zero }
            let length = hasSlash ? 1 : 0
            var rect = textView.firstRect(forCharacterRange: NSRange(location: location, length: length), actualRange: nil)
            if rect.height == 0 {
                rect.size.height = textView.font?.boundingRectForFont.height ?? 18
            }
            return TemplateMenuController.contentRect(fromScreen: rect, in: window)
        }

        /// Replaces "/query" with the expanded template as one undoable edit, caret at `{{cursor}}`.
        private func insertTemplate(_ template: WritingTemplate) {
            guard let textView, let menu = templateMenu, let session = menu.session else { return }
            let caret = textView.selectedRange()
            let start = session.slash ?? session.queryStart
            menu.close()
            guard textView.isEditable, caret.length == 0, caret.location >= start else { return }
            let range = NSRange(location: start, length: caret.location - start)
            let expanded = TemplateExpander.expand(template.body)
            // Its own undo step: ⌘Z brings back "/query", not less, not more.
            textView.breakUndoCoalescing()
            textView.insertText(expanded.text, replacementRange: range)
            textView.breakUndoCoalescing()
            let location = start + expanded.caret
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            // Same event, so its font/size change joins the insertion's undo group.
            menu.didInsertHandler?(template, textView.undoManager)
        }

        /// Insert Template…: opens the menu at the caret, no "/" typed. False when the editor
        /// can't take text right now.
        private func openTemplateMenuAtCaret() -> Bool {
            guard let textView, let window = textView.window, textView.isEditable,
                  !textView.hasMarkedText(), let menu = templateMenu else { return false }
            if window.firstResponder !== textView {
                window.makeFirstResponder(textView)
            }
            let selection = textView.selectedRange()
            let caret = NSMaxRange(selection)
            if selection.length > 0 {
                textView.setSelectedRange(NSRange(location: caret, length: 0))
            }
            menu.close()
            menu.open(slash: nil, queryStart: caret, anchor: anchorRect(at: caret, hasSlash: false), in: window)
            return true
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let menu = templateMenu, menu.isOpen else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                menu.move(1)
            case #selector(NSResponder.moveUp(_:)):
                menu.move(-1)
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                guard menu.chooseHighlighted() else {
                    menu.close()
                    return false
                }
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
                menu.close()
            default:
                return false
            }
            return true
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            undoManager
        }

        // Styling only touches attributes, so the string (and the saved file) is
        // unchanged and nothing is registered with the undo manager.
        nonisolated func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            // The editor's storage is only ever edited on the main thread.
            nonisolated(unsafe) let storage = textStorage
            MainActor.assumeIsolated {
                guard let theme else { return }
                MarkdownRenderer.style(storage, in: editedRange, theme: theme)
                guard !drawnHighlights.isEmpty else { return }
                drawnHighlights = EditorHighlight.adjust(drawnHighlights, for: editedRange, changeInLength: delta)
                closePopover()
                // Redraw once the storage has finished processing this edit.
                DispatchQueue.main.async { [weak self] in
                    self?.drawHighlights()
                }
            }
        }

        // MARK: Theme

        func apply(_ theme: EditorTheme) {
            self.theme = theme
            guard let textView, let storage = textView.textStorage else { return }
            textView.typingAttributes = MarkdownRenderer.baseAttributes(theme)
            textView.insertionPointColor = theme.textColor
            storage.beginEditing()
            MarkdownRenderer.style(storage, in: NSRange(location: 0, length: storage.length), theme: theme)
            storage.endEditing()
            popover?.appearance = theme.appearance
        }

        // MARK: Focus

        func focus() {
            DispatchQueue.main.async { [weak self] in
                guard let textView = self?.textView, let window = textView.window else { return }
                if window.firstResponder !== textView {
                    window.makeFirstResponder(textView)
                }
            }
        }

        // MARK: Highlights

        func setHighlights(_ highlights: [EditorHighlight]) {
            sourceHighlights = highlights
            drawnHighlights = highlights
            closePopover()
            drawHighlights()
        }

        private func drawHighlights() {
            guard let textView, let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager else { return }
            layoutManager.removeRenderingAttribute(.backgroundColor, for: contentManager.documentRange)
            for highlight in drawnHighlights {
                guard let textRange = textRange(for: highlight.range) else { continue }
                layoutManager.addRenderingAttribute(.backgroundColor, value: highlight.color, for: textRange)
            }
            // TextKit 2 doesn't draw underline rendering attributes, so squiggles are drawn by an overlay.
            textView.underlinesChanged()
        }

        /// Line segments (text view coordinates) of the highlights that want a squiggle.
        private func underlineSegments() -> [(rect: NSRect, color: NSColor)] {
            guard let textView, let layoutManager = textView.textLayoutManager else { return [] }
            let origin = textView.textContainerOrigin
            var segments: [(rect: NSRect, color: NSColor)] = []
            for highlight in drawnHighlights {
                guard let color = highlight.underlineColor, let textRange = textRange(for: highlight.range) else { continue }
                layoutManager.enumerateTextSegments(in: textRange, type: .highlight, options: []) { _, frame, _, _ in
                    segments.append((frame.offsetBy(dx: origin.x, dy: origin.y), color))
                    return true
                }
            }
            return segments
        }

        /// nil for empty ranges or ranges outside the current string.
        private func textRange(for range: NSRange) -> NSTextRange? {
            guard let textView, range.length > 0,
                  NSMaxRange(range) <= (textView.textStorage?.length ?? 0),
                  let contentManager = textView.textLayoutManager?.textContentManager,
                  let start = contentManager.location(contentManager.documentRange.location, offsetBy: range.location),
                  let end = contentManager.location(start, offsetBy: range.length) else { return nil }
            return NSTextRange(location: start, end: end)
        }

        // MARK: Hover

        private func hover(at point: NSPoint?) {
            guard let point, let (highlight, rect) = highlight(at: point) else {
                closePopover()
                return
            }
            showPopover(for: highlight, at: rect)
        }

        /// The highlight under `point` (text view coordinates) and the rect of its line segment there.
        private func highlight(at point: NSPoint) -> (EditorHighlight, NSRect)? {
            guard let textView, !drawnHighlights.isEmpty else { return nil }
            let index = textView.characterIndexForInsertion(at: point)
            // The insertion index rounds to the nearest boundary, so check both sides.
            let candidates = drawnHighlights.filter {
                NSLocationInRange(index, $0.range) || NSLocationInRange(index - 1, $0.range)
            }
            for highlight in candidates {
                if let rect = segmentRect(of: highlight.range, containing: point) {
                    return (highlight, rect)
                }
            }
            return nil
        }

        private func dismissMenuItem(at point: NSPoint) -> NSMenuItem? {
            guard onDismissHighlight != nil, let (highlight, _) = highlight(at: point) else { return nil }
            let item = NSMenuItem(title: "Dismiss Note", action: #selector(dismissHighlight(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = highlight.id
            return item
        }

        @objc private func dismissHighlight(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            closePopover()
            onDismissHighlight?(id)
        }

        /// The on-screen rect (text view coordinates) of the line segment of `range` under `point`.
        private func segmentRect(of range: NSRange, containing point: NSPoint) -> NSRect? {
            guard let textView, let layoutManager = textView.textLayoutManager,
                  let textRange = textRange(for: range) else { return nil }
            let origin = textView.textContainerOrigin
            var hit: NSRect?
            layoutManager.enumerateTextSegments(in: textRange, type: .highlight, options: []) { _, frame, _, _ in
                let rect = frame.offsetBy(dx: origin.x, dy: origin.y)
                if rect.contains(point) {
                    hit = rect
                    return false
                }
                return true
            }
            return hit
        }

        private func showPopover(for highlight: EditorHighlight, at rect: NSRect) {
            guard let textView else { return }
            if popoverHighlightId == highlight.id, popover?.isShown == true { return }
            closePopover()
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = false
            popover.appearance = theme?.appearance
            let controller = NSHostingController(rootView: HighlightCommentView(
                title: highlight.title,
                titleColor: highlight.titleColor,
                comment: highlight.comment,
                hint: onDismissHighlight == nil ? nil : "Right-click to dismiss"
            ))
            controller.sizingOptions = .preferredContentSize
            popover.contentViewController = controller
            popover.show(relativeTo: rect, of: textView, preferredEdge: .minY)
            self.popover = popover
            popoverHighlightId = highlight.id
        }

        func closePopover() {
            popover?.close()
            popover = nil
            popoverHighlightId = nil
        }

        @objc private func scrolled() {
            closePopover()
            // The menu follows its line.
            if templateMenu?.isOpen == true {
                refreshTemplateMenu()
            }
        }
    }
}

// MARK: - Theme

struct EditorTheme: Equatable {
    let font: NSFont
    let lineSpacing: CGFloat
    let textColor: NSColor
    let isDark: Bool

    @MainActor
    init(_ editor: WritingEditor) {
        font = editor.font
        lineSpacing = editor.lineSpacing
        textColor = editor.textColor
        isDark = editor.isDark
    }

    var appearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

// MARK: - Text view

final class WritingTextView: NSTextView {
    var onHover: ((NSPoint?) -> Void)?
    /// An extra context-menu item for the point clicked (e.g. dismissing the highlight there).
    var highlightMenuItem: ((NSPoint) -> NSMenuItem?)?
    /// Become first responder as soon as the view lands in a window.
    var focusWhenAttached = false
    /// Where to draw squiggly underlines (grammar notes), asked for on every redraw.
    var underlineSegments: (() -> [(rect: NSRect, color: NSColor)])?
    private var hoverTrackingArea: NSTrackingArea?
    private lazy var underlineOverlay: UnderlineOverlayView = {
        let overlay = UnderlineOverlayView(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.segments = { [weak self] in self?.underlineSegments?() ?? [] }
        return overlay
    }()

    /// Redraws the squiggles (after highlights, text or layout changed).
    func underlinesChanged() {
        if underlineOverlay.superview !== self {
            addSubview(underlineOverlay, positioned: .above, relativeTo: nil)
        }
        underlineOverlay.needsDisplay = true
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        // TextKit 2 adds fragment views as it lays out; keep the squiggles above the text.
        if subview !== underlineOverlay, underlineOverlay.superview === self {
            addSubview(underlineOverlay, positioned: .above, relativeTo: nil)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Rewrapped lines move the squiggles.
        if underlineOverlay.superview === self {
            underlineOverlay.needsDisplay = true
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusWhenAttached, let window else { return }
        focusWhenAttached = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(self)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let item = highlightMenuItem?(convert(event.locationInWindow, from: nil)) else { return menu }
        let result = menu ?? NSMenu()
        result.insertItem(item, at: 0)
        if result.items.count > 1 {
            result.insertItem(.separator(), at: 1)
        }
        return result
    }
}

/// Draws wavy underlines, like a spelling mark, on top of the text. Never takes clicks.
final class UnderlineOverlayView: NSView {
    var segments: (() -> [(rect: NSRect, color: NSColor)])?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        for segment in segments?() ?? [] where segment.rect.intersects(dirtyRect.insetBy(dx: 0, dy: -4)) {
            let path = NSBezierPath()
            let amplitude: CGFloat = 1.3
            let wavelength: CGFloat = 4
            let y = segment.rect.maxY - 1.5
            var x = segment.rect.minX
            path.move(to: NSPoint(x: x, y: y))
            var up = true
            while x < segment.rect.maxX {
                let next = min(x + wavelength / 2, segment.rect.maxX)
                path.curve(to: NSPoint(x: next, y: y),
                           controlPoint1: NSPoint(x: x + wavelength / 4, y: y + (up ? -amplitude : amplitude) * 2),
                           controlPoint2: NSPoint(x: next - wavelength / 4, y: y + (up ? -amplitude : amplitude) * 2))
                x = next
                up.toggle()
            }
            path.lineWidth = 1.2
            segment.color.setStroke()
            path.stroke()
        }
    }
}

private struct HighlightCommentView: View {
    var title: String? = nil
    var titleColor: NSColor? = nil
    let comment: String
    var hint: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                HStack(spacing: 6) {
                    if let titleColor {
                        Circle()
                            .fill(Color(nsColor: titleColor))
                            .frame(width: 7, height: 7)
                    }
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Text(comment)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
        .padding(12)
    }
}

// MARK: - Markdown rendering

/// Turns `MarkdownStyler` spans into text attributes.
@MainActor
enum MarkdownRenderer {
    private static let headingScale: [CGFloat] = [1.6, 1.4, 1.25, 1.12, 1.05, 1.0]

    static func baseAttributes(_ theme: EditorTheme) -> [NSAttributedString.Key: Any] {
        [
            .font: theme.font,
            .foregroundColor: theme.textColor,
            .paragraphStyle: paragraphStyle(theme, indent: 0),
        ]
    }

    /// Restyles the whole lines covered by `range`.
    static func style(_ storage: NSTextStorage, in range: NSRange, theme: EditorTheme) {
        let string = storage.string as NSString
        let target = string.paragraphRange(for: range)
        guard target.length > 0 else { return }

        // Reset only the keys we own so marked (IME) text keeps its underline.
        storage.addAttributes(baseAttributes(theme), range: target)
        for key in [NSAttributedString.Key.strikethroughStyle, .strikethroughColor, .obliqueness, .strokeWidth] {
            storage.removeAttribute(key, range: target)
        }

        let dimmed = theme.textColor.withAlphaComponent(0.35)
        for span in MarkdownStyler.spans(in: string, range: target) {
            let range = span.range
            switch span.style {
            case .heading(let level):
                let size = theme.font.pointSize * headingScale[min(max(level, 1), 6) - 1]
                let font = NSFontManager.shared.convert(theme.font, toSize: size)
                storage.addAttribute(.font, value: font, range: range)
                addTrait(.boldFontMask, to: storage, in: range)
            case .bold:
                addTrait(.boldFontMask, to: storage, in: range)
            case .italic:
                addTrait(.italicFontMask, to: storage, in: range)
            case .code:
                storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                    let size = (value as? NSFont)?.pointSize ?? theme.font.pointSize
                    storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size * 0.88, weight: .regular), range: subrange)
                }
            case .quote:
                storage.addAttributes([
                    .foregroundColor: theme.textColor.withAlphaComponent(0.6),
                    .paragraphStyle: paragraphStyle(theme, indent: theme.font.pointSize * 0.8),
                ], range: range)
            case .listMarker:
                storage.addAttribute(.foregroundColor, value: theme.textColor.withAlphaComponent(0.5), range: range)
            case .strikethrough:
                storage.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: theme.textColor.withAlphaComponent(0.6),
                ], range: range)
            case .link:
                let link = theme.textColor.blended(withFraction: 0.45, of: .systemBlue) ?? theme.textColor
                storage.addAttribute(.foregroundColor, value: link, range: range)
            case .syntax:
                storage.addAttribute(.foregroundColor, value: dimmed, range: range)
            }
        }
    }

    private static func paragraphStyle(_ theme: EditorTheme, indent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = theme.lineSpacing
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        return style
    }

    /// Bold/italic via the font family when it has the face, otherwise synthesized.
    private static func addTrait(_ trait: NSFontTraitMask, to storage: NSTextStorage, in range: NSRange) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard let font = value as? NSFont else { return }
            if let converted = converted(font, adding: trait) {
                storage.addAttribute(.font, value: converted, range: subrange)
            } else if trait == .boldFontMask {
                storage.addAttribute(.strokeWidth, value: -3.0, range: subrange)
            } else {
                storage.addAttribute(.obliqueness, value: 0.2, range: subrange)
            }
        }
    }

    // Font conversion is the expensive part of a full restyle; a long entry asks
    // for the same handful of faces thousands of times.
    private static var traitCache: [String: NSFont?] = [:]

    /// `font` with `trait`, or nil when the family has no such face.
    private static func converted(_ font: NSFont, adding trait: NSFontTraitMask) -> NSFont? {
        let key = "\(font.fontName)|\(font.pointSize)|\(trait.rawValue)"
        if let cached = traitCache[key] {
            return cached
        }
        let manager = NSFontManager.shared
        let converted = manager.convert(font, toHaveTrait: trait)
        let result = manager.traits(of: converted).contains(trait) ? converted : nil
        traitCache[key] = result
        return result
    }
}
