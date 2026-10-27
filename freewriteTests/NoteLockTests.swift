//
//  NoteLockTests.swift
//  freewriteTests
//
//  Locked notes with a software device key (no Secure Enclave, no prompt).
//

import CryptoKit
import Foundation
import Testing
@testable import freewrite

struct LockedFileFormatTests {
    private func makeKey(recovery: RecoveryKey = .generate()) throws -> (NoteKey, RecoveryKey) {
        let keyring = try NoteKeyring.new(recovery: recovery)
        return (try #require(keyring.cipher.primary), recovery)
    }

    @Test func roundTripsAnySize() throws {
        let (key, _) = try makeKey()
        for size in [0, 1, 4096, 1 << 20, (1 << 20) + 1] {
            let plain = randomBytes(max(size, 1)).prefix(size)
            let sealed = try LockedFileFormat.seal(Data(plain), with: key)
            #expect(sealed.count == LockedFileFormat.headerLength + size + LockedFileFormat.tagLength)
            #expect(try LockedFileFormat.open(sealed) { $0 == key.id ? key.key : nil } == Data(plain))
        }
    }

    @Test func headerCarriesKeyIdAndRecoveryWrapButNoText() throws {
        let (key, _) = try makeKey()
        let secret = Data("Dear diary, nobody may read this".utf8)
        let sealed = try LockedFileFormat.seal(secret, with: key)
        #expect(sealed.prefix(4) == Data("FWLK".utf8))
        #expect(sealed[4] == 1)
        #expect(sealed[5] == 1)
        let header = try LockedFileFormat.header(of: sealed)
        #expect(header.keyID == key.id)
        #expect(header.recoveryWrap == key.recoveryWrap)
        #expect(sealed.range(of: Data("diary".utf8)) == nil)
        // Same text twice → different files (random salt and nonce).
        #expect(try LockedFileFormat.seal(secret, with: key) != sealed)
    }

    @Test func wrongOrUnknownKeyFails() throws {
        let (key, _) = try makeKey()
        let sealed = try LockedFileFormat.seal(Data("text".utf8), with: key)
        #expect(throws: NoteLockError.damaged) {
            try LockedFileFormat.open(sealed) { _ in SymmetricKey(size: .bits256) }
        }
        #expect(throws: NoteLockError.unknownKey) {
            try LockedFileFormat.open(sealed) { _ in nil }
        }
    }

    @Test func tamperingIsDetected() throws {
        let (key, _) = try makeKey()
        let sealed = try LockedFileFormat.seal(Data("some private words".utf8), with: key)
        let lookup: (Data) -> SymmetricKey? = { $0 == key.id ? key.key : nil }
        // A bit flipped in the salt, nonce, ciphertext and tag; the recovery wrap is authenticated too.
        for offset in [30, 100, 130, LockedFileFormat.headerLength + 2, sealed.count - 1] {
            var copy = sealed
            copy[offset] ^= 0x01
            #expect(throws: NoteLockError.damaged) { try LockedFileFormat.open(copy, key: lookup) }
        }
        #expect(throws: (any Error).self) { try LockedFileFormat.open(sealed.prefix(sealed.count - 3), key: lookup) }
        #expect(throws: (any Error).self) { try LockedFileFormat.open(sealed.prefix(50), key: lookup) }
    }

    @Test func rejectsOtherFilesAndNewerFormats() throws {
        #expect(throws: NoteLockError.notALockedFile) { try LockedFileFormat.header(of: Data("# Just markdown".utf8)) }
        let (key, _) = try makeKey()
        var sealed = try LockedFileFormat.seal(Data("x".utf8), with: key)
        sealed[4] = 2
        #expect(throws: NoteLockError.unsupportedVersion(2)) { try LockedFileFormat.header(of: sealed) }
    }

    @Test func recoveryKeyOpensAFileOnItsOwn() throws {
        let recovery = RecoveryKey.generate()
        let (key, _) = try makeKey(recovery: recovery)
        let sealed = try LockedFileFormat.seal(Data("another Mac".utf8), with: key)

        // Everything another Mac needs is in the file plus the recovery key.
        let header = try LockedFileFormat.header(of: sealed)
        let typed = try #require(RecoveryKey(string: recovery.displayString.lowercased()))
        let recovered = try typed.unwrap(header.recoveryWrap, keyID: header.keyID)
        #expect(try LockedFileFormat.open(sealed) { _ in recovered } == Data("another Mac".utf8))

        #expect(throws: NoteLockError.wrongRecoveryKey) {
            try RecoveryKey.generate().unwrap(header.recoveryWrap, keyID: header.keyID)
        }
        // The wrap is bound to its key id.
        #expect(throws: NoteLockError.wrongRecoveryKey) {
            try recovery.unwrap(header.recoveryWrap, keyID: randomBytes(16))
        }
    }
}

