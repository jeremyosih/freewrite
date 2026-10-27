//
//  NoteLock.swift
//  freewrite
//
//  Locked notes: encrypted at rest, opened with Touch ID, an Apple Watch or the Mac password.
//
//  Keys
//    • A random 256-bit content key encrypts every file of every note locked with it.
//    • The content keys live in a keyring sealed to a Secure Enclave P-256 key created with
//      `.privateKeyUsage + .userPresence` (ephemeral ECDH → HKDF → AES-GCM). Sealing needs no
//      prompt; opening needs the Secure Enclave, i.e. the user. The sealed keyring and the
//      key's opaque blob are in `Application Support/Freewrite/vault.json` (this Mac only).
//    • Each content key is also wrapped with a recovery key (160 random bits shown once as
//      words of base32). That wrap is copied into every locked file, so a locked note plus the
//      recovery key is all another Mac needs.
//
//  File format (`[UUID]-[date].fwlock`, and `<name>.fwlock` inside `Entries/<base>/`):
//    "FWLK" | version (1) | algorithm (1 = AES-GCM-256) | key id (16) | recovery wrap (76)
//    | salt (32) | nonce (12) | ciphertext | tag (16)
//  The file key is HKDF-SHA256(content key, salt); the whole header is authenticated.
//

import Foundation
import CryptoKit
import LocalAuthentication
import AppKit
import Observation

enum NoteLockError: LocalizedError, Equatable {
    case notALockedFile
    case unsupportedVersion(Int)
    case damaged
    case unknownKey
    case locked
    case noVault
    case invalidRecoveryKey
    case wrongRecoveryKey
    case unavailable
    case verificationFailed
    case alreadyLocked
    case notLocked
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notALockedFile: return "This file isn't a locked note."
        case .unsupportedVersion(let version): return "This note was locked by a newer version of Freewrite (format \(version))."
        case .damaged: return "This locked note is damaged and can't be decrypted."
        case .unknownKey: return "This note was locked on another Mac. Unlock it with your recovery key in Settings › Privacy."
        case .locked: return "Your locked notes are closed. Unlock them first."
        case .noVault: return "No note has been locked on this Mac yet."
        case .invalidRecoveryKey: return "That doesn't look like a recovery key. It has 32 letters and digits, like ABCD-EFGH-…"
        case .wrongRecoveryKey: return "This recovery key doesn't open any locked note in this folder."
        case .unavailable: return "Locking notes needs a Mac with a Secure Enclave (Apple silicon or a T2 chip)."
        case .verificationFailed: return "The encrypted copy couldn't be verified, so nothing was changed."
        case .alreadyLocked: return "This note is already locked."
        case .notLocked: return "This note isn't locked."
        case .cancelled: return "Cancelled."
        }
    }
}

// MARK: - Keys

/// A content key and its recovery wrap (which every file locked with it carries).
struct NoteKey: Sendable {
    /// 16 random bytes, stored in each file's header.
    let id: Data
    let key: SymmetricKey
    var recoveryWrap: Data
}

/// 160 random bits, shown as 8 groups of 4 Crockford base32 characters.
struct RecoveryKey: Equatable, Sendable {
    static let byteCount = 20
    /// salt (16) + nonce (12) + wrapped key (32) + tag (16).
    static let wrapLength = 76
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let info = Data("freewrite.recovery.v1".utf8)

    let secret: Data

    init(secret: Data) {
        self.secret = secret
    }

    static func generate() -> RecoveryKey {
        RecoveryKey(secret: SymmetricKey(size: .init(bitCount: byteCount * 8)).withUnsafeBytes { Data($0) })
    }

