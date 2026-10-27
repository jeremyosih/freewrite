//
//  NoteLockFailureTests.swift
//  freewriteTests
//
//  Unlocking, changing the recovery key and recovering a vault when files or keys fail.
//

import CryptoKit
import Foundation
import Testing
@testable import freewrite

/// Real file operations, except that the `n`th matching call of one kind fails.
final class FailingFileOperations: NoteLockFileOperations, @unchecked Sendable {
    enum Kind { case write, remove, replace }

    private let kind: Kind
    private let failingCall: Int
    private let matches: @Sendable (URL) -> Bool
    /// The failing call does its work anyway before throwing (e.g. a delete that reports an error).
    private let performsFailingCall: Bool
    private let lock = NSLock()
    private var calls = 0
    private let standard = StandardNoteLockFileOperations()

    init(failing kind: Kind, onCall failingCall: Int = 1, performsFailingCall: Bool = false, where matches: @escaping @Sendable (URL) -> Bool = { _ in true }) {
        self.kind = kind
        self.failingCall = failingCall
        self.performsFailingCall = performsFailingCall
        self.matches = matches
    }

    private func check(_ kind: Kind, _ url: URL, perform: () throws -> Void) throws {
        let fails: Bool = lock.withLock {
            guard kind == self.kind, matches(url) else { return false }
            calls += 1
            return calls == failingCall
        }
        guard fails else { return try perform() }
        if performsFailingCall { try perform() }
        throw CocoaError(.fileWriteUnknown)
    }

    func write(_ data: Data, to url: URL) throws {
        try check(.write, url) { try standard.write(data, to: url) }
    }

    func removeItem(at url: URL) throws {
        try check(.remove, url) { try standard.removeItem(at: url) }
    }

    func replaceItem(at url: URL, withItemAt staged: URL) throws {
        try check(.replace, url) { try standard.replaceItem(at: url, withItemAt: staged) }
    }
}

private var fileManager: FileManager { .default }
private let entry = "[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04].md"
private let otherEntry = "[0B6F3A57-2D1C-4F7E-9C51-8A2E4B6D7F10]-[2026-03-01-09-30-00].md"
private let thirdEntry = "[5C3D2E1F-0A9B-4C8D-8E7F-6A5B4C3D2E1F]-[2026-04-11-21-15-30].md"

private func makeFolder() throws -> URL {
    let url = fileManager.temporaryDirectory.appendingPathComponent("freewrite-lockfail-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Every regular file under `root` (hidden ones too) with its bytes.
private func snapshot(_ root: URL) -> [String: Data] {
    let prefix = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
    var files: [String: Data] = [:]
    for case let url as URL in fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) ?? FileManager.DirectoryEnumerator() {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        files[String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(prefix.count))] = try? Data(contentsOf: url)
    }
    return files
}