struct RecoveryKeyTests {
    @Test func displayStringRoundTrips() throws {
        for _ in 0..<50 {
            let key = RecoveryKey.generate()
            let string = key.displayString
            #expect(string.count == 39)  // 8 groups of 4 + 7 dashes
            #expect(string.split(separator: "-").count == 8)
            #expect(RecoveryKey(string: string) == key)
        }
    }

    @Test func parsingIsLenient() throws {
        let key = RecoveryKey(secret: Data(repeating: 0, count: 20))
        #expect(key.displayString == "0000-0000-0000-0000-0000-0000-0000-0000")
        #expect(RecoveryKey(string: "oooo oooo 0000-0000 oOoO 0000 0000 0000") == key)
        let ones = RecoveryKey(secret: Data([0x08, 0x42, 0x10, 0x84, 0x21] + [UInt8](repeating: 0, count: 15)))
        #expect(ones.displayString.hasPrefix("1111-1111"))
        #expect(RecoveryKey(string: "iIlL-1111" + ones.displayString.dropFirst(9)) == ones)
    }

    @Test func rejectsWrongLengthOrCharacters() {
        let valid = RecoveryKey.generate().displayString
        #expect(RecoveryKey(string: String(valid.dropLast())) == nil)
        #expect(RecoveryKey(string: valid + "A") == nil)
        #expect(RecoveryKey(string: "U" + valid.dropFirst()) == nil)  // U isn't in the alphabet
        #expect(RecoveryKey(string: "") == nil)
    }
}

struct NoteVaultFileTests {
    @Test func keyringOpensOnlyWithTheDeviceKey() throws {
        let device = P256.KeyAgreement.PrivateKey()
        let keyring = try NoteKeyring.new(recovery: .generate())
        let file = try NoteVaultFile.seal(keyring, deviceKeyData: Data("opaque".utf8), devicePublicKey: device.publicKey)
        #expect(file.keyIDs == [keyring.primaryID])
        #expect(try file.open(with: device) == keyring)
        #expect(throws: NoteLockError.damaged) { try file.open(with: P256.KeyAgreement.PrivateKey()) }
        // No key material in the clear.
        let json = try JSONEncoder().encode(file)
        #expect(json.range(of: keyring.entries[0].key.base64EncodedData()) == nil)
        #expect(json.range(of: keyring.entries[0].recoverySecret.base64EncodedData()) == nil)
    }
}

@MainActor
struct NoteLockSessionTests {
    private let fileManager = FileManager.default

    private func makeFolder() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("freewrite-notelock-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSession(provider: SoftwareKeyProvider = SoftwareKeyProvider()) throws -> NoteLockSession {
        NoteLockSession(vaultURL: try makeFolder().appendingPathComponent("vault.json"), provider: provider)
    }

    @Test func createLockAndUnlock() async throws {
        let provider = SoftwareKeyProvider()
        let session = try makeSession(provider: provider)
        #expect(!session.hasVault)
        await #expect(throws: NoteLockError.noVault) { try await session.unlock() }

        let recovery = RecoveryKey.generate()
        try session.createVault(recovery: recovery)
        #expect(session.isUnlocked)
        #expect(provider.authenticationCount == 0)  // the first lock needs no prompt
        let cipher = try #require(session.cipher)
        let sealed = try cipher.seal(Data("hello".utf8))

        session.lock()
        #expect(session.cipher == nil)

        provider.allowsAuthentication = false
        await #expect(throws: NoteLockError.cancelled) { try await session.unlock() }
        #expect(!session.isUnlocked)

        provider.allowsAuthentication = true
        try await session.unlock()
        try await session.unlock()  // already open: no second prompt
        #expect(provider.authenticationCount == 1)
        #expect(try session.cipher?.open(sealed) == Data("hello".utf8))

        // A fresh session (app relaunch) reads the vault file back.
        let relaunched = NoteLockSession(vaultURL: session.vaultURL, provider: provider)
        #expect(relaunched.hasVault && !relaunched.isUnlocked)
        #expect(relaunched.hasKey(try LockedFileFormat.header(of: sealed).keyID))
        // Showing the recovery key always asks.
        #expect(try await relaunched.recoveryKey() == recovery)
        #expect(provider.authenticationCount == 2)
    }

