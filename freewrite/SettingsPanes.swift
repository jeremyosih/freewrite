//
//  SettingsPanes.swift
//  freewrite
//
//  Settings › Recording (microphone, input level, transcription), Storage, Permissions and About.
//

import SwiftUI
import AppKit
import AVFoundation
import Speech

// MARK: - Recording

struct RecordingSettingsView: View {
    @AppStorage(SettingsKey.microphoneID) private var microphoneID = ""
    @AppStorage(SettingsKey.transcriptionEngine) private var engine = TranscriptionEngine.apple.rawValue
    @AppStorage(SettingsKey.appleTranscriptionLanguage) private var appleLanguage = ""
    @AppStorage(SettingsKey.hexModel) private var hexModel = ""
    @AppStorage(SettingsKey.hexLanguage) private var hexLanguage = "en"

    private enum HexStatus: Equatable {
        case checking
        case connected(version: String, models: [HexClient.Model])
        case unavailable(String)
    }

    @State private var devices: [AudioInputDevices.Device] = []
    @State private var hexStatus: HexStatus = .checking
    private let appleLanguages = AppleSpeechLanguage.supported()

    var body: some View {
        Form {
            Section {
                Picker("Microphone", selection: $microphoneID) {
                    Text("System default").tag("")
                    if !devices.isEmpty {
                        Divider()
                    }
                    ForEach(devices) { device in
                        Text(device.name).tag(device.id)
                    }
                    if !microphoneID.isEmpty && !devices.contains(where: { $0.id == microphoneID }) {
                        Text("Disconnected microphone").tag(microphoneID)
                    }
                }
                .accessibilityIdentifier("microphonePicker")

                LabeledContent("Input level") {
                    InputLevelMeter(microphoneID: microphoneID)
                }
            } footer: {
                SettingsFootnote("Used for voice notes and the sound of video entries. If the chosen microphone isn't connected, the system default is used.")
            }

            Section {
                Picker("Transcription", selection: $engine) {
                    ForEach(TranscriptionEngine.allCases) { engine in
                        Text(engine.title).tag(engine.rawValue)
                    }
                }
                .accessibilityIdentifier("transcriptionEnginePicker")

                if engine == TranscriptionEngine.hex.rawValue {
                    hexRows
                } else {
                    Picker("Language", selection: $appleLanguage) {
                        Text("Automatic").tag("")
                        Divider()
                        ForEach(appleLanguages, id: \.id) { language in
                            Text(language.name).tag(language.id)
                        }
                        if !appleLanguage.isEmpty && !appleLanguages.contains(where: { $0.id == appleLanguage }) {
                            Text(appleLanguage).tag(appleLanguage)
                        }
                    }
                }
            } footer: {
                SettingsFootnote(engine == TranscriptionEngine.hex.rawValue
                     ? "Hex transcribes videos and voice notes after you stop recording, with a model you have in Hex. If Hex isn't running, Apple's on-device transcript is kept when available."
                     : "Apple transcribes on this Mac: videos live while you record, voice notes after you stop. Automatic uses your Mac's language.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reloadDevices)
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in reloadDevices() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in reloadDevices() }
        .task(id: engine) {
            if engine == TranscriptionEngine.hex.rawValue {
                await refreshHex()
            }
        }
    }

    @ViewBuilder
    private var hexRows: some View {
        LabeledContent("Hex status") {
            HStack {
                switch hexStatus {
                case .checking:
                    ProgressView().controlSize(.small)
                case .connected(let version, _):
                    Label("Connected · \(version)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .fixedSize()
                case .unavailable(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Button("Refresh") { Task { await refreshHex() } }
            }
        }

        Picker("Hex model", selection: $hexModel) {
            Text("Automatic").tag("")
            ForEach(usableModels) { model in
                Text(model.displayName).tag(model.id)
            }
            if !hexModel.isEmpty && !usableModels.contains(where: { $0.id == hexModel }) {
                Text(hexModel).tag(hexModel)
            }
        }

        TextField("Hex language", text: $hexLanguage, prompt: Text("en"))

        if case .unavailable = hexStatus {
            LabeledContent("Hex isn't installed?") {
                Link("Get Hex", destination: URL(string: "https://hex.kitlangton.com")!)
            }
        }
    }

    private var usableModels: [HexClient.Model] {
        if case .connected(_, let models) = hexStatus {
            return models.filter(\.usable)
        }
        return []
    }

    private func reloadDevices() {
        devices = AudioInputDevices.available()
    }

    private func refreshHex() async {
        hexStatus = .checking
        do {
            let client = try await HexClient.connect()
            hexStatus = .connected(version: try await client.health(), models: try await client.models())
        } catch {
            hexStatus = .unavailable(error.localizedDescription)
        }
    }
}

/// Live level of the chosen microphone while the pane is open. Never asks for permission:
/// without microphone access it just says so.
private struct InputLevelMeter: View {
    let microphoneID: String

    private static let segments = 20

    @State private var level: Float = 0
    @State private var status = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var failed = false

    var body: some View {
        Group {
            if status != .authorized {
                Text("Allow microphone access in Permissions")
                    .foregroundStyle(.secondary)
            } else if failed {
                Text("Unavailable")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 2) {
                    ForEach(0..<Self.segments, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Float(index) < level * Float(Self.segments) ? Color.primary : Color.secondary.opacity(0.25))
                            .frame(width: 4, height: 12)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Input level")
                .accessibilityValue("\(Int(level * 100)) percent")
            }
        }
        .task(id: "\(microphoneID)|\(status.rawValue)") { await meter() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            status = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    /// Runs until the view goes away or the microphone changes (the task is cancelled).
    private func meter() async {
        level = 0
        failed = false
        guard status == .authorized else { return }
        let device: AudioDeviceID? = microphoneID.isEmpty ? nil : AudioInputDevices.coreAudioDeviceID(forUID: microphoneID)
        let capture: AudioInputCapture
        do {
            capture = try AudioInputCapture(device: device)
            try capture.start()
        } catch {
            failed = true
            return
        }
        defer { capture.stop() }
        while !Task.isCancelled {
            // Fall quickly but not instantly, so the meter doesn't flicker.
            level = max(capture.level, level * 0.8)
            try? await Task.sleep(for: .milliseconds(60))
        }
    }
}

// MARK: - Storage

struct StorageSettingsView: View {
    private let storage = EntryStorage.shared
    @State private var folderSize: Int64?

    var body: some View {
        Form {
            Section {
                LabeledContent("Entries folder") {
                    HStack {
                        if let folderSize {
                            Text(ByteCountFormatter.string(fromByteCount: folderSize, countStyle: .file))
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("storageFolderSize")
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: storage.rootURL.path)
                        }
                    }
                }

                LabeledContent("Location") {
                    Text(storage.rootURL.path)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("storageFolderPath")
                }

                HStack {
                    if storage.isTransferring {
                        ProgressView().controlSize(.small)
                        Text("Transferring entries…")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Use Default") { Task { await storage.useDefaultFolder() } }
                        .disabled(storage.isUsingDefault)
                    Button("Choose Folder…") { Task { await storage.chooseFolder() } }
                        .accessibilityIdentifier("chooseStorageFolderButton")
                }
                .disabled(storage.isTransferring)
            } footer: {
                SettingsFootnote(storage.isUsingDefault
                     ? "Entries are plain Markdown files, videos and voice notes. The default folder is inside Freewrite's app container; choose a folder such as Documents or iCloud Drive to keep them where you can find them."
                     : "Entries are plain Markdown files, videos and voice notes in this folder. Use Default switches back to the folder inside Freewrite's app container.")
            }
        }
        .formStyle(.grouped)
        .task(id: "\(storage.rootURL.path)|\(storage.isTransferring)") {
            let root = storage.rootURL
            folderSize = await Task.detached(priority: .utility) { Self.size(of: root) }.value
        }
    }

    /// Bytes used on disk by everything in `root`.
    nonisolated private static func size(of root: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}

// MARK: - Permissions

enum AppPermission: String, CaseIterable, Identifiable {
    case microphone
    case camera
    case speechRecognition

    enum Status {
        case allowed
        case denied
        case notAsked
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .camera: return "Camera"
        case .speechRecognition: return "Speech Recognition"
        }
    }

    var purpose: String {
        switch self {
        case .microphone: return "To record voice notes and video sound"
        case .camera: return "To record video entries"
        case .speechRecognition: return "To transcribe with Apple on this Mac"
        }
    }

    var systemImage: String {
        switch self {
        case .microphone: return "mic.fill"
        case .camera: return "video.fill"
        case .speechRecognition: return "waveform"
        }
    }

    var tint: Color {
        switch self {
        case .microphone: return .orange
        case .camera: return .green
        case .speechRecognition: return .purple
        }
    }

    /// Anchor of the matching Privacy & Security page in System Settings.
    private var privacyAnchor: String {
        switch self {
        case .microphone: return "Privacy_Microphone"
        case .camera: return "Privacy_Camera"
        case .speechRecognition: return "Privacy_SpeechRecognition"
        }
    }

    var status: Status {
        switch self {
        case .microphone: return Self.status(AVCaptureDevice.authorizationStatus(for: .audio))
        case .camera: return Self.status(AVCaptureDevice.authorizationStatus(for: .video))
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .allowed
            case .notDetermined: return .notAsked
            default: return .denied
            }
        }
    }

    private static func status(_ status: AVAuthorizationStatus) -> Status {
        switch status {
        case .authorized: return .allowed
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    func request() async {
        switch self {
        case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .camera: _ = await AVCaptureDevice.requestAccess(for: .video)
        case .speechRecognition: _ = await AppleFileTranscriber.requestAuthorization()
        }
    }

    @MainActor
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(privacyAnchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct PermissionsSettingsView: View {
    @State private var statuses: [AppPermission: AppPermission.Status] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(AppPermission.allCases) { permission in
                    row(permission)
                }
            } footer: {
                SettingsFootnote("Freewrite only asks when you first use a feature. The microphone is for voice notes and the sound of videos, the camera for video entries, and speech recognition for Apple transcription (not needed with Hex). Nothing leaves your Mac.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func row(_ permission: AppPermission) -> some View {
        let status = statuses[permission] ?? permission.status
        return HStack(spacing: 10) {
            SettingsIconTile(systemImage: permission.systemImage, tint: permission.tint, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(permission.title)
                Text(permission.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case .allowed:
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            case .denied:
                Text("Not allowed")
                    .foregroundStyle(.secondary)
                Button("Open System Settings") { permission.openSystemSettings() }
            case .notAsked:
                Text("Not asked")
                    .foregroundStyle(.secondary)
                Button("Allow…") {
                    Task {
                        await permission.request()
                        refresh()
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("permission-\(permission.rawValue)")
    }

    private func refresh() {
        statuses = Dictionary(uniqueKeysWithValues: AppPermission.allCases.map { ($0, $0.status) })
    }
}

// MARK: - About

struct AboutSettingsView: View {
    @Environment(\.openWindow) private var openWindow

    private static let repository = URL(string: "https://github.com/jeremyosih/freewrite")!
    private static let original = URL(string: "https://github.com/farzaa/freewrite")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Freewrite")
                            .font(.headline)
                        Text(version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 2)
            }

            Section("Links") {
                linkRow("Website", Self.repository)
                linkRow("Source", Self.repository)
                linkRow("Original project", Self.original)
            }

            Section {
                LabeledContent("Welcome entry") {
                    Button("Show") { showWelcomeEntry() }
                        .accessibilityIdentifier("showWelcomeEntryButton")
                }
            } footer: {
                SettingsFootnote("Opens a new entry with the welcome text Freewrite starts with.")
            }
        }
        .formStyle(.grouped)
    }

    private func linkRow(_ title: String, _ url: URL) -> some View {
        LabeledContent(title) {
            Link(destination: url) {
                HStack(spacing: 3) {
                    Text(url.host().map { $0 + url.path() } ?? url.absoluteString)
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private func showWelcomeEntry() {
        guard WritingWindow.openCount == 0 else {
            AppCommand.showWelcomeEntry.post()
            return
        }
        // A new writing window sets itself up on appear; post once it can receive commands.
        openWindow(id: WritingWindow.id)
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            AppCommand.showWelcomeEntry.post()
        }
    }
}
