//
//  SettingsView.swift
//  freewrite
//
//  Settings window (⌘,): stored settings keys, app commands + shortcuts, the sidebar and the
//  General and Shortcuts panes. The other panes live in SettingsPanes.swift and BottomBar.swift.
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
    static let storageBookmark = "storageFolderBookmark"
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
    case commandPalette
    case newEntry
    case newVersion
    case toggleHistory
    case toggleTimer
    case recordVideo
    case recordVoiceNote
    case toggleBackspace
    case toggleTheme
    case increaseFontSize
    case decreaseFontSize
    case showWelcomeEntry

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commandPalette: return "Search Entries & Actions"
        case .newEntry: return "New Entry"
        case .newVersion: return "New Version"
        case .toggleHistory: return "Show/Hide History"
        case .toggleTimer: return "Start/Pause Timer"
        case .recordVideo: return "Record Video"
        case .recordVoiceNote: return "Record Voice Note"
        case .toggleBackspace: return "Toggle Backspace"
        case .toggleTheme: return "Toggle Light/Dark"
        case .increaseFontSize: return "Bigger Text"
        case .decreaseFontSize: return "Smaller Text"
        case .showWelcomeEntry: return "Show Welcome Entry"
        }
    }

    var defaultShortcut: KeyShortcut? {
        switch self {
        case .commandPalette: return KeyShortcut(key: "k", modifiers: [.command])
        case .newEntry: return KeyShortcut(key: "n", modifiers: [.command])
        case .newVersion: return KeyShortcut(key: "n", modifiers: [.command, .shift])
        case .toggleHistory: return KeyShortcut(key: "h", modifiers: [.command, .shift])
        case .toggleTimer: return KeyShortcut(key: "t", modifiers: [.command])
        case .recordVideo: return KeyShortcut(key: "r", modifiers: [.command, .shift])
        case .recordVoiceNote: return KeyShortcut(key: "v", modifiers: [.command, .shift])
        case .toggleBackspace: return KeyShortcut(key: "b", modifiers: [.command, .shift])
        case .toggleTheme: return KeyShortcut(key: "l", modifiers: [.command, .shift])
        case .increaseFontSize: return KeyShortcut(key: "=", modifiers: [.command])
        case .decreaseFontSize: return KeyShortcut(key: "-", modifiers: [.command])
        case .showWelcomeEntry: return nil
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

/// Opens the Settings window, or closes it when it's already open (⌘, and the gear toggle it).
@MainActor
enum SettingsWindow {
    static var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains("Settings") == true && $0.isVisible }
    }

    static func toggle(_ openSettings: OpenSettingsAction) {
        if let window {
            window.performClose(nil)
        } else {
            openSettings()
        }
    }
}

struct FreewriteCommands: Commands {
    @AppStorage(SettingsKey.shortcuts) private var shortcutsJSON = "{}"
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { SettingsWindow.toggle(openSettings) }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            button(for: .newEntry)
            button(for: .newVersion)
            button(for: .commandPalette)
        }
        CommandMenu("Write") {
            button(for: .toggleTimer)
            button(for: .toggleBackspace)
            Divider()
            button(for: .increaseFontSize)
            button(for: .decreaseFontSize)
            Divider()
            button(for: .recordVideo)
            button(for: .recordVoiceNote)
        }
        CommandGroup(after: .sidebar) {
            button(for: .toggleHistory)
            button(for: .toggleTheme)
        }
        CommandGroup(after: .help) {
            button(for: .showWelcomeEntry)
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

/// One page of the Settings window. Adding a page = a case here (title, icon, tint, group)
/// plus its view in `SettingsView.pane(_:)`.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case recording
    case storage
    case permissions
    case bottomBar
    case shortcuts
    case about

    /// Sidebar sections, top to bottom.
    enum Group: CaseIterable {
        case top
        case settings
        case app

        var header: String? {
            switch self {
            case .top: return nil
            case .settings: return "Settings"
            case .app: return "Freewrite"
            }
        }
    }

    var id: String { rawValue }

    var group: Group {
        switch self {
        case .general: return .top
        case .about: return .app
        default: return .settings
        }
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .recording: return "Recording"
        case .storage: return "Storage"
        case .permissions: return "Permissions"
        case .bottomBar: return "Bottom Bar"
        case .shortcuts: return "Shortcuts"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape.fill"
        case .recording: return "record.circle"
        case .storage: return "internaldrive.fill"
        case .permissions: return "hand.raised.fill"
        case .bottomBar: return "dock.rectangle"
        case .shortcuts: return "command"
        case .about: return "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .recording: return .red
        case .storage: return .blue
        case .permissions: return .green
        case .bottomBar: return .indigo
        case .shortcuts: return .orange
        case .about: return .gray
        }
    }
}

/// A white SF Symbol on a coloured rounded square, like System Settings.
struct SettingsIconTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

struct SettingsView: View {
    @AppStorage("settingsPane") private var selectedPane: SettingsPane = .general

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { Optional(selectedPane) },
                set: { if let pane = $0 { selectedPane = pane } }
            )) {
                ForEach(SettingsPane.Group.allCases, id: \.self) { group in
                    let panes = SettingsPane.allCases.filter { $0.group == group }
                    if let header = group.header {
                        Section(header) { rows(panes) }
                    } else {
                        Section { rows(panes) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(190)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            pane(selectedPane)
                .navigationTitle(selectedPane.title)
                .toolbar(removing: .title)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        HStack(spacing: 8) {
                            SettingsIconTile(systemImage: selectedPane.systemImage, tint: selectedPane.tint, size: 22)
                            Text(selectedPane.title)
                                .font(.title3.weight(.semibold))
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
        }
        .frame(width: 720, height: 540)
    }

    private func rows(_ panes: [SettingsPane]) -> some View {
        ForEach(panes) { pane in
            Label {
                Text(pane.title)
            } icon: {
                SettingsIconTile(systemImage: pane.systemImage, tint: pane.tint)
            }
            .tag(pane)
            .accessibilityIdentifier("settingsPane-\(pane.rawValue)")
        }
    }

    @ViewBuilder
    private func pane(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralSettingsView()
        case .recording: RecordingSettingsView()
        case .storage: StorageSettingsView()
        case .permissions: PermissionsSettingsView()
        case .bottomBar: BottomBarSettingsView()
        case .shortcuts: ShortcutSettingsView()
        case .about: AboutSettingsView()
        }
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(SettingsKey.fontName) private var fontName = WritingFont.defaultName
    @AppStorage(SettingsKey.fontSize) private var fontSize = WritingFont.defaultSize
    @AppStorage(SettingsKey.colorScheme) private var colorScheme = "light"
    @AppStorage(SettingsKey.sessionMinutes) private var sessionMinutes = 15

    private let allFamilies = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        Form {
            Section("Text") {
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

                HStack {
                    Spacer()
                    Button("Random Font") {
                        if let random = allFamilies.randomElement() {
                            fontName = random
                        }
                    }
                    Button("Reset to Default") {
                        fontName = WritingFont.defaultName
                        fontSize = WritingFont.defaultSize
                    }
                    .disabled(fontName == WritingFont.defaultName && fontSize == WritingFont.defaultSize)
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: $colorScheme) {
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            Section {
                Stepper(value: $sessionMinutes, in: 5...45, step: 5) {
                    Text("Timer length: \(sessionMinutes) min")
                }
            } header: {
                Text("Session")
            } footer: {
                SettingsFootnote("Scroll over the timer in the bottom bar to adjust it while you write.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Small grey text under a Form section.
struct SettingsFootnote: View {
    private let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
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
