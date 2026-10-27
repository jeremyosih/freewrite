//
//  CommentLayoutTests.swift
//  freewriteTests
//

import CoreGraphics
import Testing
@testable import freewrite

struct CommentLayoutTests {
    private typealias Item = CommentCardLayout.Item

    private func assertNoOverlap(_ items: [Item], _ tops: [String: CGFloat], spacing: CGFloat = 8) {
        let placed = items.map { ($0, tops[$0.id]!) }.sorted { $0.1 < $1.1 }
        for (upper, lower) in zip(placed, placed.dropFirst()) {
            #expect(upper.1 + upper.0.height + spacing <= lower.1 + 0.0001)
        }
    }

    @Test func spreadOutCardsSitAtTheirTargets() {
        let items = [Item(id: "a", target: 0, height: 40), Item(id: "b", target: 100, height: 40)]
        #expect(CommentCardLayout.place(items) == ["a": 0, "b": 100])
        #expect(CommentCardLayout.place([]) == [:])
    }

    @Test func crowdedCardsStackDownwards() {
        let items = [
            Item(id: "a", target: 10, height: 50),
            Item(id: "b", target: 20, height: 30),
            Item(id: "c", target: 30, height: 30),
            Item(id: "d", target: 300, height: 30),
        ]
        let tops = CommentCardLayout.place(items)
        #expect(tops == ["a": 10, "b": 68, "c": 106, "d": 300])
        assertNoOverlap(items, tops)
    }

    @Test func orderFollowsTargetsAndTiesKeepTheGivenOrder() {
        let items = [
            Item(id: "late", target: 200, height: 20),
            Item(id: "first", target: 50, height: 20),
            Item(id: "second", target: 50, height: 20),
        ]
        let tops = CommentCardLayout.place(items, spacing: 4)
        #expect(tops["first"] == 50)
        #expect(tops["second"] == 74)
        #expect(tops["late"] == 200)
    }

    @Test func activeCardSitsAtItsTargetAndPushesOthersAway() {
        let items = [
            Item(id: "a", target: 0, height: 60),
            Item(id: "b", target: 20, height: 60),
            Item(id: "c", target: 40, height: 60),
        ]
        let tops = CommentCardLayout.place(items, anchorId: "b")
        #expect(tops["b"] == 20)
        #expect(tops["a"] == -48)  // pushed up above the active card
        #expect(tops["c"] == 88)
        assertNoOverlap(items, tops)
        // An unknown id lays out like no anchor at all.
        #expect(CommentCardLayout.place(items, anchorId: "zzz") == CommentCardLayout.place(items))
    }

    @Test func connectorRunsFromTheCardToTheTextEdge() {
        let highlight = CGRect(x: 300, y: 100, width: 80, height: 20)
        let plain = CommentConnector.points(cardRightX: 100, cardY: 140, textLeftX: 200, highlight: highlight, emphasized: false)
        #expect(plain.first == CGPoint(x: 100, y: 140))
        #expect(plain.last == CGPoint(x: 200, y: 110))
        #expect(plain.count == 4)
        // Emphasized, it continues under the line to where the highlight starts.
        let active = CommentConnector.points(cardRightX: 100, cardY: 140, textLeftX: 200, highlight: highlight, emphasized: true)
        #expect(active.last == CGPoint(x: 300, y: 120))
        #expect(active.dropLast().last == CGPoint(x: 200, y: 120))
    }
}
