//
//  VoiceNotePlayerBar.swift
//  freewrite
//
//  The compact voice-note player in the bottom bar's status area:
//  `❚❚ ▁▃▅▇▅▃▁ 0:12 / 0:45  1×  ×`. The waveform is the scrubber.
//

import SwiftUI

struct VoiceNotePlayerBar: View {
    let player: VoiceNotePlayer
    let textColor: Color
    let textHoverColor: Color
    let onClose: () -> Void

    @State private var hovered: Control?

    private enum Control {
        case playPause, rate, close
    }

    var body: some View {
        HStack(spacing: 8) {
            control(.playPause, label: player.isPlaying ? "Pause voice note" : "Play voice note") {
                if let url = player.url { player.toggle(url) }
            } content: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10))
                    .frame(width: 12, height: 14)
            }
            .accessibilityIdentifier("playVoiceNoteButton")

            WaveformScrubber(
                levels: player.levels,
                progress: player.progress,
                meterLevel: player.isPlaying ? player.meterLevel : 0,
                playedColor: textHoverColor.opacity(0.8),
                remainingColor: textColor.opacity(0.45),
                onSeek: { player.seek(toFraction: $0) }
            )
            .accessibilityLabel("Voice note position")
            .accessibilityValue("\(player.currentTime.clockString) of \(player.duration.clockString)")
            .accessibilityAdjustableAction { direction in
                guard player.duration > 0 else { return }
                let step = 5 / player.duration
                player.seek(toFraction: player.progress + (direction == .increment ? step : -step))
            }

            Text("\(player.currentTime.clockString) / \(player.duration.clockString)")
                .font(.system(size: 13).monospacedDigit())
                .foregroundColor(textColor)
                .fixedSize()
                .accessibilityHidden(true)

            control(.rate, label: "Playback speed \(rateLabel)") {
                player.cycleRate()
            } content: {
                Text(rateLabel)
                    .font(.system(size: 12).monospacedDigit())
                    .frame(minWidth: 26)
            }
            .help("Playback speed")
            .accessibilityIdentifier("voiceNoteRateButton")

            control(.close, label: "Close voice note") {
                onClose()
            } content: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 12, height: 14)
            }
            .accessibilityIdentifier("closeVoiceNoteButton")
        }
    }

    private var rateLabel: String {
        player.rate == player.rate.rounded() ? "\(Int(player.rate))×" : "\(player.rate.formatted(.number.precision(.fractionLength(1))))×"
    }

    private func control<Content: View>(_ control: Control, label: String, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .foregroundColor(hovered == control ? textHoverColor : textColor)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .onHover { hovering in
            if hovering {
                hovered = control
                NSCursor.pointingHand.push()
            } else {
                if hovered == control { hovered = nil }
                NSCursor.pop()
            }
        }
    }
}

/// Bars of the note's loudness; the played part is darker. Click or drag to seek. The bars at
/// the playhead follow the live level unless Reduce Motion is on.
struct WaveformScrubber: View {
    let levels: [Float]
    let progress: Double
    let meterLevel: Float
    let playedColor: Color
    let remainingColor: Color
    let onSeek: (Double) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barWidth: CGFloat = 2
    private let spacing: CGFloat = 1.5
    private let height: CGFloat = 16

    var body: some View {
        let bars = levels.isEmpty ? Array(repeating: Float(0.12), count: Waveform.bucketCount) : levels
        let playhead = Int((progress * Double(bars.count)).rounded(.down))
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(bars.enumerated()), id: \.offset) { index, level in
                Capsule()
                    .fill(Double(index) < progress * Double(bars.count) ? playedColor : remainingColor)
                    .frame(width: barWidth, height: barHeight(level, index: index, playhead: playhead))
            }
        }
        .frame(width: CGFloat(bars.count) * (barWidth + spacing) - spacing, height: height)
        .animation(reduceMotion ? nil : .linear(duration: 0.1), value: meterLevel)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let width = CGFloat(bars.count) * (barWidth + spacing) - spacing
                    onSeek(Double(value.location.x / width))
                }
        )
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .accessibilityElement()
    }

    private func barHeight(_ level: Float, index: Int, playhead: Int) -> CGFloat {
        var level = CGFloat(level)
        if !reduceMotion, meterLevel > 0, abs(index - playhead) <= 1 {
            // A little pulse with what's audible right now.
            level = max(level, CGFloat(meterLevel) * (index == playhead ? 1 : 0.7))
        }
        return 3 + level * (height - 3)
    }
}