    @Test func locksAfterIdleTimeout() throws {
        let session = try makeSession()
        try session.createVault(recovery: .generate())
        let start = Date()
        session.noteActivity(at: start)
        session.lockIfIdle(now: start.addingTimeInterval(4 * 60), timeoutMinutes: 5)
        #expect(session.isUnlocked)
        session.lockIfIdle(now: start.addingTimeInterval(60 * 60), timeoutMinutes: 0)  // only on sleep
        #expect(session.isUnlocked)
        session.lockIfIdle(now: start.addingTimeInterval(5 * 60), timeoutMinutes: 5)
        #expect(!session.isUnlocked)
    }

    @Test func newRecoveryKeyRewritesLockedFiles() async throws {
        let session = try makeSession()
        let oldRecovery = RecoveryKey.generate()
        try session.createVault(recovery: oldRecovery)
        let store = try EntryVersionStore(root: makeFolder(), cipher: session.cipher)
        let entry = "[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04].md"
        try "secret".write(to: store.entryFileURL(for: entry), atomically: true, encoding: .utf8)
        try store.lock(entryFilename: entry)

        let newRecovery = try await session.replaceRecoveryKey()
        #expect(newRecovery != oldRecovery)
        let resealed = EntryVersionStore(root: store.root, cipher: session.cipher)
        #expect(try resealed.resealLockedFiles() == 1)

        let header = try LockedFileFormat.header(ofFileAt: store.lockedEntryFileURL(for: entry))
        #expect(throws: NoteLockError.wrongRecoveryKey) { try oldRecovery.unwrap(header.recoveryWrap, keyID: header.keyID) }
        let key = try newRecovery.unwrap(header.recoveryWrap, keyID: header.keyID)
        #expect(try LockedFileFormat.open(Data(contentsOf: store.lockedEntryFileURL(for: entry))) { _ in key } == Data("secret".utf8))
    }

    @Test func anotherMacUnlocksWithTheRecoveryKey() async throws {
        // Mac A locks a note.
        let macA = try makeSession()
        let recovery = RecoveryKey.generate()
        try macA.createVault(recovery: recovery)
        let folder = try makeFolder()
        let entry = "[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04].md"
        let storeA = EntryVersionStore(root: folder, cipher: macA.cipher)
        try "from Mac A".write(to: storeA.entryFileURL(for: entry), atomically: true, encoding: .utf8)
        try storeA.lock(entryFilename: entry)

        // Mac B (its own vault and key) sees the synced folder.
        let providerB = SoftwareKeyProvider()
        let macB = try makeSession(provider: providerB)
        try macB.createVault(recovery: .generate())
        let wraps = EntryVersionStore(root: folder).recoveryWraps()
        #expect(wraps.count == 1)
        #expect(!macB.hasKey(try #require(wraps.keys.first)))
        #expect(throws: NoteLockError.unknownKey) {
            try EntryVersionStore(root: folder, cipher: macB.cipher).currentText(for: entry)
        }

        await #expect(throws: NoteLockError.wrongRecoveryKey) { try await macB.importKeys(with: .generate(), from: wraps) }
        #expect(try await macB.importKeys(with: recovery, from: wraps) == 1)
        #expect(try await macB.importKeys(with: recovery, from: wraps) == 0)
        #expect(try EntryVersionStore(root: folder, cipher: macB.cipher).currentText(for: entry) == "from Mac A")

        // After a relaunch, Mac B opens it with its own device key.
        let relaunched = NoteLockSession(vaultURL: macB.vaultURL, provider: providerB)
        try await relaunched.unlock()
        #expect(try EntryVersionStore(root: folder, cipher: relaunched.cipher).currentText(for: entry) == "from Mac A")

