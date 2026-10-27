//
//  BarLayoutTests.swift
//  freewriteTests
//
//  Stored bottom-bar layouts picking up items added later, and voice-note waveform buckets.
//

import AVFoundation
import Foundation
import Testing
@testable import freewrite

struct BottomBarLayoutDecodeTests {
    private func stored(_ items: [(String, String)]) -> String {
        let slots = items.map { #"{"item":"\#($0.0)","placement":"\#($0.1)"}"# }
        return #"{"slots":["# + slots.joined(separator: ",") + "]}"
    }

    @Test func reviewAndLockLandBeforeHistoryAndSettings() {
        // A layout saved before Review and Lock existed.
        let json = stored([
            ("versions", "left"), ("timer", "right"), ("recordVideo", "right"), ("recordVoiceNote", "right"),
            ("backspace", "right"), ("fullscreen", "right"), ("newEntry", "right"), ("history", "right"),
            ("settings", "right"),
        ])
        let layout = BottomBarLayout.decode(json)
        #expect(layout.left == [.versions, .wordCount, .fontSize, .font])
        #expect(layout.right == [
            .timer, .recordVideo, .recordVoiceNote, .review, .backspace, .fullscreen, .newEntry, .history, .lock, .settings,
        ])
        #expect(layout.right.last == .settings)
    }

    @Test func newItemGoesBeforeTheEarliestStoredFollower() {
        // The user moved Settings before History: Review still lands before the gear.
        let json = stored([("versions", "left"), ("timer", "right"), ("settings", "right"), ("history", "right")])
        let items = BottomBarLayout.decode(json).slots.map(\.item)
        #expect(items.firstIndex(of: .review)! < items.firstIndex(of: .settings)!)
        #expect(items.firstIndex(of: .lock)! + 1 == items.firstIndex(of: .settings)!)
    }

    @Test func fontItemsLandOnTheLeftAfterVersions() {
        // A layout saved before Text Size and Font existed, with Timer moved to the left.
        let json = stored([
            ("versions", "left"), ("timer", "left"), ("recordVideo", "right"), ("review", "right"),
            ("history", "right"), ("lock", "right"), ("settings", "right"),
        ])
        let layout = BottomBarLayout.decode(json)
        #expect(layout.left == [.versions, .wordCount, .fontSize, .font, .timer])
        #expect(layout.right.last == .settings)
        // Versions hidden: they still come before the stored item that follows them.
        let hidden = BottomBarLayout.decode(stored([("timer", "right"), ("versions", "hidden"), ("settings", "right")]))
        let items = hidden.slots.map(\.item)
        #expect(items.firstIndex(of: .fontSize)! + 1 == items.firstIndex(of: .font)!)
        #expect(items.firstIndex(of: .font)! < items.firstIndex(of: .timer)!)
        #expect(hidden.slots.first { $0.item == .font }?.placement == .left)
    }

    @Test func defaultPutsFontControlsLeftAfterVersions() {
        #expect(BottomBarLayout.default.left == [.versions, .wordCount, .fontSize, .font])
        #expect(BottomBarLayout.default.right.last == .settings)
    }

    @Test func storedOrderAndPlacementsAreKept() {
        let json = stored([
            ("settings", "left"), ("review", "hidden"), ("timer", "right"), ("lock", "left"),
        ])
        let layout = BottomBarLayout.decode(json)
        let storedOrder = layout.slots.map(\.item).filter { [.settings, .review, .timer, .lock].contains($0) }
        #expect(storedOrder == [.settings, .review, .timer, .lock])
        #expect(layout.slots.first { $0.item == .review }?.placement == .hidden)
        #expect(layout.slots.first { $0.item == .lock }?.placement == .left)
        #expect(Set(layout.slots.map(\.item)) == Set(BottomBarItem.allCases))
        #expect(layout.slots.count == BottomBarItem.allCases.count)
    }

    @Test func unknownAndDuplicateItemsAreDropped() {
        let json = stored([("chat", "right"), ("timer", "right"), ("timer", "left"), ("settings", "sideways")])
        let layout = BottomBarLayout.decode(json)
        #expect(layout.slots.count == BottomBarItem.allCases.count)
        #expect(layout.slots.first { $0.item == .timer }?.placement == .right)
        // An unreadable placement drops the slot; Settings comes back at its default side.
        #expect(layout.right.last == .settings)
    }

    @Test func wordCountLandsLeftAfterVersions() {
        // A layout saved before Word Count existed.
        let json = stored([
            ("versions", "left"), ("timer", "right"), ("recordVideo", "right"), ("recordVoiceNote", "right"),
            ("review", "right"), ("backspace", "right"), ("fullscreen", "right"), ("newEntry", "right"),
            ("history", "right"), ("lock", "right"), ("settings", "right"),
        ])
        let layout = BottomBarLayout.decode(json)
        #expect(layout.slots.map(\.item).prefix(5) == [.versions, .wordCount, .fontSize, .font, .timer])
        #expect(layout.left == [.versions, .wordCount, .fontSize, .font])
        #expect(layout.right.last == .settings)
            }

    @Test func garbageGivesTheDefault() {
        #expect(BottomBarLayout.decode("not json") == .default)
        #expect(BottomBarLayout.decode(BottomBarLayout.default.encoded()) == .default)
    }
}

