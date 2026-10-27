//
//  AudioInput.swift
//  freewrite
//
//  Which microphone to record from (Settings › Recording) and an AVAudioEngine capture that can
//  use a specific input device. AVAudioRecorder always records from the system default input,
//  so voice notes switch to `AudioInputCapture` when another microphone is chosen; the Settings
//  input-level meter uses it too.
//

import AVFoundation
import CoreAudio

extension SettingsKey {
    /// `AVCaptureDevice.uniqueID` (the Core Audio device UID) of the chosen input; empty = system default.
    static let microphoneID = "microphoneID"
}

enum AudioInputDevices {
    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
    }

    static func available() -> [Device] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            .devices
            .map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The chosen microphone's id, or nil for the system default.
    static var selectedID: String? {
        let id = UserDefaults.standard.string(forKey: SettingsKey.microphoneID) ?? ""
        return id.isEmpty ? nil : id
    }

    /// The chosen microphone if it's connected, otherwise the system default.
    static func captureDevice() -> AVCaptureDevice? {
        selectedID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
    }

    /// The chosen microphone's Core Audio id when one is chosen and connected; nil means "use the default".
    static func selectedCoreAudioDevice() -> AudioDeviceID? {
        selectedID.flatMap(coreAudioDeviceID(forUID:))
    }

    static func coreAudioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: uid as CFString) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), qualifier, &size, &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}

/// Meters one input device and optionally records it to a mono 44.1 kHz AAC file.
/// Not main-actor isolated on purpose: the tap block runs on a Core Audio thread.
final class AudioInputCapture: @unchecked Sendable {
    enum Failure: LocalizedError {
        case deviceUnavailable
        case noInput

        var errorDescription: String? {
            switch self {
            case .deviceUnavailable: return "The selected microphone isn't available."
            case .noInput: return "No audio input is available."
            }
        }
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    // Guarded by `lock`.
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var latestLevel: Float = 0
    private var recordedFrames: AVAudioFramePosition = 0
    private var writeFailed = false

    private static let fileFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!

    /// `device` nil uses the system default input.
    init(device: AudioDeviceID?) throws {
        guard let device else { return }
        guard let unit = engine.inputNode.audioUnit else { throw Failure.deviceUnavailable }
        var deviceID = device
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw Failure.deviceUnavailable }
    }

    /// Starts metering, and recording to `url` when given.
    func start(recordingTo url: URL? = nil) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }

        if let url {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let converter = AVAudioConverter(from: format, to: Self.fileFormat) else { throw Failure.noInput }
            converter.downmix = true
            lock.withLock {
                self.file = file
                self.converter = converter
            }
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    /// Stops capture and closes the file. Returns false if writing failed along the way.
    @discardableResult
    func stop() -> Bool {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return lock.withLock {
            file?.close()
            file = nil
            converter = nil
            return !writeFailed
        }
    }

    var isRunning: Bool { engine.isRunning }

    /// Input level (0…1, -50 dB and below reads as silence).
    var level: Float { lock.withLock { latestLevel } }

    /// Seconds written to the file so far.
    var recordedDuration: TimeInterval {
        lock.withLock { Double(recordedFrames) / Self.fileFormat.sampleRate }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        let level = Self.level(of: buffer)
        lock.withLock {
            latestLevel = level
            guard let file, let converter, !writeFailed else { return }
            let ratio = Self.fileFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: Self.fileFormat, frameCapacity: capacity) else { return }
            let source = BufferOnce(buffer)
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if let next = source.take() {
                    status.pointee = .haveData
                    return next
                }
                status.pointee = .noDataNow
                return nil
            }
            do {
                if let error { throw error }
                if output.frameLength > 0 {
                    try file.write(from: output)
                    recordedFrames += AVAudioFramePosition(output.frameLength)
                }
            } catch {
                print("AudioInputCapture: write failed: \(error)")
                writeFailed = true
            }
        }
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count {
            sum += samples[index] * samples[index]
        }
        let rms = (sum / Float(count)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (decibels + 50) / 50))
    }
}

/// Hands a buffer to the converter exactly once per `convert` call.
private final class BufferOnce: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
