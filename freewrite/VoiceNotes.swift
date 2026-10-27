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

/// Plays one voice note at a time, for the version being viewed: play/pause, seeking, speed, and
/// the note's waveform (computed once off the main thread) for the bottom-bar player.
@MainActor
@Observable
final class VoiceNotePlayer: NSObject, AVAudioPlayerDelegate {
    static let rates: [Float] = [1, 1.5, 2]

    /// The loaded note; the player stays in the bar until `stop()`, also when paused or finished.
    private(set) var url: URL?
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    private(set) var currentTime: TimeInterval = 0
    /// Kept across notes, like a podcast player.
    private(set) var rate: Float = 1
    /// `Waveform.bucketCount` levels in 0…1; empty until computed.
    private(set) var levels: [Float] = []
    /// Live output level (0…1) while playing.
    private(set) var meterLevel: Float = 0

    var progress: Double { duration > 0 ? min(max(currentTime / duration, 0), 1) : 0 }

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var tickTimer: Timer?

    /// Plays `url`, or pauses/resumes it when it's the loaded note. `load` supplies the bytes
    /// instead of reading `url` (a locked note's decrypted audio, kept in memory only).
    func toggle(_ url: URL, load: (() throws -> Data)? = nil) {
        if self.url == url, player != nil {
            isPlaying ? pause() : resume()
        } else {
            self.load(url, data: load)
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicking()
    }

    func resume() {
        guard let player else { return }
        player.rate = rate
        isPlaying = player.play()
        if isPlaying { startTicking() }
    }

    /// Jumps to `fraction` (0…1) of the note.
    func seek(toFraction fraction: Double) {
        guard let player, duration > 0 else { return }
        player.currentTime = min(max(fraction, 0), 1) * duration
        currentTime = player.currentTime
    }

    /// 1× → 1.5× → 2× → 1×.
    func cycleRate() {
        let index = Self.rates.firstIndex(of: rate) ?? 0
        rate = Self.rates[(index + 1) % Self.rates.count]
        player?.rate = rate
    }

    func stop() {
        stopTicking()
        player?.stop()
        player = nil
        url = nil
        isPlaying = false
        duration = 0
        currentTime = 0
        levels = []
        meterLevel = 0
    }

    private func load(_ url: URL, data load: (() throws -> Data)?) {
        stop()
        let data: Data?
        do {
            data = try load?()
            let player = try data.map { try AVAudioPlayer(data: $0) } ?? AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.enableRate = true
            player.isMeteringEnabled = true
            player.prepareToPlay()
            self.player = player
            self.url = url
            duration = player.duration
            resume()
        } catch {
            print("Voice note: couldn't play \(url.lastPathComponent): \(error)")
            return
        }
        Task { [weak self] in
            let levels = await Task.detached(priority: .utility) {
                (try? data.map { try Waveform.levels(of: $0) } ?? Waveform.levels(of: url)) ?? []
            }.value
            guard let self, self.url == url else { return }
            self.levels = levels
        }
    }

    private func startTicking() {
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
        meterLevel = 0
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        player.updateMeters()
        // -50 dB and below reads as silence.
        meterLevel = max(0, min(1, (player.averagePower(forChannel: 0) + 50) / 50))
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.player, ObjectIdentifier(current) == id else { return }
            self.isPlaying = false
            self.stopTicking()
            // Back to the start; the player stays so the note can be replayed.
            current.currentTime = 0
            self.currentTime = 0
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
