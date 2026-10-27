//
//  PrivacySettingsView.swift
//  freewrite
//
//  Settings › Privacy: locked notes (timeout, recovery key) and the recovery key sheets.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PrivacySettingsView: View {
    private let noteLock = NoteLockSession.shared
    private let storage = EntryStorage.shared
    @AppStorage(SettingsKey.noteLockTimeout) private var timeoutMinutes = NoteLockSession.defaultTimeoutMinutes
    @State private var shownKey: ShownRecoveryKey?
    @State private var showingRecoveryEntry = false
    @State private var isWorking = false
    @State private var message: String?

    private var lockedCount: Int { storage.versionStore.lockedEntryFilenames().count }

    private var lockShortcut: String {
        ShortcutStore.shortcut(for: .toggleNoteLock, in: UserDefaults.standard.string(forKey: SettingsKey.shortcuts) ?? "{}")?.displayString
            ?? "its shortcut"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(lockedCount == 1 ? "1 in this folder" : "\(lockedCount) in this folder")
                        .monospacedDigit()
                        .accessibilityIdentifier("lockedNoteCount")
                } label: {
                    Text("Locked notes")
                    Text("Lock one from History, the bottom bar or \(lockShortcut)")
                }
                LabeledContent {
                    HStack {
                        Text(noteLock.isUnlocked ? "Open" : "Locked")
                            .foregroundStyle(.secondary)
                        if noteLock.isUnlocked {
                            Button("Lock Now") { noteLock.lock() }
                        }
                    }
                } label: {
                    Text("Right now")
                    Text("Opening one asks for Touch ID, your Apple Watch or your password")
                }
                Picker(selection: $timeoutMinutes) {
                    ForEach(NoteLockSession.timeoutChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? "Only when the Mac sleeps" : "After \(minutes) min").tag(minutes)
                    }
                } label: {
                    Text("Close again")
                    Text("Without using Freewrite; always when the Mac sleeps or locks")
                }
                .accessibilityIdentifier("noteLockTimeoutPicker")
            } header: {
                Text("Locked Notes")
            }

            Section {
                LabeledContent {
                    HStack {
                        if isWorking {
                            ProgressView().controlSize(.small)
                        }
                        Button("Show…") { showRecoveryKey() }
                            .accessibilityIdentifier("showRecoveryKeyButton")
                    }
                    .disabled(!noteLock.hasVault || isWorking)
                } label: {
                    Text("Recovery key")
                    Text(noteLock.hasVault ? "Opens your locked notes on another Mac" : "You'll get one the first time you lock a note")
                }
                LabeledContent {
                    Button("Create…") { replaceRecoveryKey() }
                        .disabled(!noteLock.hasVault || isWorking)
                } label: {
                    Text("New recovery key")
                    Text("Rewrites this folder's locked notes for the new key")
                }
                LabeledContent {
                    Button("Unlock…") { showingRecoveryEntry = true }
                        .disabled(isWorking || !noteLock.isAvailable)
                        .accessibilityIdentifier("unlockWithRecoveryKeyButton")
                } label: {
                    Text("Notes from another Mac")
                    Text("Enter its recovery key once; after that Touch ID opens them")
                }
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Recovery Key")
            } footer: {
                SettingsFootnote("The recovery key is the only way to open locked notes on another Mac, or on this one if its Touch ID key is lost (e.g. after erasing the Mac). Freewrite can't recover it for you.")
            }

            Section {
                Text("Locked notes, their versions, voice notes and transcripts are encrypted (AES-256) in your entries folder, so other apps, sync services and anyone who copies the folder can't read them. Only dates and the number of versions stay visible. Copies made before you locked a note can still hold its plain text: Time Machine backups, iCloud Drive versions, other folders, and deleted files that linger on the disk. Turn on FileVault to protect those too. While a note is open, its text is in Freewrite's memory. Video entries can't be locked yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let vaultError = noteLock.vaultError {
                    Text(vaultError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if !noteLock.isAvailable {
                    Text(NoteLockError.unavailable.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("What Locking Protects")
            }
        }
        .formStyle(.grouped)
        // The recovery key is never left on screen once locked notes close (idle, sleep, screen
        // lock, Lock Now), the pane is left or the Settings window closes.
        .onChange(of: noteLock.lockCount) { hideRecoveryKey() }
        .onDisappear { hideRecoveryKey() }
        .background(WindowCloseObserver { hideRecoveryKey() })
        .sheet(item: $shownKey) { shown in
            RecoveryKeySheet(recoveryKey: shown.key, mode: shown.mode) { _ in shownKey = nil }
        }
        .sheet(isPresented: $showingRecoveryEntry) {
            RecoveryKeyEntrySheet { key in
                showingRecoveryEntry = false
                if let key { importRecoveryKey(key) }
            }
        }
    }

    private func showRecoveryKey() {
        run {
            let key = try await noteLock.recoveryKey()
            shownKey = ShownRecoveryKey(key: key, mode: .show)
        }
    }

    private func hideRecoveryKey() {
        shownKey = nil
    }

    private func replaceRecoveryKey() {
        guard !storage.isTransferring else {
            message = NoteLockError.busy.localizedDescription
            return
        }
        let alert = NSAlert()
        alert.messageText = "Create a new recovery key?"
        alert.informativeText = "Your locked notes in this folder, including any you unlocked with another recovery key, are rewritten so only the new key opens them. Older copies (backups, other folders) still open with the old key."
        alert.addButton(withTitle: "Create New Key")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run {
            let rotation = try await noteLock.replaceRecoveryKey {
                guard !storage.isTransferring else { throw NoteLockError.busy }
                return storage.versionStore
            }
            // From here the new key is the recovery key: always show it.
            if rotation.notUpdated.isEmpty {
                message = "New recovery key created; \(rotation.updatedFiles) locked file(s) updated."
            } else {
                let notes = rotation.notUpdated.map(Self.noteName).joined(separator: ", ")
                message = "New recovery key created, but \(rotation.notUpdated.count) locked note(s) couldn't be updated (\(notes)). Until they are, they still open only with your previous recovery key on other Macs: keep it, or create a new key again."
            }
            shownKey = ShownRecoveryKey(key: rotation.recoveryKey, mode: .replaced)
        }
    }

    private func importRecoveryKey(_ key: RecoveryKey) {
        run {
            let wraps = storage.versionStore.recoveryWraps()
            guard !wraps.isEmpty else {
                message = "There are no locked notes in this folder."
                return
            }
            let result = try await noteLock.importKeys(with: key, from: wraps)
            var parts: [String] = []
            if let backup = result.replacedVaultBackup {
                parts.append("This Mac's key for locked notes couldn't be used, so Freewrite made a new one from your recovery key (the old one was kept as \(backup.lastPathComponent)).")
            }
            parts.append(result.added == 0
                ? "This Mac can already open the locked notes this recovery key is for."
                : "Done. This Mac now opens those locked notes with its own Touch ID.")
            if result.stillUnknown > 0 {
                parts.append("Some locked notes in this folder need a different recovery key.")
            }
            message = parts.joined(separator: " ")
        }
    }

    /// "Feb 20, 2026" for a locked note's logical filename.
    private static func noteName(_ filename: String) -> String {
        guard let date = StorageTransfer.parseEntryFilename(filename)?.timestamp else { return filename }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do {
                try await work()
            } catch NoteLockError.cancelled {
                // No message.
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

/// Calls `onClose` when the window holding this view closes (e.g. the Settings window).
private struct WindowCloseObserver: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onClose = onClose
    }

    final class ObserverView: NSView {
        var onClose: (() -> Void)?
        private var observer: NSObjectProtocol?

        /// Also called with no window when the view goes away, which removes the observer.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onClose?() }
            }
        }
    }
}