    /// Accepts any case, spaces or dashes, and the usual look-alikes (O → 0, I/L → 1).
    init?(string: String) {
        var bits: UInt32 = 0
        var bitCount = 0
        var bytes = Data()
        for character in string.uppercased() {
            if character == "-" || character.isWhitespace { continue }
            let normalized: Character
            switch character {
            case "O": normalized = "0"
            case "I", "L": normalized = "1"
            default: normalized = character
            }
            guard let value = Self.alphabet.firstIndex(of: normalized) else { return nil }
            bits = (bits << 5) | UInt32(value)
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                bytes.append(UInt8((bits >> UInt32(bitCount)) & 0xFF))
            }
        }
        guard bytes.count == Self.byteCount, bitCount == 0 else { return nil }
        self.secret = bytes
    }

    var displayString: String {
        var characters: [Character] = []
        var bits: UInt32 = 0
        var bitCount = 0
        for byte in secret {
            bits = (bits << 8) | UInt32(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                characters.append(Self.alphabet[Int((bits >> UInt32(bitCount)) & 0x1F)])
            }
        }
        return stride(from: 0, to: characters.count, by: 4)
            .map { String(characters[$0..<min($0 + 4, characters.count)]) }
            .joined(separator: "-")
    }

    private func keyEncryptionKey(salt: Data) -> SymmetricKey {
        // The secret is random and high-entropy, so HKDF is enough (no password stretching).
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt, info: Self.info, outputByteCount: 32)
    }

    func wrap(_ key: SymmetricKey, keyID: Data) throws -> Data {
        let salt = randomBytes(16)
        let sealed = try AES.GCM.seal(key.withUnsafeBytes { Data($0) }, using: keyEncryptionKey(salt: salt), authenticating: keyID)
        guard let combined = sealed.combined else { throw NoteLockError.damaged }
        return salt + combined
    }

    func unwrap(_ wrap: Data, keyID: Data) throws -> SymmetricKey {
        let wrap = Data(wrap)
        guard wrap.count == Self.wrapLength else { throw NoteLockError.damaged }
        do {
            let box = try AES.GCM.SealedBox(combined: wrap.subdata(in: 16..<wrap.count))
            let raw = try AES.GCM.open(box, using: keyEncryptionKey(salt: wrap.subdata(in: 0..<16)), authenticating: keyID)
            return SymmetricKey(data: raw)
        } catch {
            throw NoteLockError.wrongRecoveryKey
        }
    }
}

func randomBytes(_ count: Int) -> Data {
    SymmetricKey(size: .init(bitCount: count * 8)).withUnsafeBytes { Data($0) }
}

// MARK: - File format

enum LockedFileFormat {
    static let fileExtension = "fwlock"
    static let magic = Data("FWLK".utf8)
    static let version: UInt8 = 1
    static let algorithmAESGCM256: UInt8 = 1
    static let keyIDLength = 16
    static let saltLength = 32
    static let nonceLength = 12
    static let tagLength = 16
    static let headerLength = 4 + 1 + 1 + keyIDLength + RecoveryKey.wrapLength + saltLength + nonceLength
    private static let fileKeyInfo = Data("freewrite.fwlock.v1".utf8)

    struct Header: Equatable {
        let keyID: Data
        let recoveryWrap: Data
        let salt: Data
        let nonce: Data
        let bytes: Data
    }

    static func seal(_ plaintext: Data, with key: NoteKey) throws -> Data {
        guard key.id.count == keyIDLength, key.recoveryWrap.count == RecoveryKey.wrapLength else { throw NoteLockError.damaged }
        let salt = randomBytes(saltLength)
        let nonce = AES.GCM.Nonce()
        var header = magic
        header.append(version)
        header.append(algorithmAESGCM256)
        header.append(key.id)
        header.append(key.recoveryWrap)
        header.append(salt)
        header.append(contentsOf: nonce)
        let sealed = try AES.GCM.seal(plaintext, using: fileKey(key.key, salt: salt), nonce: nonce, authenticating: header)
        return header + sealed.ciphertext + sealed.tag
    }

    static func header(of file: Data) throws -> Header {
        let file = Data(file)
        guard file.count >= 6, file.prefix(4) == magic else { throw NoteLockError.notALockedFile }
        guard file[4] == version else { throw NoteLockError.unsupportedVersion(Int(file[4])) }
        guard file[5] == algorithmAESGCM256, file.count >= headerLength + tagLength else { throw NoteLockError.damaged }
        var offset = 6
        func take(_ count: Int) -> Data {
            defer { offset += count }
            return file.subdata(in: offset..<offset + count)
        }
        return Header(
            keyID: take(keyIDLength),
            recoveryWrap: take(RecoveryKey.wrapLength),
            salt: take(saltLength),
            nonce: take(nonceLength),
            bytes: file.subdata(in: 0..<headerLength)
        )
    }