struct BottomBarModelTests {
    private let text = BottomBarContext(hasTextEntry: true)

    @Test func writingOnlyItemsAreHiddenOnVideo() {
        let video = BottomBarContext(isVideoEntry: true)
        for item in [BottomBarItem.versions, .wordCount, .recordVoiceNote, .review, .backspace, .lock] {
            #expect(!item.isVisible(in: video), "\(item)")
        }
        for item in [BottomBarItem.timer, .recordVideo, .fullscreen, .newEntry, .history, .settings] {
            #expect(item.isVisible(in: video), "\(item)")
        }
    }

    @Test func closedLockedNoteShowsNothingOfTheNote() {
        let closed = BottomBarContext(hasTextEntry: true, isNoteClosed: true, isNoteLocked: true)
        #expect(!BottomBarItem.versions.isVisible(in: closed))
        #expect(!BottomBarItem.wordCount.isVisible(in: closed))
        #expect(!BottomBarItem.recordVoiceNote.isVisible(in: closed))
        #expect(!BottomBarItem.review.isVisible(in: closed))
        #expect(BottomBarItem.lock.isVisible(in: closed))
        let open = BottomBarContext(hasTextEntry: true, isNoteClosed: false, isNoteLocked: true)
        #expect(BottomBarItem.wordCount.isVisible(in: open))
        #expect(!BottomBarItem.review.isVisible(in: open))
    }

    @Test func versionsNeedALoadedTextEntry() {
        // Before the first entry loads there's no manifest: the version button would be empty.
        let nothing = BottomBarContext()
        #expect(!BottomBarItem.versions.isVisible(in: nothing))
        #expect(BottomBarItem.versions.isVisible(in: text))
        let groups = BottomBarModel.groups(layout: .default, context: nothing)
        #expect(!groups.left.contains(.item(.versions)))
        #expect(groups.left.isEmpty)
    }

    @Test func groupsOnlyHoldVisibleItems() {
        let video = BottomBarContext(isVideoEntry: true)
        let groups = BottomBarModel.groups(layout: .default, context: video)
        #expect(groups.left.isEmpty)
        #expect(groups.right == [.item(.timer), .item(.recordVideo), .item(.fullscreen), .item(.newEntry), .item(.history), .item(.settings)])
    }

    @Test func overflowSitsBeforeTheGearOnlyWhenUsed() {
        let none = BottomBarModel.groups(layout: .default, context: text)
        #expect(!none.right.contains(.overflow))
        let some = BottomBarModel.groups(layout: .default, context: text, overflow: [.fullscreen, .wordCount])
        #expect(!some.right.contains(.item(.fullscreen)))
        #expect(!some.left.contains(.item(.wordCount)))
        #expect(some.right.suffix(2) == [.overflow, .item(.settings)])
        // Items that aren't visible never make an (empty) "…".
        let video = BottomBarContext(isVideoEntry: true)
        let hidden = BottomBarModel.groups(layout: .default, context: video, overflow: [.wordCount, .backspace])
        #expect(!hidden.right.contains(.overflow))
    }

