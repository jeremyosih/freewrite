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
    /// The editor takes focus again whenever this changes (e.g. the selected entry).
    var focusKey: AnyHashable? = nil
    /// False while something else (the ⌘K palette) owns the keyboard.
    var canTakeFocus: Bool = true

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
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
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
        coordinator.apply(EditorTheme(self))
        coordinator.load(text)
        coordinator.setHighlights(highlights)
        coordinator.focusKey = focusKey
        coordinator.canTakeFocus = canTakeFocus
        textView.focusWhenAttached = canTakeFocus
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.binding = $text

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
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var binding: Binding<String>?
        var theme: EditorTheme?
        var lastText = ""
        var focusKey: AnyHashable?
        var canTakeFocus = true
        /// Highlights as last passed in, and as currently drawn (moved along with edits).
        private(set) var sourceHighlights: [EditorHighlight] = []
        private var drawnHighlights: [EditorHighlight] = []

        private weak var textView: WritingTextView?
        private let undoManager = UndoManager()
        private var popover: NSPopover?
        private var popoverHighlightId: String?

        func attach(to textView: WritingTextView, in scrollView: NSScrollView) {
            self.textView = textView
            textView.delegate = self
            textView.textStorage?.delegate = self
            textView.onHover = { [weak self] point in
                self?.hover(at: point)
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
            guard let point, let textView, !drawnHighlights.isEmpty else {
                closePopover()
                return
            }
            let index = textView.characterIndexForInsertion(at: point)
            // The insertion index rounds to the nearest boundary, so check both sides.
            let candidates = drawnHighlights.filter {
                NSLocationInRange(index, $0.range) || NSLocationInRange(index - 1, $0.range)
            }
            for highlight in candidates {
                if let rect = segmentRect(of: highlight.range, containing: point) {
                    showPopover(for: highlight, at: rect)
                    return
                }
            }
            closePopover()
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
            let controller = NSHostingController(rootView: HighlightCommentView(comment: highlight.comment))
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
    /// Become first responder as soon as the view lands in a window.
    var focusWhenAttached = false
    private var hoverTrackingArea: NSTrackingArea?

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
}

private struct HighlightCommentView: View {
    let comment: String

    var body: some View {
        Text(comment)
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)
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