    /// Reads only the header of a file on disk.
    static func header(ofFileAt url: URL) throws -> Header {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = try handle.read(upToCount: headerLength) ?? Data()
        // `header(of:)` also checks there's room for a tag; it isn't needed to read the header.
        data.append(Data(count: tagLength))
        return try header(of: data)
    }

    static func open(_ file: Data, key lookup: (Data) -> SymmetricKey?) throws -> Data {
        let file = Data(file)
        let header = try header(of: file)
        guard let key = lookup(header.keyID) else { throw NoteLockError.unknownKey }
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: header.nonce),
                ciphertext: file.subdata(in: headerLength..<file.count - tagLength),
                tag: file.subdata(in: file.count - tagLength..<file.count)
            )
            return try AES.GCM.open(box, using: fileKey(key, salt: header.salt), authenticating: header.bytes)
        } catch {
            throw NoteLockError.damaged
        }
    }

    private static func fileKey(_ key: SymmetricKey, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: fileKeyInfo, outputByteCount: 32)
    }
}

/// The content keys available while locked notes are open.
struct NoteCipher: Sendable {
    let primaryID: Data
    let keys: [Data: NoteKey]

    var primary: NoteKey? { keys[primaryID] }

    /// Seals with `keyID` (the key a note was locked with) or, if unknown, the primary key.
    func seal(_ plaintext: Data, keyID: Data? = nil) throws -> Data {
        guard let key = keyID.flatMap({ keys[$0] }) ?? primary else { throw NoteLockError.unknownKey }
        return try LockedFileFormat.seal(plaintext, with: key)
    }

    func open(_ file: Data) throws -> Data {
        try LockedFileFormat.open(file) { keys[$0]?.key }
    }
}

// MARK: - Keyring and vault file

/// Every content key this Mac can open, with the recovery key that goes with it. Only ever
/// stored sealed to the device key.
struct NoteKeyring: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var id: Data
        var key: Data
        var recoverySecret: Data
        var recoveryWrap: Data
    }

    /// The key new locks use.
    var primaryID: Data
    var entries: [Entry]

    /// A new keyring with one fresh content key wrapped by `recovery`.
    static func new(recovery: RecoveryKey) throws -> NoteKeyring {
        let id = randomBytes(LockedFileFormat.keyIDLength)
        let key = SymmetricKey(size: .bits256)
        let entry = Entry(id: id, key: key.withUnsafeBytes { Data($0) }, recoverySecret: recovery.secret, recoveryWrap: try recovery.wrap(key, keyID: id))
        return NoteKeyring(primaryID: id, entries: [entry])
    }

    var cipher: NoteCipher {
        var keys: [Data: NoteKey] = [:]
        for entry in entries {
            keys[entry.id] = NoteKey(id: entry.id, key: SymmetricKey(data: entry.key), recoveryWrap: entry.recoveryWrap)
        }
        return NoteCipher(primaryID: primaryID, keys: keys)
    }

    var primaryRecoveryKey: RecoveryKey? {
        entries.first(where: { $0.id == primaryID }).map { RecoveryKey(secret: $0.recoverySecret) }
    }

    /// Gives the primary key a new recovery key. Files keep opening with the old one until
    /// they are rewritten (`EntryVersionStore.resealLockedFiles`).
    mutating func replacePrimaryRecoveryKey(with recovery: RecoveryKey) throws {
        guard let index = entries.firstIndex(where: { $0.id == primaryID }) else { throw NoteLockError.noVault }
        entries[index].recoverySecret = recovery.secret
        entries[index].recoveryWrap = try recovery.wrap(SymmetricKey(data: entries[index].key), keyID: primaryID)
    }

    /// Adds a key recovered on this Mac; it becomes primary if the keyring had none.
    mutating func add(id: Data, key: SymmetricKey, recovery: RecoveryKey, recoveryWrap: Data) {
        guard !entries.contains(where: { $0.id == id }) else { return }
        entries.append(Entry(id: id, key: key.withUnsafeBytes { Data($0) }, recoverySecret: recovery.secret, recoveryWrap: recoveryWrap))
        if entries.count == 1 { primaryID = id }
    }
}