        // A brand-new Mac without a vault gets one from the recovery key alone.
        let macC = try makeSession()
        #expect(try await macC.importKeys(with: recovery, from: wraps) == 1)
        #expect(macC.hasVault)
        #expect(try EntryVersionStore(root: folder, cipher: macC.cipher).currentText(for: entry) == "from Mac A")
    }
}

struct LockedEntryStoreTests {
    private let fileManager = FileManager.default
    private let entry = "[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04].md"
    private let base = "[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04]"

    private func makeCipher() throws -> NoteCipher {
        try NoteKeyring.new(recovery: .generate()).cipher
    }

    /// An entry with v1 sealed (with a voice note and transcript), v2 current and annotations.
    private func makeEntry(cipher: NoteCipher) throws -> EntryVersionStore {
        let root = fileManager.temporaryDirectory.appendingPathComponent("freewrite-locked-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let store = EntryVersionStore(root: root, cipher: cipher)
        try "first draft".write(to: store.entryFileURL(for: entry), atomically: true, encoding: .utf8)
        let audio = root.appendingPathComponent("recording.m4a")
        try Data("AUDIO".utf8).write(to: audio)
        let attachment = try store.attachVoiceNote(from: audio, to: entry)
        try store.saveTranscript("spoken words", forAudio: attachment.audioPath, entryFilename: entry)
        try store.sealCurrent(entryFilename: entry)
        try "second draft".write(to: store.entryFileURL(for: entry), atomically: true, encoding: .utf8)
        try "{\"notes\":[]}".write(to: store.entryDirectory(for: entry).appendingPathComponent("annotations.json"), atomically: true, encoding: .utf8)
        return store
    }

    private func files(in store: EntryVersionStore) -> [String] {
        let prefix = store.root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return (fileManager.enumerator(at: store.root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            .map { String($0.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(prefix.count)) }
            .sorted()
    }

    @Test func lockEncryptsEveryFileButTheManifest() throws {
        let cipher = try makeCipher()
        let store = try makeEntry(cipher: cipher)
        #expect(!store.isLocked(entry))
        let notRemoved = try store.lock(entryFilename: entry)
        #expect(notRemoved.isEmpty)
        #expect(store.isLocked(entry))
        #expect(files(in: store) == [
            "Entries/\(base)/annotations.json.fwlock",
            "Entries/\(base)/audio/v1.m4a.fwlock",
            "Entries/\(base)/audio/v1.transcript.md.fwlock",
            "Entries/\(base)/entry.json",
            "Entries/\(base)/versions/v1.md.fwlock",
            "\(base).fwlock",
        ])
        #expect(store.lockedEntryFilenames() == [entry])
        // Nothing readable on disk.
        for path in files(in: store) where path.hasSuffix(".fwlock") {
            let data = try Data(contentsOf: store.root.appendingPathComponent(path))
            for word in ["draft", "spoken", "AUDIO", "notes"] {
                #expect(data.range(of: Data(word.utf8)) == nil)
            }
        }

        // Readable through the store with the keys…
        #expect(try store.currentText(for: entry) == "second draft")
        #expect(try store.text(of: "v1", for: entry) == "first draft")
        #expect(try store.data(atRelativePath: "audio/v1.m4a", entryFilename: entry) == Data("AUDIO".utf8))
        #expect(store.fileExists(atRelativePath: "audio/v1.transcript.md", entryFilename: entry))
        // …and not without them.
        let closed = EntryVersionStore(root: store.root)
        #expect(throws: NoteLockError.locked) { try closed.currentText(for: entry) }
        #expect(throws: NoteLockError.locked) { try closed.saveCurrentText("overwrite", for: entry) }
        #expect(throws: NoteLockError.alreadyLocked) { try store.lock(entryFilename: entry) }
    }

    @Test func lockedEntryKeepsVersioningEncrypted() throws {
        let cipher = try makeCipher()
        let store = try makeEntry(cipher: cipher)
        try store.lock(entryFilename: entry)

        try store.saveCurrentText("third", for: entry)
        let manifest = try store.sealCurrent(entryFilename: entry)
        #expect(manifest.current == "v3")
        #expect(try store.text(of: "v2", for: entry) == "third")
        #expect(try store.currentText(for: entry) == "")
        #expect(fileManager.fileExists(atPath: store.entryDirectory(for: entry).appendingPathComponent("versions/v2.md.fwlock").path))
        #expect(!fileManager.fileExists(atPath: store.entryDirectory(for: entry).appendingPathComponent("versions/v2.md").path))

        // A voice note on a locked entry: encrypted copy, recording kept for transcription.
        let recording = fileManager.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString).m4a")
        try Data("NEW AUDIO".utf8).write(to: recording)
        let attachment = try store.attachVoiceNote(from: recording, to: entry)
        #expect(attachment.temporaryPlaintextURL == recording)
        #expect(attachment.audioPath == "audio/v3.m4a")
        #expect(fileManager.fileExists(atPath: recording.path))
        #expect(!fileManager.fileExists(atPath: attachment.audioURL.path))
        #expect(try store.data(atRelativePath: attachment.audioPath, entryFilename: entry) == Data("NEW AUDIO".utf8))
        #expect(attachment.manifest.currentVersion?.source == .voiceNote)
        try fileManager.removeItem(at: recording)
    }

