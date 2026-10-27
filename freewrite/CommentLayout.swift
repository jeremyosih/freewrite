//
//  CommentLayout.swift
//  freewrite
//
//  Pure geometry of the comment margin (CommentMargin.swift): where each card goes so cards
//  sit next to their highlight without overlapping, and the connector from a card to its text.
//

import CoreGraphics

enum CommentCardLayout {
    struct Item: Equatable, Sendable {
        var id: String
        /// Where the card would like its top edge: the top of its highlight's first line.
        var target: CGFloat
        var height: CGFloat
    }

    /// The top of every card, keyed by id. Cards keep the order of their targets (ties keep the
    /// order given) and never overlap: each is at least `spacing` below the one before.
    /// Without an `anchorId`, cards only ever move down from their target, like Google Docs.
    /// With one (the active card), that card sits exactly at its target; the cards after it are
    /// pushed down and the cards before it pushed up to make room.
    static func place(_ items: [Item], spacing: CGFloat = 8, anchorId: String? = nil) -> [String: CGFloat] {
        let sorted = items.enumerated()
            .sorted { $0.element.target != $1.element.target ? $0.element.target < $1.element.target : $0.offset < $1.offset }
            .map(\.element)
        guard !sorted.isEmpty else { return [:] }
        var tops = sorted.map(\.target)
        let pivot = anchorId.flatMap { id in sorted.firstIndex { $0.id == id } } ?? 0
        if pivot + 1 < sorted.count {
            for index in (pivot + 1)..<sorted.count {
                tops[index] = max(sorted[index].target, tops[index - 1] + sorted[index - 1].height + spacing)
            }
        }
        if pivot > 0 {
            for index in stride(from: pivot - 1, through: 0, by: -1) {
                tops[index] = min(sorted[index].target, tops[index + 1] - spacing - sorted[index].height)
            }
        }
        var result: [String: CGFloat] = [:]
        for (item, top) in zip(sorted, tops) where result[item.id] == nil {
            result[item.id] = top
        }
        return result
    }
}

enum CommentConnector {
    /// The line from a card to its highlight, in one coordinate space, for a column on the left
    /// of the text: out of the card's right edge at `cardY`, across the gutter to the text's
    /// left edge at the highlight's line (drawn as a curve: the first four points are its start,
    /// two control points and its end), then (emphasized only) along the bottom of that line to
    /// where the highlight starts, so the line runs under the text rather than through it.
    static func points(cardRightX: CGFloat, cardY: CGFloat, textLeftX: CGFloat, highlight: CGRect, emphasized: Bool) -> [CGPoint] {
        let lineY = highlight.midY
        let elbowX = cardRightX + max((textLeftX - cardRightX) * 0.5, 0)
        var points = [
            CGPoint(x: cardRightX, y: cardY),
            CGPoint(x: elbowX, y: cardY),
            CGPoint(x: elbowX, y: lineY),
            CGPoint(x: textLeftX, y: lineY),
        ]
        if emphasized, highlight.minX > textLeftX {
            points[3] = CGPoint(x: textLeftX, y: highlight.maxY)
            points[2] = CGPoint(x: elbowX, y: highlight.maxY)
            points.append(CGPoint(x: highlight.minX, y: highlight.maxY))
        }
        return points
    }
}