/// A P-256 key-agreement key: the Secure Enclave key in the app, a software key in tests.
protocol NoteDeviceKey {
    var publicKey: P256.KeyAgreement.PublicKey { get }
    func sharedSecretFromKeyAgreement(with publicKeyShare: P256.KeyAgreement.PublicKey) throws -> SharedSecret
}

extension P256.KeyAgreement.PrivateKey: NoteDeviceKey {}
extension SecureEnclave.P256.KeyAgreement.PrivateKey: NoteDeviceKey {}

/// `Application Support/Freewrite/vault.json`.
struct NoteVaultFile: Codable, Equatable, Sendable {
    var format = 1
    /// Opaque handle to the device key (the Secure Enclave key's `dataRepresentation`); it can
    /// only be used on this Mac.
    var deviceKey: Data
    var devicePublicKey: Data
    var ephemeralPublicKey: Data
    /// The keyring, AES-GCM sealed with HKDF(ECDH(ephemeral, device key)).
    var sealedKeyring: Data
    /// Ids of the keys in the keyring, readable without unlocking.
    var keyIDs: [Data]
    var primaryKeyID: Data

    private static let info = Data("freewrite.keyring.v1".utf8)

    static func seal(_ keyring: NoteKeyring, deviceKeyData: Data, devicePublicKey: P256.KeyAgreement.PublicKey) throws -> NoteVaultFile {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: devicePublicKey)
        let key = keyEncryptionKey(shared, ephemeral: ephemeral.publicKey, device: devicePublicKey)
        guard let sealed = try AES.GCM.seal(try JSONEncoder().encode(keyring), using: key).combined else { throw NoteLockError.damaged }
        return NoteVaultFile(
            deviceKey: deviceKeyData,
            devicePublicKey: devicePublicKey.x963Representation,
            ephemeralPublicKey: ephemeral.publicKey.x963Representation,
            sealedKeyring: sealed,
            keyIDs: keyring.entries.map(\.id),
            primaryKeyID: keyring.primaryID
        )
    }

    /// Needs the device key, i.e. user presence for the Secure Enclave key.
    func open(with deviceKey: some NoteDeviceKey) throws -> NoteKeyring {
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: ephemeralPublicKey)
        let device = try P256.KeyAgreement.PublicKey(x963Representation: devicePublicKey)
        let shared = try deviceKey.sharedSecretFromKeyAgreement(with: ephemeral)
        let key = Self.keyEncryptionKey(shared, ephemeral: ephemeral, device: device)
        let json: Data
        do {
            json = try AES.GCM.open(AES.GCM.SealedBox(combined: sealedKeyring), using: key)
        } catch {
            throw NoteLockError.damaged
        }
        return try JSONDecoder().decode(NoteKeyring.self, from: json)
    }

    private static func keyEncryptionKey(_ shared: SharedSecret, ephemeral: P256.KeyAgreement.PublicKey, device: P256.KeyAgreement.PublicKey) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral.x963Representation + device.x963Representation, sharedInfo: info, outputByteCount: 32)
    }

    static func load(from url: URL) throws -> NoteVaultFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(NoteVaultFile.self, from: Data(contentsOf: url))
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

// MARK: - Device key providers