private func setModificationDate(_ date: Date, of url: URL) throws {
    try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

/// An entry with v1 sealed (voice note + transcript), v2 current and annotations.
private func makeEntry(_ name: String = entry, in store: EntryVersionStore, text: String = "second draft") throws {
    try "first draft".write(to: store.entryFileURL(for: name), atomically: true, encoding: .utf8)
    let audio = store.root.appendingPathComponent("recording-\(UUID().uuidString).m4a")
    try Data("AUDIO".utf8).write(to: audio)
    let attachment = try store.attachVoiceNote(from: audio, to: name)
    try store.saveTranscript("spoken words", forAudio: attachment.audioPath, entryFilename: name)
    try store.sealCurrent(entryFilename: name)
    try text.write(to: store.entryFileURL(for: name), atomically: true, encoding: .utf8)
    try "{\"notes\":[]}".write(to: store.entryDirectory(for: name).appendingPathComponent("annotations.json"), atomically: true, encoding: .utf8)
}

/// Whether `recovery` alone (as on another Mac) opens every locked file of `name`.
private func recoveryOpens(_ recovery: RecoveryKey, _ name: String, in store: EntryVersionStore) throws -> Bool {
    let closed = EntryVersionStore(root: store.root)
    let urls = (fileManager.enumerator(at: closed.entryDirectory(for: name), includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
        .filter { $0.pathExtension == LockedFileFormat.fileExtension } + [closed.lockedEntryFileURL(for: name)]
    for url in urls {
        let data = try Data(contentsOf: url)
        let header = try LockedFileFormat.header(of: data)
        guard let key = try? recovery.unwrap(header.recoveryWrap, keyID: header.keyID),
              (try? LockedFileFormat.open(data) { _ in key }) != nil else { return false }
    }
    return true
}

// MARK: - Unlocking (finding: unlocked edits can disappear)

struct UnlockFailureTests {
    private func lockedStore() throws -> (EntryVersionStore, [String: Data]) {
        let store = EntryVersionStore(root: try makeFolder(), cipher: try NoteKeyring.new(recovery: .generate()).cipher)
        try makeEntry(in: store)
        try store.lock(entryFilename: entry)
        return (store, snapshot(store.root))
    }

    @Test func failingToDeleteTheTopLevelFileKeepsTheNoteLocked() throws {
        var (store, lockedFiles) = try lockedStore()
        let top = store.lockedEntryFileURL(for: entry).lastPathComponent
        store.lockFileOperations = FailingFileOperations(failing: .remove, where: { $0.lastPathComponent == top })
        #expect(throws: (any Error).self) { try store.unlock(entryFilename: entry) }
        // Still locked, every encrypted file intact, no plain copy left behind.
        #expect(store.isLocked(entry))
        #expect(snapshot(store.root) == lockedFiles)
        #expect(try store.currentText(for: entry) == "second draft")
        #expect(try store.text(of: "v1", for: entry) == "first draft")
    }

    @Test func failingWriteHalfwayRemovesThePlainCopies() throws {
        for call in 1...5 {
            var (store, lockedFiles) = try lockedStore()
            store.lockFileOperations = FailingFileOperations(failing: .write, onCall: call)
            #expect(throws: (any Error).self) { try store.unlock(entryFilename: entry) }
            #expect(store.isLocked(entry))
            #expect(snapshot(store.root) == lockedFiles)
        }
    }

    @Test func aDeleteThatReportsAnErrorButHappenedStillUnlocks() throws {
        var (store, _) = try lockedStore()
        let top = store.lockedEntryFileURL(for: entry).lastPathComponent
        store.lockFileOperations = FailingFileOperations(failing: .remove, performsFailingCall: true, where: { $0.lastPathComponent == top })
        try store.unlock(entryFilename: entry)
        #expect(!store.isLocked(entry))
        #expect(try String(contentsOf: store.entryFileURL(for: entry), encoding: .utf8) == "second draft")
        #expect(try store.text(of: "v1", for: entry) == "first draft")
    }

    @Test func staleEncryptedFilesAreReportedAndHarmless() throws {
        var (store, _) = try lockedStore()
        store.lockFileOperations = FailingFileOperations(failing: .remove, where: { $0.lastPathComponent == "v1.md.fwlock" })
        let stale = try store.unlock(entryFilename: entry)
        #expect(stale.map(\.lastPathComponent) == ["v1.md.fwlock"])
        #expect(!store.isLocked(entry))
        // Plain readers and writers work; the stale file is ignored.
        #expect(try store.text(of: "v1", for: entry) == "first draft")
        try store.saveCurrentText("edited after unlocking", for: entry)
        #expect(try String(contentsOf: store.entryFileURL(for: entry), encoding: .utf8) == "edited after unlocking")
        // Locking again overwrites it.
        store.lockFileOperations = StandardNoteLockFileOperations()
        try store.lock(entryFilename: entry)
        #expect(try store.text(of: "v1", for: entry) == "first draft")
        #expect(try store.currentText(for: entry) == "edited after unlocking")
    }

    @Test func neverOverwritesADifferentPlainFile() throws {
        let (store, _) = try lockedStore()
        let other = store.entryDirectory(for: entry).appendingPathComponent("versions/v1.md")
        try "something else".write(to: other, atomically: true, encoding: .utf8)
        try setModificationDate(Date().addingTimeInterval(-3600), of: other)
        let before = snapshot(store.root)
        #expect(throws: NoteLockError.plainCopyConflict("v1.md")) { try store.unlock(entryFilename: entry) }
        #expect(store.isLocked(entry))
        #expect(snapshot(store.root) == before)
    }
}

// MARK: - Leftovers of an interrupted unlock

struct LeftoverPlainFilesTests {
    /// The state an earlier build left when deleting the top-level `.fwlock` failed: plain files
    /// everywhere, the encrypted versions gone, and later edits saved to the plain `.md`.
    @Test func newerPlainEditsComeBackAndNothingIsLost() throws {
        let store = EntryVersionStore(root: try makeFolder(), cipher: try NoteKeyring.new(recovery: .generate()).cipher)
        try makeEntry(in: store)
        try store.lock(entryFilename: entry)
        let lockedTop = store.lockedEntryFileURL(for: entry)
        try setModificationDate(Date().addingTimeInterval(-600), of: lockedTop)
        let directory = store.entryDirectory(for: entry)
        try fileManager.removeItem(at: directory.appendingPathComponent("versions/v1.md.fwlock"))
        try "first draft".write(to: directory.appendingPathComponent("versions/v1.md"), atomically: true, encoding: .utf8)
        try "second draft, edited while it looked unlocked".write(to: store.entryFileURL(for: entry), atomically: true, encoding: .utf8)

        #expect(store.hasNewerPlainCopy(entry))
        let result = try store.reconcileLeftoverPlainFiles(of: entry)
        #expect(result.restoredNewerText)
        #expect(result.sealedVersion == "v2")
        #expect(result.encrypted.map(\.lastPathComponent) == ["v1.md"])
        #expect(result.kept.isEmpty)
        #expect(!store.hasNewerPlainCopy(entry))
        #expect(!fileManager.fileExists(atPath: store.entryFileURL(for: entry).path))
        #expect(!fileManager.fileExists(atPath: directory.appendingPathComponent("versions/v1.md").path))
        #expect(try store.currentText(for: entry) == "second draft, edited while it looked unlocked")
        #expect(try store.text(of: "v2", for: entry) == "second draft")
        #expect(try store.text(of: "v1", for: entry) == "first draft")
        #expect(store.manifest(for: entry).versions.count == 3)
    }

    @Test func olderDifferentPlainCopyIsKept() throws {
        let store = EntryVersionStore(root: try makeFolder(), cipher: try NoteKeyring.new(recovery: .generate()).cipher)
        try makeEntry(in: store)
        try store.lock(entryFilename: entry)
        try store.saveCurrentText("edited after locking", for: entry)
        let plain = store.entryFileURL(for: entry)
        try "second draft".write(to: plain, atomically: true, encoding: .utf8)
        try setModificationDate(Date().addingTimeInterval(-600), of: plain)
        #expect(!store.hasNewerPlainCopy(entry))
        let result = try store.reconcileLeftoverPlainFiles(of: entry)
        #expect(!result.restoredNewerText)
        #expect(result.kept.map(\.lastPathComponent) == [plain.lastPathComponent])
        #expect(try store.currentText(for: entry) == "edited after locking")
        #expect(fileManager.fileExists(atPath: plain.path))
    }

    @Test func unlockingBringsBackNewerEditsToo() throws {
        let store = EntryVersionStore(root: try makeFolder(), cipher: try NoteKeyring.new(recovery: .generate()).cipher)
        try makeEntry(in: store)
        try store.lock(entryFilename: entry)
        try setModificationDate(Date().addingTimeInterval(-600), of: store.lockedEntryFileURL(for: entry))
        try "newest words".write(to: store.entryFileURL(for: entry), atomically: true, encoding: .utf8)
        try store.unlock(entryFilename: entry)
        #expect(!store.isLocked(entry))
        #expect(try String(contentsOf: store.entryFileURL(for: entry), encoding: .utf8) == "newest words")
        #expect(try store.text(of: "v2", for: entry) == "second draft")
        #expect(snapshot(store.root).keys.allSatisfy { !$0.hasSuffix(".fwlock") })
    }
}

// MARK: - New recovery key (findings: imported notes, split keys)

@MainActor
struct RecoveryKeyRotationTests {
    private func makeSession(provider: SoftwareKeyProvider = SoftwareKeyProvider()) throws -> NoteLockSession {
        NoteLockSession(vaultURL: try makeFolder().appendingPathComponent("vault.json"), provider: provider)
    }

    /// Mac A locks `entry`, Mac B locks `otherEntry` in the same folder, and A imports B's key.
    private func folderWithImportedNote() async throws -> (session: NoteLockSession, folder: URL, recoveryA: RecoveryKey, recoveryB: RecoveryKey) {
        let folder = try makeFolder()
        let macB = try makeSession()
        let recoveryB = RecoveryKey.generate()
        try macB.createVault(recovery: recoveryB)
        let storeB = EntryVersionStore(root: folder, cipher: macB.cipher)
        try makeEntry(otherEntry, in: storeB, text: "from Mac B")
        try storeB.lock(entryFilename: otherEntry)

        let macA = try makeSession()
        let recoveryA = RecoveryKey.generate()
        try macA.createVault(recovery: recoveryA)
        let storeA = EntryVersionStore(root: folder, cipher: macA.cipher)
        try makeEntry(in: storeA, text: "from Mac A")
        try storeA.lock(entryFilename: entry)
        #expect(try await macA.importKeys(with: recoveryB, from: storeA.recoveryWraps()).added == 1)
        return (macA, folder, recoveryA, recoveryB)
    }

    @Test func newKeyOpensImportedNotesToo() async throws {
        let (session, folder, recoveryA, recoveryB) = try await folderWithImportedNote()
        let rotation = try await session.replaceRecoveryKey { EntryVersionStore(root: folder, cipher: session.cipher) }
        #expect(rotation.notUpdated.isEmpty)
        #expect(rotation.updatedFiles == 10)  // 5 files per note
        let store = EntryVersionStore(root: folder)
        for name in [entry, otherEntry] {
            #expect(try recoveryOpens(rotation.recoveryKey, name, in: store))
            #expect(try !recoveryOpens(recoveryA, name, in: store))
            #expect(try !recoveryOpens(recoveryB, name, in: store))
        }
        // A fresh Mac with only the new key opens both.
        let fresh = try makeSession()
        let imported = try await fresh.importKeys(with: rotation.recoveryKey, from: store.recoveryWraps())
        #expect(imported.added == 2 && imported.stillUnknown == 0)
        #expect(try EntryVersionStore(root: folder, cipher: fresh.cipher).currentText(for: otherEntry) == "from Mac B")
        #expect(try await session.recoveryKey() == rotation.recoveryKey)
        // No hidden staging copies left.
        #expect(snapshot(folder).keys.allSatisfy { !$0.hasSuffix(".rekey") })
    }

    @Test func notesThisMacCantOpenAreReported() async throws {
        let (session, folder, _, _) = try await folderWithImportedNote()
        let macC = try makeSession()
        let recoveryC = RecoveryKey.generate()
        try macC.createVault(recovery: recoveryC)
        let storeC = EntryVersionStore(root: folder, cipher: macC.cipher)
        try makeEntry(thirdEntry, in: storeC, text: "from Mac C")
        try storeC.lock(entryFilename: thirdEntry)

        let rotation = try await session.replaceRecoveryKey { EntryVersionStore(root: folder, cipher: session.cipher) }
        #expect(rotation.notUpdated == [thirdEntry])
        #expect(try recoveryOpens(rotation.recoveryKey, entry, in: EntryVersionStore(root: folder)))
        #expect(try recoveryOpens(recoveryC, thirdEntry, in: EntryVersionStore(root: folder)))
    }

    @Test func failedStagingChangesNothing() async throws {
        let (session, folder, recoveryA, recoveryB) = try await folderWithImportedNote()
        let before = snapshot(folder)
        let vaultBefore = try Data(contentsOf: session.vaultURL)
        for call in [1, 4, 9] {
            await #expect(throws: (any Error).self) {
                _ = try await session.replaceRecoveryKey {
                    var store = EntryVersionStore(root: folder, cipher: session.cipher)
                    store.lockFileOperations = FailingFileOperations(failing: .write, onCall: call)
                    return store
                }
            }
            #expect(snapshot(folder) == before)
            #expect(try Data(contentsOf: session.vaultURL) == vaultBefore)
            #expect(try await session.recoveryKey() == recoveryA)
        }
        #expect(try recoveryOpens(recoveryA, entry, in: EntryVersionStore(root: folder)))
        #expect(try recoveryOpens(recoveryB, otherEntry, in: EntryVersionStore(root: folder)))
    }

    @Test func failedReplaceStillShowsTheNewKeyAndKeepsTheOldOneWorking() async throws {
        let (session, folder, _, recoveryB) = try await folderWithImportedNote()
        let base = (otherEntry as NSString).deletingPathExtension
        let rotation = try await session.replaceRecoveryKey {
            var store = EntryVersionStore(root: folder, cipher: session.cipher)
            store.lockFileOperations = FailingFileOperations(failing: .replace, where: { $0.path.contains(base) && $0.lastPathComponent == "v1.md.fwlock" })
            return store
        }
        #expect(rotation.notUpdated == [otherEntry])
        #expect(rotation.updatedFiles == 9)
        #expect(try await session.recoveryKey() == rotation.recoveryKey)
        let store = EntryVersionStore(root: folder)
        #expect(try recoveryOpens(rotation.recoveryKey, entry, in: store))
        // The note that wasn't fully updated: its v1 still opens with the old key, the rest with the new one.
        let v1 = store.entryDirectory(for: otherEntry).appendingPathComponent("versions/v1.md.fwlock")
        let header = try LockedFileFormat.header(ofFileAt: v1)
        #expect((try? recoveryB.unwrap(header.recoveryWrap, keyID: header.keyID)) != nil)
        #expect(try EntryVersionStore(root: folder, cipher: session.cipher).text(of: "v1", for: otherEntry) == "first draft")
        #expect(snapshot(folder).keys.allSatisfy { !$0.hasSuffix(".rekey") })

        // Creating a key again updates everything.
        let retry = try await session.replaceRecoveryKey { EntryVersionStore(root: folder, cipher: session.cipher) }
        #expect(retry.notUpdated.isEmpty)
        for name in [entry, otherEntry] {
            #expect(try recoveryOpens(retry.recoveryKey, name, in: store))
        }
    }
}

// MARK: - Recovering a vault that can't be used (finding: recovery cannot repair a vault)

@MainActor
struct VaultRepairTests {
    private func lockedFolder() throws -> (session: NoteLockSession, provider: SoftwareKeyProvider, folder: URL, recovery: RecoveryKey) {
        let provider = SoftwareKeyProvider()
        let session = NoteLockSession(vaultURL: try makeFolder().appendingPathComponent("vault.json"), provider: provider)
        let recovery = RecoveryKey.generate()
        try session.createVault(recovery: recovery)
        let folder = try makeFolder()
        let store = EntryVersionStore(root: folder, cipher: session.cipher)
        try makeEntry(in: store, text: "precious")
        try store.lock(entryFilename: entry)
        return (session, provider, folder, recovery)
    }

    /// vault.json as restored onto another Mac: same key ids, a device key this Mac can't use.
    private func makeDeviceKeyUnusable(_ url: URL) throws {
        var vault = try #require(try NoteVaultFile.load(from: url))
        vault.deviceKey = P256.KeyAgreement.PrivateKey().rawRepresentation
        try vault.save(to: url)
    }

    @Test func recoveryRebuildsAVaultFromAnotherMac() async throws {
        let (session, provider, folder, recovery) = try lockedFolder()
        try makeDeviceKeyUnusable(session.vaultURL)
        let restored = NoteLockSession(vaultURL: session.vaultURL, provider: provider)
        let wraps = EntryVersionStore(root: folder).recoveryWraps()
        #expect(restored.hasKey(try #require(wraps.keys.first)))  // ids still match
        await #expect(throws: NoteLockError.deviceKeyUnusable) { try await restored.unlock() }

        // A wrong recovery key changes nothing.
        let vaultBefore = try Data(contentsOf: session.vaultURL)
        await #expect(throws: NoteLockError.wrongRecoveryKey) { try await restored.importKeys(with: .generate(), from: wraps) }
        #expect(try Data(contentsOf: session.vaultURL) == vaultBefore)

        let result = try await restored.importKeys(with: recovery, from: wraps)
        #expect(result.added == 1 && result.stillUnknown == 0)
        let backup = try #require(result.replacedVaultBackup)
        #expect(try Data(contentsOf: backup) == vaultBefore)  // the old vault is kept, not discarded
        #expect(try EntryVersionStore(root: folder, cipher: restored.cipher).currentText(for: entry) == "precious")

        // After a relaunch this Mac opens it with its own (new) device key, and can lock more.
        let relaunched = NoteLockSession(vaultURL: session.vaultURL, provider: provider)
        try await relaunched.unlock()
        #expect(try EntryVersionStore(root: folder, cipher: relaunched.cipher).currentText(for: entry) == "precious")
        #expect(try await relaunched.recoveryKey() == recovery)
    }

    @Test func recoveryReplacesAnUnreadableVault() async throws {
        let (session, provider, folder, recovery) = try lockedFolder()
        try Data("not json".utf8).write(to: session.vaultURL)
        let damaged = NoteLockSession(vaultURL: session.vaultURL, provider: provider)
        #expect(damaged.vaultError != nil && !damaged.hasVault)
        let result = try await damaged.importKeys(with: recovery, from: EntryVersionStore(root: folder).recoveryWraps())
        #expect(result.added == 1)
        #expect(try Data(contentsOf: try #require(result.replacedVaultBackup)) == Data("not json".utf8))
        #expect(damaged.vaultError == nil && damaged.hasVault)
        #expect(try EntryVersionStore(root: folder, cipher: damaged.cipher).currentText(for: entry) == "precious")
    }

    @Test func keysOfOtherRecoveryKeysAreReported() async throws {
        let (session, provider, folder, recovery) = try lockedFolder()
        let other = NoteLockSession(vaultURL: try makeFolder().appendingPathComponent("vault.json"), provider: SoftwareKeyProvider())
        try other.createVault(recovery: .generate())
        let otherStore = EntryVersionStore(root: folder, cipher: other.cipher)
        try makeEntry(otherEntry, in: otherStore)
        try otherStore.lock(entryFilename: otherEntry)

        try makeDeviceKeyUnusable(session.vaultURL)
        let restored = NoteLockSession(vaultURL: session.vaultURL, provider: provider)
        let result = try await restored.importKeys(with: recovery, from: EntryVersionStore(root: folder).recoveryWraps())
        #expect(result.added == 1 && result.stillUnknown == 1)
        #expect(result.replacedVaultBackup != nil)
    }

    @Test func aUsableVaultIsKeptAndCancellingChangesNothing() async throws {
        let (session, provider, folder, recovery) = try lockedFolder()
        session.lock()
        let vaultBefore = try Data(contentsOf: session.vaultURL)
        let wraps = EntryVersionStore(root: folder).recoveryWraps()
        provider.allowsAuthentication = false
        await #expect(throws: NoteLockError.cancelled) { try await session.importKeys(with: recovery, from: wraps) }
        provider.allowsAuthentication = true
        let result = try await session.importKeys(with: recovery, from: wraps)
        #expect(result == RecoveryImport(added: 0, replacedVaultBackup: nil, stillUnknown: 0))
        #expect(try Data(contentsOf: session.vaultURL) == vaultBefore)
    }
}

// MARK: - Closing hides secrets (finding: recovery key survives idle lock)

@MainActor
struct LockCountTests {
    @Test func everyCloseIsCounted() throws {
        let session = NoteLockSession(vaultURL: try makeFolder().appendingPathComponent("vault.json"), provider: SoftwareKeyProvider())
        session.lock()  // nothing open: still counted (a sheet may show a key)
        #expect(session.lockCount == 1)
        try session.createVault(recovery: .generate())
        let start = Date()
        session.noteActivity(at: start)
        session.lockIfIdle(now: start.addingTimeInterval(600), timeoutMinutes: 5)
        #expect(!session.isUnlocked)
        #expect(session.lockCount == 2)
    }
}

// MARK: - Second review round (findings: reopen after lock, stale wraps, shared key ids, wrong key)

@MainActor
struct SecondReviewRoundTests {
    private func makeSession(provider: SoftwareKeyProvider = SoftwareKeyProvider()) throws -> NoteLockSession {
        NoteLockSession(vaultURL: try makeFolder().appendingPathComponent("vault.json"), provider: provider)
    }

    @Test func aPromptAnsweredAfterLockingDoesntReopen() async throws {
        let provider = SoftwareKeyProvider()
        let session = try makeSession(provider: provider)
        try session.createVault(recovery: .generate())
        session.lock()
        provider.whileAuthenticating = { session.lock() }  // Lock Now / screen lock while the prompt is up
        await #expect(throws: NoteLockError.cancelled) { try await session.unlock() }
        #expect(!session.isUnlocked)
        await #expect(throws: NoteLockError.cancelled) { _ = try await session.recoveryKey() }
        provider.whileAuthenticating = nil
        try await session.unlock()
        #expect(session.isUnlocked)
    }

    @Test func aCipherFromBeforeANewRecoveryKeyKeepsTheNewKey() async throws {
        let session = try makeSession()
        try session.createVault(recovery: .generate())
        let folder = try makeFolder()
        let before = EntryVersionStore(root: folder, cipher: session.cipher)  // e.g. a pending transcription
        try makeEntry(in: before)
        try before.lock(entryFilename: entry)
        let rotation = try await session.replaceRecoveryKey { EntryVersionStore(root: folder, cipher: session.cipher) }
        session.lock()

        try before.saveTranscript("late words", forAudio: "audio/v1.m4a", entryFilename: entry)
        try before.saveCurrentText("second draft\n\nlate words", for: entry)
        #expect(try recoveryOpens(rotation.recoveryKey, entry, in: before))
    }

    @Test func everyWrapOfAKeyIsTried() async throws {
        let recovery = RecoveryKey.generate()
        let session = try makeSession()
        try session.createVault(recovery: recovery)
        let folder = try makeFolder()
        let store = EntryVersionStore(root: folder, cipher: session.cipher)
        try makeEntry(in: store)
        try store.lock(entryFilename: entry)
        let oldCopy = try Data(contentsOf: store.lockedEntryFileURL(for: entry))
        try makeEntry(otherEntry, in: store)
        try store.lock(entryFilename: otherEntry)
        _ = try await session.replaceRecoveryKey { EntryVersionStore(root: folder, cipher: session.cipher) }
        // One note comes back from an older backup, still carrying the old wrap.
        try oldCopy.write(to: store.lockedEntryFileURL(for: entry))

        let wraps = EntryVersionStore(root: folder).recoveryWraps()
        #expect(wraps.count == 1 && wraps.values.first?.count == 2)
        let fresh = try makeSession()
        #expect(try await fresh.importKeys(with: recovery, from: wraps).added == 1)
    }

    @Test func cleanupRefusesANoteLockedWithAnotherKey() throws {
        let folder = try makeFolder()
        let macB = try makeSession()
        try macB.createVault(recovery: .generate())
        let storeB = EntryVersionStore(root: folder, cipher: macB.cipher)
        try makeEntry(in: storeB)
        try storeB.lock(entryFilename: entry)
        let orphan = storeB.entryDirectory(for: entry).appendingPathComponent("audio/v2.transcript.md")
        try "left behind".write(to: orphan, atomically: true, encoding: .utf8)

        let macA = try makeSession()
        try macA.createVault(recovery: .generate())
        let storeA = EntryVersionStore(root: folder, cipher: macA.cipher)
        let before = snapshot(folder)
        #expect(throws: NoteLockError.unknownKey) { try storeA.reconcileLeftoverPlainFiles(of: entry) }
        #expect(snapshot(folder) == before)
        #expect(throws: NoteLockError.unknownKey) { try macA.cipher!.seal(Data("x".utf8), keyID: storeA.lockKeyID(of: entry)) }
    }
}
