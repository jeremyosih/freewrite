//
//  SettingsView.swift
//  freewrite
//
//  Settings window (⌘,): writing font/size, appearance, session length and keyboard shortcuts.
//

import SwiftUI
import AppKit

// MARK: - Stored settings

enum SettingsKey {
    static let fontName = "fontName"
    static let fontSize = "fontSize"
    static let colorScheme = "colorScheme"
    static let sessionMinutes = "sessionMinutes"
    static let shortcuts = "shortcuts"
}

enum WritingFont {
    static let presets: [(label: String, name: String)] = [
        ("Lato", "Lato-Regular"),
        ("Arial", "Arial"),
        ("System", ".AppleSystemUIFont"),
        ("Serif", "Times New Roman"),
    ]
    static let defaultName = "Lato-Regular"
    static let sizes: [Double] = [16, 18, 20, 22, 24, 26]
    static let defaultSize: Double = 18

    static func displayName(for name: String) -> String {
        presets.first(where: { $0.name == name })?.label ?? name
    }
}

// MARK: - Shortcuts

enum AppCommand: String, CaseIterable, Identifiable {
    case newEntry
    case toggleHistory
    case toggleTimer
    case recordVideo
    case openChat
    case toggleBackspace
    case toggleTheme
    case increaseFontSize
    case decreaseFontSize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newEntry: return "New Entry"
        case .toggleHistory: return "Show/Hide History"
        case .toggleTimer: return "Start/Pause Timer"
        case .recordVideo: return "Record Video"
        case .openChat: return "Chat"
        case .toggleBackspace: return "Toggle Backspace"
        case .toggleTheme: return "Toggle Light/Dark"
        case .increaseFontSize: return "Bigger Text"
        case .decreaseFontSize: return "Smaller Text"
        }
    }

    var defaultShortcut: KeyShortcut? {
        switch self {
        case .newEntry: return KeyShortcut(key: "n", modifiers: [.command])
        case .toggleHistory: return KeyShortcut(key: "h", modifiers: [.command, .shift])
        case .toggleTimer: return KeyShortcut(key: "t", modifiers: [.command])
        case .recordVideo: return KeyShortcut(key: "r", modifiers: [.command, .shift])
        case .openChat: return KeyShortcut(key: "c", modifiers: [.command, .shift])
        case .toggleBackspace: return KeyShortcut(key: "b", modifiers: [.command, .shift])
        case .toggleTheme: return KeyShortcut(key: "l", modifiers: [.command, .shift])
        case .increaseFontSize: return KeyShortcut(key: "=", modifiers: [.command])
        case .decreaseFontSize: return KeyShortcut(key: "-", modifiers: [.command])
        }
    }

    static let notification = Notification.Name("freewrite.appCommand")

    func post() {
        NotificationCenter.default.post(name: Self.notification, object: rawValue)
    }
}

