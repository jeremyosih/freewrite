//
//  SettingsFile.swift
//  freewrite
//
//  `settings.json` in the entries folder is the settings' source of truth: the app writes it
//  when a setting changes, and reloads it live when you (in any editor) or an agent (through
//  `update_settings`) change it. Prompts, templates, the bottom bar and shortcuts are real JSON
//  in the file. The app still reads settings through UserDefaults/@AppStorage; this mirrors the
//  two both ways. Agent tokens and the folder bookmark never go in the file.
//

import Foundation

enum SettingsSchema {
    enum Kind: Sendable {
        case string(allowed: [String]?)
        case integer
        case number
        case bool
        /// Stored in UserDefaults as a JSON string, written to the file as JSON.
        case json(check: @Sendable (Data) -> String?)
    }

    struct Key: Sendable {
        let name: String
        let kind: Kind
        let help: String
    }

    static let keys: [Key] = [
        Key(name: SettingsKey.colorScheme, kind: .string(allowed: ["light", "dark"]), help: "Theme."),
        Key(name: SettingsKey.fontName, kind: .string(allowed: nil), help: "Default font for new pages (PostScript or family name)."),
        Key(name: SettingsKey.fontSize, kind: .number, help: "Default text size in points (e.g. 18)."),
        Key(name: SettingsKey.favoriteFonts, kind: .json(check: stringArray), help: "Fonts offered first in font menus: [\"Lato-Regular\", …]."),
        Key(name: SettingsKey.sessionMinutes, kind: .integer, help: "Timer length in minutes."),
        Key(name: SettingsKey.wordCountUnit, kind: .string(allowed: ["words", "characters"]), help: "What the bottom bar counts."),
        Key(name: SettingsKey.showComments, kind: .bool, help: "Comment margin open."),
        Key(name: SettingsKey.bottomBarLayout, kind: .json(check: anyJSON), help: "Bottom bar items, their side (left/right/hidden) and order."),
        Key(name: SettingsKey.shortcuts, kind: .json(check: anyJSON), help: "Keyboard shortcut overrides by command (null = unassigned)."),
        Key(name: SettingsKey.templates, kind: .json(check: decodes([WritingTemplate].self)), help: "Writing templates (the \"/\" menu). Keep the fields of the existing ones."),
        Key(name: PromptStore.key, kind: .json(check: decodes([AgentPrompt].self)), help: "Prompts served to agents: [{\"id\", \"name\", \"prompt\"}]. New ones need a unique id."),
        Key(name: SettingsKey.transcriptionEngine, kind: .string(allowed: nil), help: "Transcription engine."),
        Key(name: SettingsKey.appleTranscriptionLanguage, kind: .string(allowed: nil), help: "Apple transcription language (empty = automatic)."),
        Key(name: SettingsKey.hexModel, kind: .string(allowed: nil), help: "Hex transcription model."),
        Key(name: SettingsKey.hexLanguage, kind: .string(allowed: nil), help: "Hex transcription language."),
        Key(name: SettingsKey.microphoneID, kind: .string(allowed: nil), help: "Microphone device id (empty = system default)."),
        Key(name: SettingsKey.noteLockTimeout, kind: .integer, help: "Minutes before open locked notes close."),
        Key(name: "videoVolume", kind: .number, help: "Video playback volume, 0…1."),
        Key(name: "videoIsMuted", kind: .bool, help: "Videos start muted."),
    ]

    static func key(_ name: String) -> Key? { keys.first { $0.name == name } }

    /// Lists that are worth showing even when never changed, so an agent can append to them.
    static let resolvedLists: [String: @MainActor @Sendable () -> String] = [
        PromptStore.key: { PromptStore.encode(PromptStore.load()) },
        SettingsKey.templates: { TemplateStore.encode(TemplateStore.load()) },
    ]

    @Sendable private static func anyJSON(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) == nil ? "isn't valid JSON" : nil
    }

    @Sendable private static func stringArray(_ data: Data) -> String? {
        (try? JSONDecoder().decode([String].self, from: data)) == nil ? "must be an array of strings" : nil
    }

    private static func decodes<T: Decodable>(_ type: T.Type) -> @Sendable (Data) -> String? {
        { data in
            do {
                _ = try JSONDecoder().decode(T.self, from: data)
                return nil
            } catch let DecodingError.keyNotFound(key, context) {
                return "is missing \"\(key.stringValue)\" at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
            } catch {
                return "doesn't have the expected shape (\(error.localizedDescription))"
            }
        }
    }
}

@MainActor
final class SettingsFile {
    static let shared = SettingsFile()
    static let filename = "settings.json"

    private let defaults = UserDefaults.standard
    private var folder: URL?
    /// What the file held when we last read or wrote it, to tell our writes from outside edits.
    private var lastSeen: JSONValue?
    private var lastModified: Date?
    private var pollTimer: Timer?
    private var exportScheduled = false
    /// Why the file couldn't be read last time (shown in Settings), nil when fine.
    private(set) var problem: String?

    var url: URL? { folder?.appendingPathComponent(Self.filename) }