/// Creates the device key and asks for the user before it can be used.
@MainActor
protocol NoteDeviceKeyProvider: AnyObject {
    var isAvailable: Bool { get }
    /// "Touch ID" when the Mac has it, else "your password".
    var methodName: String { get }
    /// A new device key: its persistent data and public key.
    func makeKey() throws -> (data: Data, publicKey: P256.KeyAgreement.PublicKey)
    /// Asks for Touch ID, an Apple Watch or the Mac password. Throws `.cancelled` if declined.
    func authenticate(reason: String) async throws
    /// The device key, usable without another prompt after `authenticate`.
    func key(from data: Data) throws -> any NoteDeviceKey
    /// Forgets the authentication (the next `key(from:)` needs `authenticate` again).
    func invalidate()
}

@MainActor
final class SecureEnclaveKeyProvider: NoteDeviceKeyProvider {
    private var context: LAContext?

    var isAvailable: Bool { SecureEnclave.isAvailable }

    var methodName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .touchID ? "Touch ID" : "your password"
    }

    func makeKey() throws -> (data: Data, publicKey: P256.KeyAgreement.PublicKey) {
        guard isAvailable else { throw NoteLockError.unavailable }
        var error: Unmanaged<CFError>?
        // `.userPresence` (not `.biometryCurrentSet`): adding a fingerprint must never destroy the key.
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], &error) else {
            throw error?.takeRetainedValue() ?? NoteLockError.unavailable
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        return (key.dataRepresentation, key.publicKey)
    }

    func authenticate(reason: String) async throws {
        let context = LAContext()
        // A Touch ID unlock of the Mac a few seconds ago counts; anything older asks again.
        context.touchIDAuthenticationAllowableReuseDuration = 10
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                    if success {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: error ?? NoteLockError.cancelled)
                    }
                }
            }
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel, .userFallback].contains(error.code) {
            throw NoteLockError.cancelled
        }
        self.context = context
    }

    func key(from data: Data) throws -> any NoteDeviceKey {
        guard let context else { throw NoteLockError.locked }
        return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data, authenticationContext: context)
    }

    func invalidate() {
        context?.invalidate()
        context = nil
    }
}

/// A software device key with no prompt, for tests (never used by the app itself).
@MainActor
final class SoftwareKeyProvider: NoteDeviceKeyProvider {
    var isAvailable: Bool { true }
    var methodName: String { "a test key" }
    var allowsAuthentication = true
    private(set) var authenticationCount = 0
    private var isAuthenticated = false

    func makeKey() throws -> (data: Data, publicKey: P256.KeyAgreement.PublicKey) {
        let key = P256.KeyAgreement.PrivateKey()
        return (key.rawRepresentation, key.publicKey)
    }

    func authenticate(reason: String) async throws {
        guard allowsAuthentication else { throw NoteLockError.cancelled }
        authenticationCount += 1
        isAuthenticated = true
    }

    func key(from data: Data) throws -> any NoteDeviceKey {
        guard isAuthenticated else { throw NoteLockError.locked }
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    func invalidate() {
        isAuthenticated = false
    }
}

// MARK: - Session

extension SettingsKey {
    /// Minutes without using Freewrite before locked notes close again; 0 = only when the Mac sleeps.
    static let noteLockTimeout = "noteLockTimeoutMinutes"
}

/// Whether locked notes are open right now. Opening asks once; the keys then stay in memory
/// until Freewrite has been idle for the chosen time, the Mac sleeps or locks its screen, or the
/// user closes them.
@MainActor
@Observable
final class NoteLockSession {
    static let shared = NoteLockSession(
        vaultURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Freewrite", isDirectory: true)
            .appendingPathComponent("vault.json"),
        provider: SecureEnclaveKeyProvider(),
        monitorsActivity: true
    )

    static let defaultTimeoutMinutes = 5
    static let timeoutChoices = [1, 5, 15, 0]

    /// Keys of the open session; nil while locked notes are closed.
    private(set) var cipher: NoteCipher?
    private(set) var vault: NoteVaultFile?
    /// Set when vault.json exists but can't be read (it is never overwritten then).
    private(set) var vaultError: String?

    var isUnlocked: Bool { cipher != nil }
    var hasVault: Bool { vault != nil }
    var isAvailable: Bool { provider.isAvailable }
    var methodName: String { provider.methodName }