struct KeyShortcut: Codable, Equatable {
    /// A single character, or one of the named keys in `specialKeys`.
    var key: String
    var modifierRawValue: UInt

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifierRawValue = modifiers.intersection(Self.relevantModifiers).rawValue
    }

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    private static let specialKeys: [(name: String, keyCode: UInt16, equivalent: KeyEquivalent, symbol: String)] = [
        ("return", 36, .return, "↩"),
        ("tab", 48, .tab, "⇥"),
        ("space", 49, .space, "Space"),
        ("delete", 51, .delete, "⌫"),
        ("escape", 53, .escape, "⎋"),
        ("left", 123, .leftArrow, "←"),
        ("right", 124, .rightArrow, "→"),
        ("down", 125, .downArrow, "↓"),
        ("up", 126, .upArrow, "↑"),
    ]

    /// System and standard menu shortcuts (Quit, Close, Hide, Copy/Paste, Undo, Settings, …)
    /// that a command must not take over.
    static let reserved: [KeyShortcut] = [
        KeyShortcut(key: "q", modifiers: [.command]),
        KeyShortcut(key: "w", modifiers: [.command]),
        KeyShortcut(key: "h", modifiers: [.command]),
        KeyShortcut(key: "h", modifiers: [.command, .option]),
        KeyShortcut(key: "m", modifiers: [.command]),
        KeyShortcut(key: ",", modifiers: [.command]),
        KeyShortcut(key: "c", modifiers: [.command]),
        KeyShortcut(key: "v", modifiers: [.command]),
        KeyShortcut(key: "x", modifiers: [.command]),
        KeyShortcut(key: "a", modifiers: [.command]),
        KeyShortcut(key: "z", modifiers: [.command]),
        KeyShortcut(key: "z", modifiers: [.command, .shift]),
        KeyShortcut(key: "f", modifiers: [.command, .control]),
        KeyShortcut(key: "`", modifiers: [.command]),
    ]

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierRawValue) }

    var keyboardShortcut: KeyboardShortcut? {
        let equivalent: KeyEquivalent
        if let special = Self.specialKeys.first(where: { $0.name == key }) {
            equivalent = special.equivalent
        } else if let character = key.first {
            equivalent = KeyEquivalent(character)
        } else {
            return nil
        }
        var eventModifiers: EventModifiers = []
        if modifiers.contains(.command) { eventModifiers.insert(.command) }
        if modifiers.contains(.shift) { eventModifiers.insert(.shift) }
        if modifiers.contains(.option) { eventModifiers.insert(.option) }
        if modifiers.contains(.control) { eventModifiers.insert(.control) }
        return KeyboardShortcut(equivalent, modifiers: eventModifiers)
    }

    var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        if let special = Self.specialKeys.first(where: { $0.name == key }) {
            result += special.symbol
        } else {
            result += key.uppercased()
        }
        return result
    }

    /// Builds a shortcut from a key press, or nil if the key can't be used as one.
    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Self.relevantModifiers)
        if let special = Self.specialKeys.first(where: { $0.keyCode == event.keyCode }) {
            self.init(key: special.name, modifiers: modifiers)
        } else if let characters = event.charactersIgnoringModifiers?.lowercased(),
                  characters.count == 1,
                  let scalar = characters.unicodeScalars.first,
                  !CharacterSet.controlCharacters.contains(scalar) {
            self.init(key: characters, modifiers: modifiers)
        } else {
            return nil
        }
        // Plain keys would fire while typing; require ⌘, ⌃ or ⌥.
        guard !modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
    }
}

/// Custom shortcuts stored as JSON in UserDefaults; a missing entry means "use the default",
/// an explicit `null` means "no shortcut".
enum ShortcutStore {
    static func decode(_ json: String) -> [String: KeyShortcut?] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: KeyShortcut?].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func encode(_ overrides: [String: KeyShortcut?]) -> String {
        guard let data = try? JSONEncoder().encode(overrides) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func shortcut(for command: AppCommand, in json: String) -> KeyShortcut? {
        let overrides = decode(json)
        if let override = overrides[command.rawValue] {
            return override
        }
        return command.defaultShortcut
    }
}

// MARK: - Menu commands

/// The writing window (`WindowGroup` id) and how many are open, so menu commands still
/// work after the last one was closed.
@MainActor
enum WritingWindow {
    static let id = "writing"
    static var openCount = 0
}

