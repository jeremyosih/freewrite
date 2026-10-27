//
//  VoiceNotes.swift
//  freewrite
//
//  Audio-only voice notes: recording (AVAudioRecorder → temporary AAC .m4a, no time limit) and
//  playback of a version's voice note. Where the file goes is decided by `EntryVersionStore`.
//

import AVFoundation
import Observation

@MainActor
@Observable
final class VoiceNoteRecorder {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    /// Recent input levels (0…1), oldest first, for the bottom-bar meter.
    private(set) var levels: [Float] = Array(repeating: 0, count: VoiceNoteRecorder.meterBars)

    static let meterBars = 18

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meterTimer: Timer?

    /// Whether the microphone may be used, asking the first time.
    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        guard !isRecording else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-note-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Couldn't start recording."])
        }
        self.recorder = recorder
        elapsed = 0
        levels = Array(repeating: 0, count: Self.meterBars)
        isRecording = true

        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    /// Stops and returns the recorded file (nil if nothing usable was recorded).
    func stop() -> URL? {
        guard let recorder else { return nil }
        let url = recorder.url
        let duration = recorder.currentTime
        finish()
        recorder.stop()
        guard duration > 0.3, FileManager.default.fileExists(atPath: url.path) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    func discard() {
        guard let recorder else { return }
        finish()
        recorder.stop()
        recorder.deleteRecording()
    }

    private func finish() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder = nil
        isRecording = false
    }

    private func tick() {
        guard let recorder else { return }
        recorder.updateMeters()
        elapsed = recorder.currentTime
        // -50 dB and below reads as silence.
        let power = recorder.averagePower(forChannel: 0)
        let level = max(0, min(1, (power + 50) / 50))
        levels.removeFirst()
        levels.append(level)
    }
}

/// Plays one voice note at a time (play/pause), for the version being viewed.
@MainActor
@Observable
final class VoiceNotePlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var url: URL?
    private(set) var isPlaying = false

    @ObservationIgnored private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if self.url == url, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
            } else {
                isPlaying = player.play()
            }
            return
        }
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            self.player = player
            self.url = url
            isPlaying = player.play()
        } catch {
            print("Voice note: couldn't play \(url.lastPathComponent): \(error)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        url = nil
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
        }
    }
}

extension TimeInterval {
    /// "3:42" or "1:03:42".
    var clockString: String {
        let total = Int(self)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