    let vaultURL: URL
    @ObservationIgnored private let provider: any NoteDeviceKeyProvider
    @ObservationIgnored private var keyring: NoteKeyring?
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var observers: [Any] = []
    @ObservationIgnored private var idleTimer: Timer?

    init(vaultURL: URL, provider: any NoteDeviceKeyProvider, monitorsActivity: Bool = false) {
        self.vaultURL = vaultURL
        self.provider = provider
        reloadVault()
        if monitorsActivity {
            startMonitoring()
        }
    }

    func reloadVault() {
        do {
            vault = try NoteVaultFile.load(from: vaultURL)
            vaultError = nil
        } catch {
            vault = nil
            vaultError = "Freewrite couldn't read \(vaultURL.path): \(error.localizedDescription)"
        }
    }

    /// Whether this Mac has the key a file was locked with (false: it needs the recovery key).
    func hasKey(_ keyID: Data) -> Bool {
        vault?.keyIDs.contains(keyID) == true
    }

    /// First lock on this Mac: makes the device key and a content key wrapped by `recovery`.
    /// Leaves the session open.
    func createVault(recovery: RecoveryKey) throws {
        guard vault == nil, vaultError == nil else { throw NoteLockError.alreadyLocked }
        let keyring = try NoteKeyring.new(recovery: recovery)
        try save(keyring, newDeviceKey: true)
        open(keyring)
    }

    /// Asks for the user and opens every locked note this Mac has a key for.
    func unlock(reason: String = "open your locked notes") async throws {
        guard !isUnlocked else { return }
        let keyring = try await authenticatedKeyring(reason: reason)
        open(keyring)
    }

    /// Closes locked notes: forgets the keys and the authentication.
    func lock() {
        guard cipher != nil || keyring != nil else { return }
        keyring = nil
        cipher = nil
        provider.invalidate()
    }

    /// Always asks, even while open.
    func recoveryKey(reason: String = "show your recovery key") async throws -> RecoveryKey {
        let keyring = try await authenticatedKeyring(reason: reason)
        open(keyring)
        guard let recovery = keyring.primaryRecoveryKey else { throw NoteLockError.noVault }
        return recovery
    }

    /// Replaces the recovery key of the primary content key. Returns the new key; locked files
    /// still need resealing with the new `cipher` so their headers carry the new wrap.
    func replaceRecoveryKey(reason: String = "create a new recovery key") async throws -> RecoveryKey {
        var keyring = try await authenticatedKeyring(reason: reason)
        let recovery = RecoveryKey.generate()
        try keyring.replacePrimaryRecoveryKey(with: recovery)
        try save(keyring, newDeviceKey: false)
        open(keyring)
        return recovery
    }

    /// Adds every content key that `recovery` unwraps from `wraps` (key id → recovery wrap, read
    /// from locked files' headers). Returns how many keys were added.
    func importKeys(with recovery: RecoveryKey, from wraps: [Data: Data]) async throws -> Int {
        var recovered: [(id: Data, key: SymmetricKey, wrap: Data)] = []
        for (id, wrap) in wraps.sorted(by: { $0.key.base64EncodedString() < $1.key.base64EncodedString() }) where !hasKey(id) {
            if let key = try? recovery.unwrap(wrap, keyID: id) {
                recovered.append((id, key, wrap))
            }
        }
        guard !recovered.isEmpty else {
            if wraps.keys.contains(where: { !hasKey($0) }) { throw NoteLockError.wrongRecoveryKey }
            return 0
        }
        var keyring: NoteKeyring
        let isNew = vault == nil
        if isNew {
            guard vaultError == nil else { throw NoteLockError.damaged }
            keyring = NoteKeyring(primaryID: Data(), entries: [])
        } else {
            keyring = try await authenticatedKeyring(reason: "add your recovery key")
        }
        for item in recovered {
            keyring.add(id: item.id, key: item.key, recovery: recovery, recoveryWrap: item.wrap)
        }
        try save(keyring, newDeviceKey: isNew)
        open(keyring)
        return recovered.count
    }

    // MARK: Idle and sleep