    @Test func overflowCandidatesAreVisibleAndPlaced() {
        var layout = BottomBarLayout.default
        layout.slots[layout.slots.firstIndex { $0.item == .fullscreen }!].placement = .hidden
        let candidates = BottomBarModel.overflowCandidates(layout: layout, context: BottomBarContext(isVideoEntry: true))
        #expect(candidates == [.newEntry, .timer, .recordVideo, .history])
        #expect(!candidates.contains(.settings))
    }

    @Test func separatorsOnlyBetweenRenderedSlots() {
        // Every row of the bar, for a range of states: no leading, trailing or doubled `•`.
        let contexts = [
            BottomBarContext(), text, BottomBarContext(isVideoEntry: true),
            BottomBarContext(hasTextEntry: true, isNoteClosed: true, isNoteLocked: true),
        ]
        for context in contexts {
            let candidates = BottomBarModel.overflowCandidates(layout: .default, context: context)
            for count in 0...candidates.count {
                let groups = BottomBarModel.groups(layout: .default, context: context, overflow: Array(candidates.prefix(count)))
                for (slots, afterStatus) in [(groups.left, true), (groups.left, false), (groups.right, false)] {
                    var row: [String] = afterStatus ? ["status"] : []
                    for (index, slot) in slots.enumerated() {
                        if BottomBarModel.separatorBefore(index, afterStatus: afterStatus) { row.append("•") }
                        row.append("\(slot)")
                    }
                    #expect(row.first != "•" && row.last != "•")
                    #expect(!zip(row, row.dropFirst()).contains { $0 == "•" && $1 == "•" })
                }
            }
        }
    }
}

struct WaveformTests {
    @Test func bucketsSpreadEvenly() {
        var accumulator = WaveformAccumulator(count: 4, totalFrames: 8)
        // Loud, silent, quiet, loud.
        accumulator.add([1, 1, 0, 0, 0.1, 0.1, 1, 1] as [Float])
        let levels = accumulator.levels
        #expect(levels.count == 4)
        #expect(levels[0] == 1)
        #expect(levels[1] == 0)
        #expect(levels[3] == 1)
        #expect(levels[2] > 0 && levels[2] < 1)
    }

    @Test func silenceAndEmptyGiveZeros() {
        var silent = WaveformAccumulator(count: 3, totalFrames: 300)
        silent.add([Float](repeating: 0, count: 300))
        #expect(silent.levels == [0, 0, 0])
        #expect(WaveformAccumulator(count: 5, totalFrames: 0).levels == [0, 0, 0, 0, 0])
    }

    @Test func extraFramesGoToTheLastBucket() {
        var accumulator = WaveformAccumulator(count: 2, totalFrames: 2)
        accumulator.add([0, 0, 0.5, 0.5] as [Float])
        #expect(accumulator.levels == [0, 1])
    }

    /// A tone that's quiet in the first half and loud in the second, as an AAC `.m4a`.
    private func makeNote() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("waveform-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frames: AVAudioFrameCount = 44_100
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            let amplitude: Float = index < Int(frames) / 2 ? 0.02 : 0.8
            channel[index] = amplitude * sin(Float(index) * 2 * .pi * 440 / 44_100)
        }
        try file.write(from: buffer)
        return url
    }

    @Test func fileAndMemoryGiveTheSameShape() throws {
        let url = try makeNote()
        defer { try? FileManager.default.removeItem(at: url) }
        let fromFile = try Waveform.levels(of: url)
        let fromMemory = try Waveform.levels(of: Data(contentsOf: url))
        #expect(fromFile.count == Waveform.bucketCount)
        #expect(fromMemory.count == Waveform.bucketCount)
        // Quiet first half, loud second half.
        let firstHalf = fromMemory[2..<18].reduce(0, +) / 16
        let secondHalf = fromMemory[22..<38].reduce(0, +) / 16
        #expect(secondHalf > firstHalf + 0.2)
        for (a, b) in zip(fromFile, fromMemory) {
            #expect(abs(a - b) < 0.05)
        }
    }

    @Test func unreadableDataThrows() {
        #expect(throws: (any Error).self) { try Waveform.levels(of: Data("not audio".utf8)) }
    }
}
