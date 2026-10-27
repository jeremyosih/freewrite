//
//  Waveform.swift
//  freewrite
//
//  Loudness of a voice note in a fixed number of buckets, for the player's waveform. The file is
//  read once in chunks (voice notes have no time limit), never held in memory whole. A locked
//  note's audio is only in memory, so it's decoded from its bytes instead (never written out).
//

import AVFoundation
import AudioToolbox

/// Accumulates mono samples into `count` RMS buckets spread evenly over `totalFrames`.
struct WaveformAccumulator {
    let count: Int
    let totalFrames: Int64
    private var sums: [Double]
    private var frames: [Int]
    private var position: Int64 = 0

    init(count: Int, totalFrames: Int64) {
        self.count = max(count, 1)
        self.totalFrames = max(totalFrames, 1)
        sums = Array(repeating: 0, count: self.count)
        frames = Array(repeating: 0, count: self.count)
    }

    mutating func add<C: Collection>(_ samples: C) where C.Element == Float {
        for sample in samples {
            let bucket = min(Int(position * Int64(count) / totalFrames), count - 1)
            sums[bucket] += Double(sample) * Double(sample)
            frames[bucket] += 1
            position += 1
        }
    }

    /// Levels in 0…1: RMS per bucket on a -50…0 dB scale, scaled so the loudest bucket is 1.
    /// Silence (or an empty file) gives all zeros.
    var levels: [Float] {
        let decibels = zip(sums, frames).map { sum, frames -> Float in
            guard frames > 0, sum > 0 else { return 0 }
            let rms = (sum / Double(frames)).squareRoot()
            let db = 20 * log10(rms)
            return Float(max(0, min(1, (db + 50) / 50)))
        }
        guard let loudest = decibels.max(), loudest > 0 else { return decibels }
        return decibels.map { $0 / loudest }
    }
}

enum Waveform {
    static let bucketCount = 40

    /// Reads the first channel of `url` and returns `count` levels (see `WaveformAccumulator`).
    static func levels(of url: URL, count: Int = bucketCount) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        var accumulator = WaveformAccumulator(count: count, totalFrames: file.length)
        let chunk: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            return accumulator.levels
        }
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
            accumulator.add(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        return accumulator.levels
    }

    /// Same as `levels(of:)` for audio that's only in memory (a locked note's decrypted `.m4a`).
    static func levels(of data: Data, count: Int = bucketCount) throws -> [Float] {
        let source = MemoryAudioSource(data: data)
        // The callbacks get an unretained pointer: keep `source` alive until the file is closed
        // (declared first, so this runs after the other defers).
        defer { withExtendedLifetime(source) {} }
        var fileID: AudioFileID?
        var status = AudioFileOpenWithCallbacks(
            Unmanaged.passUnretained(source).toOpaque(),
            { client, position, requested, buffer, actual in
                let source = Unmanaged<MemoryAudioSource>.fromOpaque(client).takeUnretainedValue()
                return source.read(at: position, count: requested, into: buffer, actual: actual)
            },
            nil,
            { client in
                Int64(Unmanaged<MemoryAudioSource>.fromOpaque(client).takeUnretainedValue().data.count)
            },
            nil,
            kAudioFileM4AType,
            &fileID
        )
        guard status == noErr, let fileID else { throw WaveformError.unreadable(status) }
        defer { AudioFileClose(fileID) }

        var fileRef: ExtAudioFileRef?
        status = ExtAudioFileWrapAudioFileID(fileID, false, &fileRef)
        guard status == noErr, let fileRef else { throw WaveformError.unreadable(status) }
        defer { ExtAudioFileDispose(fileRef) }

        var fileFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(fileRef, kExtAudioFileProperty_FileDataFormat, &size, &fileFormat)
        guard status == noErr else { throw WaveformError.unreadable(status) }

        // Mono Float32 at the file's sample rate, so frame counts match the file's length.
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: fileFormat.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        status = ExtAudioFileSetProperty(fileRef, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat)
        guard status == noErr else { throw WaveformError.unreadable(status) }

        var totalFrames: Int64 = 0
        size = UInt32(MemoryLayout<Int64>.size)
        status = ExtAudioFileGetProperty(fileRef, kExtAudioFileProperty_FileLengthFrames, &size, &totalFrames)
        guard status == noErr else { throw WaveformError.unreadable(status) }

        var accumulator = WaveformAccumulator(count: count, totalFrames: totalFrames)
        let chunk = 32_768
        var samples = [Float](repeating: 0, count: chunk)
        while true {
            try Task.checkCancellation()
            var frames = UInt32(chunk)
            status = samples.withUnsafeMutableBytes { bytes in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress)
                )
                return ExtAudioFileRead(fileRef, &frames, &list)
            }
            guard status == noErr else { throw WaveformError.unreadable(status) }
            guard frames > 0 else { break }
            accumulator.add(samples.prefix(Int(frames)))
        }
        return accumulator.levels
    }
}

enum WaveformError: Error {
    case unreadable(OSStatus)
}

/// Read callbacks for `AudioFileOpenWithCallbacks` over bytes in memory.
private final class MemoryAudioSource {
    let data: Data

    init(data: Data) {
        self.data = data
    }

    func read(at position: Int64, count requested: UInt32, into buffer: UnsafeMutableRawPointer, actual: UnsafeMutablePointer<UInt32>) -> OSStatus {
        guard position >= 0, position <= Int64(data.count) else { return kAudioFilePositionError }
        let start = Int(position)
        let length = min(Int(requested), data.count - start)
        data.withUnsafeBytes { bytes in
            if length > 0, let base = bytes.baseAddress {
                buffer.copyMemory(from: base + start, byteCount: length)
            }
        }
        actual.pointee = UInt32(length)
        return noErr
    }
}