    @Test func unlockRestoresIdenticalPlainFiles() throws {
        let cipher = try makeCipher()
        let store = try makeEntry(cipher: cipher)
        let before = try files(in: store).map { ($0, try Data(contentsOf: store.root.appendingPathComponent($0))) }
        try store.lock(entryFilename: entry)
        try store.unlock(entryFilename: entry)
        #expect(!store.isLocked(entry))
        let after = try files(in: store).map { ($0, try Data(contentsOf: store.root.appendingPathComponent($0))) }
        #expect(before.map(\.0) == after.map(\.0))
        #expect(before.map(\.1) == after.map(\.1))
        #expect(throws: NoteLockError.notLocked) { try store.unlock(entryFilename: entry) }
    }

    @Test func failedLockLeavesTheEntryAlone() throws {
        let store = try makeEntry(cipher: try makeCipher())
        let before = files(in: store)
        // No keys: nothing happens.
        #expect(throws: NoteLockError.locked) { try EntryVersionStore(root: store.root).lock(entryFilename: entry) }
        // A file that can't be read halfway through: the encrypted copies made so far are removed.
        let unreadable = store.entryDirectory(for: entry).appendingPathComponent("versions/v1.md")
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
        #expect(throws: (any Error).self) { try store.lock(entryFilename: entry) }
        #expect(files(in: store) == before)
        #expect(!store.isLocked(entry))
    }

    @Test func wrongKeyCantOpenOrUnlock() throws {
        let store = try makeEntry(cipher: try makeCipher())
        try store.lock(entryFilename: entry)
        let other = EntryVersionStore(root: store.root, cipher: try makeCipher())
        #expect(throws: NoteLockError.unknownKey) { try other.currentText(for: entry) }
        #expect(throws: NoteLockError.unknownKey) { try other.unlock(entryFilename: entry) }
        #expect(store.isLocked(entry))
    }

    @Test func leftoverPlainCopiesAreRemovedOnlyWhenIdentical() throws {
        let cipher = try makeCipher()
        let store = try makeEntry(cipher: cipher)
        try store.lock(entryFilename: entry)
        // As if a lock was interrupted before deleting the plain files.
        try "second draft".write(to: store.entryFileURL(for: entry), atomically: true, encoding: .utf8)
        let edited = store.entryDirectory(for: entry).appendingPathComponent("versions/v1.md")
        try "edited elsewhere".write(to: edited, atomically: true, encoding: .utf8)
        store.removeLeftoverPlainFiles(of: entry)
        #expect(!fileManager.fileExists(atPath: store.entryFileURL(for: entry).path))
        #expect(fileManager.fileExists(atPath: edited.path))
    }
}

struct BottomBarLockItemTests {
    @Test func lockIsAddedBeforeSettingsForExistingLayouts() {
        let stored = #"{"slots":[{"item":"history","placement":"right"},{"item":"settings","placement":"right"},{"item":"timer","placement":"left"}]}"#
        let layout = BottomBarLayout.decode(stored)
        let items = layout.slots.map(\.item)
        #expect(items.firstIndex(of: .lock)! + 1 == items.firstIndex(of: .settings)!)
        #expect(layout.slots.first { $0.item == .lock }?.placement == .right)
        #expect(BottomBarLayout.default.right.suffix(2) == [.lock, .settings])
    }
}