    var timeoutMinutes: Int {
        UserDefaults.standard.object(forKey: SettingsKey.noteLockTimeout) as? Int ?? Self.defaultTimeoutMinutes
    }

    func noteActivity(at date: Date = Date()) {
        lastActivity = date
    }

    /// Closes the session once Freewrite has been idle longer than the timeout.
    func lockIfIdle(now: Date = Date(), timeoutMinutes: Int? = nil) {
        let minutes = timeoutMinutes ?? self.timeoutMinutes
        guard isUnlocked, minutes > 0, now.timeIntervalSince(lastActivity) >= Double(minutes) * 60 else { return }
        lock()
    }

    private func startMonitoring() {
        // Activity in Freewrite only: time spent in other apps counts as idle.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { event in
            MainActor.assumeIsolated { NoteLockSession.shared.noteActivity() }
            return event
        }
        if let monitor { observers.append(monitor) }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { NoteLockSession.shared.lockIfIdle() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { NoteLockSession.shared.lock() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NoteLockSession.shared.lock() }
        })
    }

    // MARK: Helpers

    private func open(_ keyring: NoteKeyring) {
        self.keyring = keyring
        cipher = keyring.cipher
        lastActivity = Date()
    }

    private func authenticatedKeyring(reason: String) async throws -> NoteKeyring {
        guard let vault else { throw vaultError == nil ? NoteLockError.noVault : NoteLockError.damaged }
        try await provider.authenticate(reason: reason)
        let deviceKey = try provider.key(from: vault.deviceKey)
        return try vault.open(with: deviceKey)
    }

    private func save(_ keyring: NoteKeyring, newDeviceKey: Bool) throws {
        let deviceKeyData: Data
        let publicKey: P256.KeyAgreement.PublicKey
        if newDeviceKey || vault == nil {
            (deviceKeyData, publicKey) = try provider.makeKey()
        } else if let vault {
            deviceKeyData = vault.deviceKey
            publicKey = try P256.KeyAgreement.PublicKey(x963Representation: vault.devicePublicKey)
        } else {
            throw NoteLockError.noVault
        }
        let file = try NoteVaultFile.seal(keyring, deviceKeyData: deviceKeyData, devicePublicKey: publicKey)
        try file.save(to: vaultURL)
        vault = file
    }
}

// MARK: - Locking an entry's files

