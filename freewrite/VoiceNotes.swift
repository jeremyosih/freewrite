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
final class VoiceNoteRecorder: NSObject, AVAudioRecorderDelegate {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    /// Recent input levels (0…1), oldest first, for the bottom-bar meter.
    private(set) var levels: [Float] = Array(repeating: 0, count: VoiceNoteRecorder.meterBars)

    static let meterBars = 18

    @ObservationIgnored private var recorder: AVAudioRecorder?
    /// Used instead of `recorder` when a specific microphone is chosen in Settings › Recording.
    @ObservationIgnored private var capture: AudioInputCapture?
    @ObservationIgnored private var captureURL: URL?
    @ObservationIgnored private var meterTimer: Timer?
    /// Called when recording stops on its own (device lost, encoder error). Gets whatever audio
    /// was captured (nil if none) and a message for the user.
    @ObservationIgnored var onUnexpectedStop: ((URL?, String) -> Void)?

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
        if let device = AudioInputDevices.selectedCoreAudioDevice() {
            // AVAudioRecorder can only use the system default input.
            let capture = try AudioInputCapture(device: device)
            try capture.start(recordingTo: url)
            self.capture = capture
            captureURL = url
        } else {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Couldn't start recording."])
            }
            self.recorder = recorder
        }
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
        if let capture, let url = captureURL {
            let duration = capture.recordedDuration
            finish()
            capture.stop()
            // Audio written before a write failure is still a valid file; keep it.
            return Self.keep(url, if: duration > 0.3)
        }
        guard let recorder else { return nil }
        let url = recorder.url
        let duration = recorder.currentTime
        finish()
        recorder.stop()
        return Self.keep(url, if: duration > 0.3)
    }

    func discard() {
        if let capture, let url = captureURL {
            finish()
            capture.stop()
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let recorder else { return }
        finish()
        recorder.stop()
        recorder.deleteRecording()
    }

    private static func keep(_ url: URL, if usable: Bool) -> URL? {
        guard usable, FileManager.default.fileExists(atPath: url.path) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    private func finish() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder = nil
        capture = nil
        captureURL = nil
        isRecording = false
    }

    // Stop/Discard clear `recorder` before stopping it, so a callback for the current recorder
    // means capture ended without the user asking.
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor in
            self.handleUnexpectedStop(of: id, reason: flag ? "Recording stopped." : "Recording failed.")
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let id = ObjectIdentifier(recorder)
        let message = error?.localizedDescription ?? "unknown error"
        Task { @MainActor in
            self.handleUnexpectedStop(of: id, reason: "Recording failed: \(message)")
        }
    }

    private func handleUnexpectedStop(of id: ObjectIdentifier, reason: String) {
        guard let recorder, ObjectIdentifier(recorder) == id else { return }
        let url = recorder.url
        let captured = elapsed > 0.3 && FileManager.default.fileExists(atPath: url.path)
        finish()
        recorder.stop()
        if !captured { try? FileManager.default.removeItem(at: url) }
        onUnexpectedStop?(captured ? url : nil, reason)
    }

    private func tick() {
        let level: Float
        if let capture {
            guard capture.isRunning else {
                // The engine stops when its device goes away or the configuration changes.
                handleCaptureStop(reason: "Recording stopped: the microphone changed or was disconnected.")
                return
            }
            guard !capture.hasWriteFailed else {
                // Stop right away instead of recording into a file that no longer accepts audio.
                handleCaptureStop(reason: "Recording stopped: the audio couldn't be saved.")
                return
            }
            elapsed = capture.recordedDuration
            level = capture.level
        } else if let recorder {
            recorder.updateMeters()
            elapsed = recorder.currentTime
            // -50 dB and below reads as silence.
            let power = recorder.averagePower(forChannel: 0)
            level = max(0, min(1, (power + 50) / 50))
        } else {
            return
        }
        levels.removeFirst()
        levels.append(level)
    }

    private func handleCaptureStop(reason: String) {
        guard let capture, let url = captureURL else { return }
        let captured = capture.recordedDuration > 0.3
        finish()
        capture.stop()
        onUnexpectedStop?(Self.keep(url, if: captured), reason)
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
