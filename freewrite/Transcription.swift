//
//  Transcription.swift
//  freewrite
//
//  Choice of speech-to-text engine for video entries and voice notes:
//  - Apple: on-device. Videos are transcribed live while recording (CameraManager); voice notes
//    are transcribed from the saved file (SpeechAnalyzer, falling back to SFSpeechRecognizer).
//  - Hex: the local Hex dictation app (https://hex.kitlangton.com) through its desktop local API v2,
//    run on the saved recording after it stops. Audio never leaves the Mac either way.
//

import Foundation
import AVFoundation
import Speech

enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case apple
    case hex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple (on-device)"
        case .hex: return "Hex"
        }
    }

    static var current: TranscriptionEngine {
        TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: SettingsKey.transcriptionEngine) ?? "") ?? .apple
    }

    /// Transcribes a saved audio (or movie) file with this engine.
    func transcribe(fileURL: URL) async throws -> String {
        switch self {
        case .apple: return try await AppleFileTranscriber.transcribe(fileURL: fileURL)
        case .hex: return try await HexTranscriber.transcribe(mediaURL: fileURL)
        }
    }
}

extension SettingsKey {
    static let transcriptionEngine = "transcriptionEngine"
    /// Empty means "pick the best installed model".
    static let hexModel = "hexModel"
    static let hexLanguage = "hexLanguage"
    /// Locale identifier for Apple transcription; empty = the Mac's language.
    static let appleTranscriptionLanguage = "appleTranscriptionLanguage"
}

/// The language Apple's speech recognition transcribes in (Settings › Recording).
enum AppleSpeechLanguage {
    static var locale: Locale {
        let identifier = UserDefaults.standard.string(forKey: SettingsKey.appleTranscriptionLanguage) ?? ""
        return identifier.isEmpty ? .current : Locale(identifier: identifier)
    }