struct FreewriteCommands: Commands {
    @AppStorage(SettingsKey.shortcuts) private var shortcutsJSON = "{}"
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            button(for: .newEntry)
        }
        CommandMenu("Write") {
            button(for: .toggleTimer)
            button(for: .toggleBackspace)
            Divider()
            button(for: .increaseFontSize)
            button(for: .decreaseFontSize)
            Divider()
            button(for: .recordVideo)
            button(for: .openChat)
        }
        CommandGroup(after: .sidebar) {
            button(for: .toggleHistory)
            button(for: .toggleTheme)
        }
    }

    @ViewBuilder
    private func button(for command: AppCommand) -> some View {
        let button = Button(command.title) { perform(command) }
        if let shortcut = ShortcutStore.shortcut(for: command, in: shortcutsJSON)?.keyboardShortcut {
            button.keyboardShortcut(shortcut)
        } else {
            button
        }
    }

    private func perform(_ command: AppCommand) {
        if command == .newEntry && WritingWindow.openCount == 0 {
            // A newly opened writing window creates (or selects) today's entry on appear.
            openWindow(id: WritingWindow.id)
        } else {
            command.post()
        }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    var body: some View {
        TabView {
            WritingSettingsView()
                .tabItem { Label("Writing", systemImage: "textformat") }
            ShortcutSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct WritingSettingsView: View {
    @AppStorage(SettingsKey.fontName) private var fontName = WritingFont.defaultName
    @AppStorage(SettingsKey.fontSize) private var fontSize = WritingFont.defaultSize
    @AppStorage(SettingsKey.colorScheme) private var colorScheme = "light"
    @AppStorage(SettingsKey.sessionMinutes) private var sessionMinutes = 15

    private let allFamilies = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        Form {
            Section("Text") {
                LabeledContent("Font") {
                    HStack {
                        Picker("Font", selection: $fontName) {
                            ForEach(WritingFont.presets, id: \.name) { preset in
                                Text(preset.label).tag(preset.name)
                            }
                            Divider()
                            ForEach(allFamilies, id: \.self) { family in
                                Text(family).tag(family)
                            }
                            // Keep a previously chosen font selectable even if it's no longer installed.
                            if !allFamilies.contains(fontName) && !WritingFont.presets.contains(where: { $0.name == fontName }) {
                                Text(fontName).tag(fontName)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()

                        Button("Random") {
                            if let random = allFamilies.randomElement() {
                                fontName = random
                            }
                        }
                    }
                }

                Picker("Size", selection: $fontSize) {
                    ForEach(WritingFont.sizes, id: \.self) { size in
                        Text("\(Int(size)) px").tag(size)
                    }
                }

                Text("The quick brown fox jumps over the lazy dog.")
                    .font(.custom(fontName, size: fontSize))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }

            Section("Appearance") {
                Picker("Theme", selection: $colorScheme) {
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            Section("Session") {
                Stepper(value: $sessionMinutes, in: 5...45, step: 5) {
                    Text("Timer length: \(sessionMinutes) min")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutSettingsView: View {
    @AppStorage(SettingsKey.shortcuts) private var shortcutsJSON = "{}"
    /// The one row waiting for keys, if any. A single key monitor serves it.
    @State private var recordingCommand: AppCommand?
    @State private var monitor: Any?
    @State private var rejection: String?

    var body: some View {
        Form {
            Section {
                ForEach(AppCommand.allCases) { command in
                    LabeledContent(command.title) {
                        let isRecording = recordingCommand == command
                        Button { toggleRecording(command) } label: {
                            Text(isRecording ? "Type shortcut…" : (ShortcutStore.shortcut(for: command, in: shortcutsJSON)?.displayString ?? "None"))
                                .frame(minWidth: 110)
                                .foregroundStyle(isRecording ? .secondary : .primary)
                        }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let rejection {
                        Text(rejection)
                            .foregroundStyle(.orange)
                    }
                    Text("Click a shortcut, then press the new keys. Esc cancels, Delete clears.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    stopRecording()
                    shortcutsJSON = "{}"
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear(perform: stopRecording)
        // Leaving the Settings window ends recording so keys typed elsewhere aren't swallowed.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            stopRecording()
        }
    }

    private func toggleRecording(_ command: AppCommand) {
        if recordingCommand == command {
            stopRecording()
        } else {
            startRecording(command)
        }
    }

    private func startRecording(_ command: AppCommand) {
        rejection = nil
        recordingCommand = command
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            record(event)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        recordingCommand = nil
    }

    private func record(_ event: NSEvent) {
        guard let command = recordingCommand else { return }
        let modifiers = event.modifierFlags.intersection(KeyShortcut.relevantModifiers)
        switch event.keyCode {
        case 53 where modifiers.isEmpty:
            stopRecording()
        case 51 where modifiers.isEmpty:
            set(nil, for: command)
            stopRecording()
        default:
            guard let recorded = KeyShortcut(event: event) else {
                NSSound.beep()
                return
            }
            guard !KeyShortcut.reserved.contains(recorded) else {
                NSSound.beep()
                rejection = "\(recorded.displayString) is used by macOS or the standard menus. Choose another shortcut."
                return
            }
            set(recorded, for: command)
            stopRecording()
        }
    }

    private func set(_ shortcut: KeyShortcut?, for command: AppCommand) {
        var overrides = ShortcutStore.decode(shortcutsJSON)
        if let shortcut {
            // A shortcut can only belong to one command.
            for other in AppCommand.allCases where other != command
                && ShortcutStore.shortcut(for: other, in: shortcutsJSON) == shortcut {
                overrides[other.rawValue] = .some(nil)
            }
        }
        if shortcut == command.defaultShortcut {
            overrides.removeValue(forKey: command.rawValue)
        } else {
            overrides[command.rawValue] = .some(shortcut)
        }
        shortcutsJSON = ShortcutStore.encode(overrides)
    }
}