extension EntryVersionStore {
    /// Logical (`.md`) names of every locked entry in the folder.
    func lockedEntryFilenames() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files
            .map(\.lastPathComponent)
            .filter { StorageTransfer.parseEntryFilename($0, extension: LockedFileFormat.fileExtension) != nil }
            .map { ($0 as NSString).deletingPathExtension + ".md" }
            .sorted()
    }

    /// Key id → recovery wrap of every locked entry in the folder (read from the headers).
    func recoveryWraps() -> [Data: Data] {
        var wraps: [Data: Data] = [:]
        for filename in lockedEntryFilenames() {
            if let header = try? LockedFileFormat.header(ofFileAt: lockedEntryFileURL(for: filename)) {
                wraps[header.keyID] = header.recoveryWrap
            }
        }
        return wraps
    }

    /// Key id of a locked entry.
    func lockKeyID(of entryFilename: String) -> Data? {
        try? LockedFileFormat.header(ofFileAt: lockedEntryFileURL(for: entryFilename)).keyID
    }

    /// The plain files locking encrypts: the top-level file and everything in `Entries/<base>/`
    /// except `entry.json` (version ids, dates and audio paths; no text).
    private func plainFiles(of entryFilename: String) -> [URL] {
        nestedFiles(of: entryFilename).filter { $0.pathExtension != LockedFileFormat.fileExtension && $0.lastPathComponent != Self.manifestName }
    }

    private func nestedLockedFiles(of entryFilename: String) -> [URL] {
        nestedFiles(of: entryFilename).filter { $0.pathExtension == LockedFileFormat.fileExtension }
    }

    private func nestedFiles(of entryFilename: String) -> [URL] {
        let directory = entryDirectory(for: entryFilename)
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            .sorted { $0.path < $1.path }
    }

    /// Encrypts every file of the entry, checks each encrypted copy on disk decrypts to the
    /// original, then deletes the plain files. Any failure before that removes the encrypted
    /// copies and leaves the entry as it was. Returns plain files that couldn't be deleted.
    @discardableResult
    func lock(entryFilename: String) throws -> [URL] {
        guard let cipher, let primary = cipher.primary else { throw NoteLockError.locked }
        guard !isLocked(entryFilename) else { throw NoteLockError.alreadyLocked }
        let top = entryFileURL(for: entryFilename)
        guard FileManager.default.fileExists(atPath: top.path) else { throw Failure.missingEntry(entryFilename) }
        // The top-level file last: the entry only counts as locked once everything else is.
        let sources = plainFiles(of: entryFilename) + [top]
        var written: [URL] = []
        do {
            for source in sources {
                let plain = try Data(contentsOf: source)
                let target = lockedURL(for: source, entryFilename: entryFilename)
                try cipher.seal(plain, keyID: primary.id).write(to: target, options: .atomic)
                written.append(target)
                guard try cipher.open(Data(contentsOf: target)) == plain else { throw NoteLockError.verificationFailed }
            }
        } catch {
            for url in written { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        var notRemoved: [URL] = []
        for source in sources {
            do {
                try FileManager.default.removeItem(at: source)
            } catch {
                notRemoved.append(source)
            }
        }
        return notRemoved
    }

    /// Turns a locked entry back into plain files (decrypted, written and checked first; the
    /// encrypted files are removed last, the top-level one first).
    func unlock(entryFilename: String) throws {
        guard let cipher else { throw NoteLockError.locked }
        guard isLocked(entryFilename) else { throw NoteLockError.notLocked }
        let sources = nestedLockedFiles(of: entryFilename) + [lockedEntryFileURL(for: entryFilename)]
        var written: [URL] = []
        do {
            for source in sources {
                let plain = try cipher.open(Data(contentsOf: source))
                let target = plainURL(forLocked: source, entryFilename: entryFilename)
                try plain.write(to: target, options: .atomic)
                written.append(target)
                guard try Data(contentsOf: target) == plain else { throw NoteLockError.verificationFailed }
            }
        } catch {
            for url in written { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        for source in sources.reversed() {
            try? FileManager.default.removeItem(at: source)
        }
    }

    /// Plain copies left next to a locked entry's files by an interrupted lock or unlock.
    /// Removed only when they match the decrypted content.
    func removeLeftoverPlainFiles(of entryFilename: String) {
        guard let cipher, isLocked(entryFilename) else { return }
        for locked in nestedLockedFiles(of: entryFilename) + [lockedEntryFileURL(for: entryFilename)] {
            let plainURL = plainURL(forLocked: locked, entryFilename: entryFilename)
            guard FileManager.default.fileExists(atPath: plainURL.path),
                  let plain = try? Data(contentsOf: plainURL),
                  let decrypted = try? cipher.open(Data(contentsOf: locked)),
                  plain == decrypted else { continue }
            try? FileManager.default.removeItem(at: plainURL)
        }
    }

    /// Rewrites every locked file of the folder sealed with the current cipher, so their
    /// headers carry the current recovery wrap. Returns how many files were rewritten.
    @discardableResult
    func resealLockedFiles() throws -> Int {
        guard let cipher else { throw NoteLockError.locked }
        var count = 0
        for filename in lockedEntryFilenames() {
            for url in nestedLockedFiles(of: filename) + [lockedEntryFileURL(for: filename)] {
                let data = try Data(contentsOf: url)
                let keyID = try LockedFileFormat.header(of: data).keyID
                guard cipher.keys[keyID] != nil else { continue }
                try cipher.seal(cipher.open(data), keyID: keyID).write(to: url, options: .atomic)
                count += 1
            }
        }
        return count
    }

    private func plainURL(forLocked url: URL, entryFilename: String) -> URL {
        url.path == lockedEntryFileURL(for: entryFilename).path ? entryFileURL(for: entryFilename) : url.deletingPathExtension()
    }
}