    /// Locales Apple's recognizer supports, sorted by display name.
    static func supported() -> [(id: String, name: String)] {
        SFSpeechRecognizer.supportedLocales()
            .map { (id: $0.identifier, name: Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Hex local API client

/// Talks to Hex's desktop local API v2. Hex writes `local-api.json` (port + bearer token) into its
/// Application Support folder while it runs; endpoints are `GET /health`, `GET /models` and
/// `POST /transcriptions?model=…&language=…` with a 16 kHz mono WAV body.
/// The token is never logged.
struct HexClient: Sendable {
    struct Model: Decodable, Identifiable, Hashable, Sendable {
        let id: String
        var name: String = ""
        var installed: Bool = false
        var verified: Bool = false

        var usable: Bool { installed && verified }
        var displayName: String { name.isEmpty ? id : name }

        private enum CodingKeys: String, CodingKey { case id, name, installed, verified }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            installed = try container.decodeIfPresent(Bool.self, forKey: .installed) ?? false
            verified = try container.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        }
    }

    enum Failure: LocalizedError {
        case notRunning
        case unsupportedVersion
        case unauthorized
        case noModel
        case busy
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .notRunning: return "Hex isn't running."
            case .unsupportedVersion: return "This Hex version isn't supported. Update Hex."
            case .unauthorized: return "Hex rejected Freewrite's credentials. Restart Hex."
            case .noModel: return "Hex has no transcription model installed."
            case .busy: return "Hex is busy."
            case .http(let status): return "Hex returned HTTP \(status)."
            }
        }
    }

    /// Tried in order when the user hasn't picked a model.
    static let preferredModels = ["parakeet_unified_en", "parakeet_v3", "parakeet_v2", "whisper_large_v3_turbo"]

    let port: Int
    private let token: String

    private struct Discovery: Decodable {
        let port: Int
        let token: String
        let apiVersion: String
    }

    /// The real home folder; inside the sandbox `NSHomeDirectory()` points at the container.
    private static var userHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    static var discoveryCandidates: [URL] {
        let support = userHome.appendingPathComponent("Library/Application Support", isDirectory: true)
        // Hex moved its data from "voice-control" to "hex"; older installs still use the former.
        return ["hex", "voice-control"].map {
            support.appendingPathComponent($0, isDirectory: true).appendingPathComponent("local-api.json")
        }
    }

    static func connect() async throws -> HexClient {
        guard let data = discoveryCandidates.lazy.compactMap({ try? Data(contentsOf: $0) }).first,
              let discovery = try? JSONDecoder().decode(Discovery.self, from: data) else {
            throw Failure.notRunning
        }
        guard discovery.apiVersion == "2" else { throw Failure.unsupportedVersion }
        let client = HexClient(port: discovery.port, token: discovery.token)
        _ = try await client.health()
        return client
    }

    private init(port: Int, token: String) {
        self.port = port
        self.token = token
    }

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 3) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.notRunning
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return data
        case 401: throw Failure.unauthorized
        case 429: throw Failure.busy
        default: throw Failure.http(status)
        }
    }

    func health() async throws -> String {
        struct Health: Decodable { let version: String; let apiVersion: String }
        let health = try JSONDecoder().decode(Health.self, from: try await send(request("/health")))
        guard health.apiVersion == "2" else { throw Failure.unsupportedVersion }
        return health.version
    }

    func models() async throws -> [Model] {
        try JSONDecoder().decode([Model].self, from: try await send(request("/models")))
    }

    /// The configured model if Hex has it ready, else the first ready preferred model, else any ready one.
    func resolveModel(configured: String) async throws -> String {
        let usable = try await models().filter(\.usable)
        if !configured.isEmpty, usable.contains(where: { $0.id == configured }) {
            return configured
        }
        if let preferred = Self.preferredModels.first(where: { id in usable.contains(where: { $0.id == id }) }) {
            return preferred
        }
        guard let any = usable.first else { throw Failure.noModel }
        return any.id
    }

    func transcribe(wav: Data, model: String, language: String) async throws -> String {
        struct Transcription: Decodable { let transcript: String }
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "model", value: model), URLQueryItem(name: "language", value: language)]
        let path = "/transcriptions?" + (query.percentEncodedQuery ?? "")

        // A cold model may need to load first; Hex answers 429 while its queue is full.
        for attempt in 0..<6 {
            do {
                let data = try await send(request(path, method: "POST", body: wav, timeout: 180))
                return try JSONDecoder().decode(Transcription.self, from: data).transcript
            } catch Failure.busy where attempt < 5 {
                try await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
            }
        }
        throw Failure.busy
    }
}

// MARK: - Transcribing a saved recording with Hex

enum HexTranscriber {
    private static let sampleRate = 16_000
    /// Long recordings are sent in pieces of about this length, cut at the quietest nearby moment.
    private static let chunkSeconds = 30
    private static let cutSearchSeconds = 3

