//
//  WordCountTests.swift
//  freewriteTests
//
//  The bottom bar's word/character count and focus mode's scroll gesture.
//

import Foundation
import Testing
@testable import freewrite

struct TextCountTests {
    private func words(_ text: String) -> Int { TextCount(text).words }

    @Test func plainText() {
        #expect(words("") == 0)
        #expect(words("   \n\t ") == 0)
        #expect(words("hello") == 1)
        #expect(words("  hello   world \n again ") == 3)
        #expect(words("Hello, world! How are you?") == 5)
    }

    @Test func joinersInsideWords() {
        #expect(words("don't stop") == 2)
        #expect(words("don\u{2019}t") == 1)
        #expect(words("well-known snake_case") == 2)
        #expect(words("end - start") == 2)
        #expect(words("a--b") == 2)
        #expect(words("pi is 3.14, about 1,000 times") == 6)
        #expect(words("end.Next") == 2)
    }

    @Test func markdownMarkersAreNotWords() {
        #expect(words("# Title") == 1)
        #expect(words("**bold** and _italic_") == 3)
        #expect(words("- item\n- other\n> quote\n---") == 3)
        #expect(words("`code` [link](notes)") == 3)
    }

    @Test func chineseAndJapaneseCountPerCharacter() {
        #expect(words("我爱你") == 3)
        #expect(words("今日はいい天気") == 7)
        #expect(words("カタカナ") == 4)
        #expect(words("I said 你好 today") == 5)
        // Korean uses spaces.
        #expect(words("안녕하세요 세계") == 2)
    }

    @Test func emojiAndAccents() {
        #expect(words("🎉") == 0)
        #expect(words("I ❤️ you") == 2)
        #expect(words("cafe\u{301} na\u{EF}ve") == 2)
        #expect(TextCount("👍🏽").characters == 1)
        #expect(TextCount("👨‍👩‍👧").characters == 1)
        #expect(TextCount("e\u{301}").characters == 1)
        #expect(TextCount("a b\n").characters == 4)
    }

    @Test func labels() {
        let locale = Locale(identifier: "en_US")
        #expect(TextCount("one").label(.words, locale: locale) == "1 word")
        #expect(TextCount("").label(.words, locale: locale) == "0 words")
        #expect(TextCount("a").label(.characters, locale: locale) == "1 character")
        #expect(TextCount(String(repeating: "word ", count: 1204)).label(.words, locale: locale) == "1,204 words")
        #expect(TextCount("hi").label(.characters, locale: locale) == "2 characters")
        #expect(TextCount.Unit.words.toggled == .characters)
        #expect(TextCount.Unit.characters.toggled == .words)
    }

    @Test func measureMatchesInit() async {
        let text = String(repeating: "Lorem ipsum dolor sit amet. ", count: 5000)
        let count = await TextCount.measure(text)
        #expect(count == TextCount(text))
        #expect(count.words == 25_000)
    }
}

struct FocusScrollGestureTests {
    @Test func trackpadNeedsADeliberateSwipe() {
        var gesture = FocusScrollGesture()
        #expect(gesture.add(deltaY: -10, isPrecise: true, phase: .began, isMomentum: false, time: 0) == nil)
        #expect(gesture.add(deltaY: -20, isPrecise: true, phase: .changed, isMomentum: false, time: 0.01) == nil)
        #expect(gesture.add(deltaY: -40, isPrecise: true, phase: .changed, isMomentum: false, time: 0.02) == .down)
        // Fires once per gesture.
        #expect(gesture.add(deltaY: -80, isPrecise: true, phase: .changed, isMomentum: false, time: 0.03) == nil)
        #expect(gesture.add(deltaY: 200, isPrecise: true, phase: .changed, isMomentum: false, time: 0.04) == nil)
        _ = gesture.add(deltaY: 0, isPrecise: true, phase: .ended, isMomentum: false, time: 0.05)
        // A new gesture can fire again, the other way.
        #expect(gesture.add(deltaY: 30, isPrecise: true, phase: .began, isMomentum: false, time: 1) == nil)
        #expect(gesture.add(deltaY: 40, isPrecise: true, phase: .changed, isMomentum: false, time: 1.01) == .up)
    }

    @Test func smallSwipesAndMomentumDontToggle() {
        var gesture = FocusScrollGesture()
        _ = gesture.add(deltaY: -25, isPrecise: true, phase: .began, isMomentum: false, time: 0)
        #expect(gesture.add(deltaY: -25, isPrecise: true, phase: .ended, isMomentum: false, time: 0.1) == nil)
        // The glide after the fingers lift never counts.
        for step in 0..<20 {
            #expect(gesture.add(deltaY: -30, isPrecise: true, phase: .none, isMomentum: true, time: 0.2 + Double(step) / 100) == nil)
        }
        // A short swipe after the last one starts from zero.
        #expect(gesture.add(deltaY: -25, isPrecise: true, phase: .began, isMomentum: false, time: 1) == nil)
    }

    @Test func changingDirectionStartsOver() {
        var gesture = FocusScrollGesture()
        _ = gesture.add(deltaY: -50, isPrecise: true, phase: .began, isMomentum: false, time: 0)
        #expect(gesture.add(deltaY: 30, isPrecise: true, phase: .changed, isMomentum: false, time: 0.01) == nil)
        #expect(gesture.add(deltaY: 25, isPrecise: true, phase: .changed, isMomentum: false, time: 0.02) == nil)
        #expect(gesture.add(deltaY: 10, isPrecise: true, phase: .changed, isMomentum: false, time: 0.03) == .up)
    }

    @Test func mouseWheelNeedsTwoNotchesInARow() {
        var gesture = FocusScrollGesture()
        #expect(gesture.add(deltaY: -1, isPrecise: false, phase: .none, isMomentum: false, time: 0) == nil)
        // A pause: the next notch is a new gesture.
        #expect(gesture.add(deltaY: -1, isPrecise: false, phase: .none, isMomentum: false, time: 1) == nil)
        #expect(gesture.add(deltaY: -1, isPrecise: false, phase: .none, isMomentum: false, time: 1.1) == .down)
        #expect(gesture.add(deltaY: -1, isPrecise: false, phase: .none, isMomentum: false, time: 1.2) == nil)
        #expect(gesture.add(deltaY: 1, isPrecise: false, phase: .none, isMomentum: false, time: 2) == nil)
        #expect(gesture.add(deltaY: 1, isPrecise: false, phase: .none, isMomentum: false, time: 2.1) == .up)
    }
}