    /// Starts mirroring for `folder`: its file wins if it exists, else it's created from the
    /// current settings. Called at launch and whenever the entries folder changes.
    func start(folder: URL) {
        self.folder = folder
        lastSeen = nil
        lastModified = nil
        if let url, FileManager.default.fileExists(atPath: url.path) {
            importFile()
        }
        export()
        if pollTimer == nil {
            // Polling the file's date once a second catches every kind of save (atomic or in place).
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { SettingsFile.shared.checkFile() }
            }
            NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SettingsFile.shared.scheduleExport() }
            }
        }
    }

    // MARK: Current values

    /// The settings as the file shows them.
    func current() -> JSONValue {
        var object: [String: JSONValue] = [:]
        for key in SettingsSchema.keys {
            if let value = value(for: key) { object[key.name] = value }
        }
        return .object(object)
    }

    private func value(for key: SettingsSchema.Key) -> JSONValue? {
        switch key.kind {
        case .string:
            return defaults.string(forKey: key.name).map(JSONValue.string)
        case .integer, .number:
            guard let number = defaults.object(forKey: key.name) as? NSNumber else { return nil }
            return .number(number.doubleValue)
        case .bool:
            guard let number = defaults.object(forKey: key.name) as? NSNumber else { return nil }
            return .bool(number.boolValue)
        case .json:
            let raw = defaults.string(forKey: key.name).flatMap { $0.isEmpty ? nil : $0 } ?? SettingsSchema.resolvedLists[key.name]?()
            guard let raw, let value = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) else { return nil }
            return value
        }
    }

    // MARK: Changing settings

    /// Applies `changes` (key → value, null = back to the default). All or nothing: every
    /// problem is listed and nothing changes if any key is wrong.
    func apply(_ changes: [String: JSONValue]) throws -> [String] {
        var problems: [String] = []
        var writes: [(String, Any?)] = []
        for (name, value) in changes.sorted(by: { $0.key < $1.key }) {
            guard let key = SettingsSchema.key(name) else {
                problems.append("\(name): unknown setting")
                continue
            }
            if value == .null {
                writes.append((name, nil))
                continue
            }
            switch (key.kind, value) {
            case (.string(let allowed), .string(let string)):
                if let allowed, !allowed.contains(string) {
                    problems.append("\(name): must be one of \(allowed.joined(separator: ", "))")
                } else {
                    writes.append((name, string))
                }
            case (.integer, .number(let number)):
                writes.append((name, Int(number)))
            case (.number, .number(let number)):
                writes.append((name, number))
            case (.bool, .bool(let bool)):
                writes.append((name, bool))
            case (.json(let check), _):
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                guard let data = try? encoder.encode(value) else {
                    problems.append("\(name): couldn't encode")
                    continue
                }
                if let problem = check(data) {
                    problems.append("\(name) \(problem)")
                } else {
                    writes.append((name, String(decoding: data, as: UTF8.self)))
                }
            default:
                problems.append("\(name): wrong type")
            }
        }
        guard problems.isEmpty else { throw AgentToolError("Nothing changed: " + problems.joined(separator: "; ")) }
        for (name, value) in writes {
            if let value { defaults.set(value, forKey: name) } else { defaults.removeObject(forKey: name) }
        }
        export()
        return writes.map(\.0)
    }

    // MARK: File ⇄ defaults

    private func scheduleExport() {
        guard !exportScheduled else { return }
        exportScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            exportScheduled = false
            export()
        }
    }

    /// Writes the file when the settings differ from what it holds. A file that doesn't parse
    /// (you're mid-edit) is left alone.
    private func export() {
        guard let url else { return }
        let value = current()
        if let onDisk = readFile() {
            guard onDisk != value else {
                lastSeen = onDisk
                return
            }
        } else if FileManager.default.fileExists(atPath: url.path) {
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return }
        do {
            try data.write(to: url, options: .atomic)
            lastSeen = value
            lastModified = modificationDate()
        } catch {
            problem = "Couldn't write \(Self.filename): \(error.localizedDescription)"
        }
    }

    private func checkFile() {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        let modified = modificationDate()
        guard modified != lastModified else { return }
        lastModified = modified
        importFile()
    }

    /// Reads the file into the settings (only keys whose value changed).
    private func importFile() {
        guard let value = readFile(), case .object(let object) = value else {
            problem = "\(Self.filename) isn't valid JSON; fix it and it reloads."
            return
        }
        problem = nil
        guard value != lastSeen else { return }
        lastSeen = value
        let current = current()
        var changes: [String: JSONValue] = [:]
        for (name, newValue) in object where SettingsSchema.key(name) != nil && current[name] != newValue {
            changes[name] = newValue
        }
        guard !changes.isEmpty else { return }
        do {
            _ = try apply(changes)
        } catch {
            problem = "\(Self.filename): \(error.localizedDescription)"
        }
    }

    private func readFile() -> JSONValue? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func modificationDate() -> Date? {
        guard let url else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: For agents

    /// The settings plus what each key means, for `get_settings`.
    func describe() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(current())).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var lines = ["settings.json (in the entries folder; change it with update_settings):", json, "", "Keys (missing = the default):"]
        for key in SettingsSchema.keys {
            lines.append("- \(key.name): \(key.help)")
        }
        return lines.joined(separator: "\n")
    }
}