    static func transcribe(mediaURL: URL) async throws -> String {
        let client = try await HexClient.connect()
        let defaults = UserDefaults.standard
        let model = try await client.resolveModel(configured: defaults.string(forKey: SettingsKey.hexModel) ?? "")
        let language = normalizedLanguage(defaults.string(forKey: SettingsKey.hexLanguage) ?? "")

        var pieces: [String] = []
        try await forEachPiece(of: mediaURL) { samples in
            let text = try await client.transcribe(wav: wavData(samples), model: model, language: language)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pieces.append(trimmed) }
        }
        return pieces.joined(separator: " ")
    }

    /// A language code such as "en" or "pt-BR"; anything else falls back to English.
    static func normalizedLanguage(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let valid = !trimmed.isEmpty && trimmed.count <= 35
            && trimmed.first?.isLetter == true
            && trimmed.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        return valid ? trimmed.lowercased() : "en"
    }

    /// Decodes the first audio track to 16 kHz mono Float32 and hands it to `body` in pieces of
    /// about `chunkSeconds`, each as soon as it is complete, so only about one piece is in memory.
    static func forEachPiece(of url: URL, _ body: (ArraySlice<Float>) async throws -> Void) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }

        // Samples not yet sent; they always start at a piece boundary.
        var pending: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let offset = pending.count
            pending.append(contentsOf: repeatElement(0, count: count))
            pending.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(
                    block,
                    atOffset: 0,
                    dataLength: count * MemoryLayout<Float>.size,
                    destination: raw.baseAddress! + offset * MemoryLayout<Float>.size
                )
            }
            while let cut = cutPoint(in: pending) {
                try await body(pending[..<cut])
                pending.removeFirst(cut)
            }
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        if !pending.isEmpty { try await body(pending[...]) }
    }

    /// Where the piece starting at `samples[0]` ends, or nil while it can't be decided yet
    /// (the rest is short enough to send as one piece if no more audio follows).
    /// Cuts at the quietest 20 ms frame within ±3 s of the nominal boundary.
    static func cutPoint(in samples: [Float]) -> Int? {
        let chunk = chunkSeconds * sampleRate
        let search = cutSearchSeconds * sampleRate
        let frame = sampleRate / 50 // 20 ms
        guard samples.count > chunk + search else { return nil }
        let target = chunk
        var bestCut = target
        var bestEnergy = Float.greatestFiniteMagnitude
        var frameStart = target - search
        while frameStart + frame <= target + search {
            var energy: Float = 0
            for i in frameStart..<(frameStart + frame) { energy += samples[i] * samples[i] }
            if energy < bestEnergy {
                bestEnergy = energy
                bestCut = frameStart + frame / 2
            }
            frameStart += frame
        }
        return bestCut
    }

    /// 16-bit PCM mono WAV.
    private static func wavData(_ samples: ArraySlice<Float>) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }
}

// MARK: - Transcribing a saved recording on-device

/// Apple's on-device recognition over a whole file: the long-form `SpeechAnalyzer` +
/// `SpeechTranscriber` when the locale is supported (installing its model if needed), otherwise
/// `SFSpeechRecognizer` with on-device recognition where available.
enum AppleFileTranscriber {
    enum Failure: LocalizedError {
        case notAuthorized
        case unavailable

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Speech recognition isn't allowed. Turn it on in System Settings › Privacy & Security."
            case .unavailable: return "On-device speech recognition isn't available for your language. Try another language or Hex in Settings › Recording."
            }
        }
    }

    static func transcribe(fileURL: URL, locale: Locale = AppleSpeechLanguage.locale) async throws -> String {
        guard await requestAuthorization() else { throw Failure.notAuthorized }
        if SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            do {
                return try await transcribeWithAnalyzer(fileURL: fileURL, locale: supported)
            } catch {
                print("SpeechAnalyzer failed, falling back to SFSpeechRecognizer: \(error)")
            }
        }
        return try await transcribeWithRecognizer(fileURL: fileURL, locale: locale)
    }

    static func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default: return false
        }
    }

    private static func transcribeWithAnalyzer(fileURL: URL, locale: Locale) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let collector = Task {
            var pieces: [String] = []
            for try await result in transcriber.results where result.isFinal {
                pieces.append(String(result.text.characters))
            }
            return pieces
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            let file = try AVAudioFile(forReading: fileURL)
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        return normalized(try await collector.value.joined())
    }

    private static func transcribeWithRecognizer(fileURL: URL, locale: Locale) async throws -> String {
        // "Apple (on-device)" never sends audio to Apple's servers: no local model, no transcript.
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw Failure.unavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if once.claim() { continuation.resume(throwing: error) }
                } else if let result, result.isFinal {
                    if once.claim() { continuation.resume(returning: normalized(result.bestTranscription.formattedString)) }
                }
            }
        }
    }

    /// Collapses runs of whitespace (results come as space-prefixed segments).
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lets a callback that may fire several times resume a continuation once.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.withLock {
                defer { claimed = true }
                return !claimed
            }
        }
    }
}