private struct ShownRecoveryKey: Identifiable {
    let id = UUID()
    let key: RecoveryKey
    let mode: RecoveryKeySheet.Mode
}

/// Shows a recovery key with Copy and Save. In `.setUp` (first lock) the user must confirm
/// they saved it before the note is locked.
struct RecoveryKeySheet: View {
    enum Mode {
        case setUp
        case show
        case replaced
    }

    let recoveryKey: RecoveryKey
    let mode: Mode
    /// true = confirmed (lock the note), false = cancelled.
    let onDone: (Bool) -> Void
    @State private var savedIt = false
    @State private var copied = false

    private var title: String {
        switch mode {
        case .setUp: return "Save your recovery key"
        case .show: return "Your recovery key"
        case .replaced: return "Your new recovery key"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title2.weight(.semibold))
            }
            Text(mode == .setUp
                 ? "Locked notes are encrypted and open with Touch ID, your Apple Watch or your password on this Mac. To open them on another Mac, or if this Mac's key is ever lost, you'll need this recovery key. Freewrite can't recover it for you."
                 : "You need this key to open your locked notes on another Mac, or if this Mac's key is ever lost. Keep it somewhere safe, like a password manager.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            Text(recoveryKey.displayString)
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                .accessibilityLabel("Recovery key")
                .accessibilityValue(recoveryKey.displayString)
                .accessibilityIdentifier("recoveryKeyText")

            HStack {
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(recoveryKey.displayString, forType: .string)
                    copied = true
                }
                Button("Save to File…") { saveToFile() }
            }

            if mode == .setUp {
                Toggle("I saved my recovery key somewhere safe", isOn: $savedIt)
                    .accessibilityIdentifier("savedRecoveryKeyToggle")
            }

            HStack {
                Spacer()
                if mode == .setUp {
                    Button("Cancel") { onDone(false) }
                        .keyboardShortcut(.cancelAction)
                    Button("Lock Note") { onDone(true) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!savedIt)
                        .accessibilityIdentifier("confirmLockNoteButton")
                } else {
                    Button("Done") { onDone(true) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func saveToFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Freewrite Recovery Key.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let contents = """
        Freewrite recovery key

        \(recoveryKey.displayString)

        Opens your locked notes on another Mac (Settings › Privacy › Unlock with Recovery Key) or if this Mac's key is lost.
        Keep it private: anyone with this key and your entries folder can read your locked notes.

        """
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Asks for a recovery key (e.g. on a new Mac).
struct RecoveryKeyEntrySheet: View {
    let onDone: (RecoveryKey?) -> Void
    @State private var input = ""

    private var parsed: RecoveryKey? { RecoveryKey(string: input) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Unlock with Recovery Key")
                .font(.title2.weight(.semibold))
            Text("Enter the recovery key you saved when you first locked a note. This Mac then opens the locked notes in your entries folder with its own Touch ID.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $input)
                .font(.system(size: 14, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("recoveryKeyField")
            if !input.isEmpty && parsed == nil {
                Text(NoteLockError.invalidRecoveryKey.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Unlock") { onDone(parsed) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
