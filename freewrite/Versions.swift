//
//  Versions.swift
//  freewrite
//
//  Manual versions of an entry. The top-level `[UUID]-[date].md` always holds the current,
//  editable version; sealed versions and voice notes live next to a manifest in
//  `Entries/[UUID]-[date]/`, created the first time an entry needs it:
//
//      Entries/[UUID]-[date]/
//        entry.json              {"current":"v2","versions":[{"id":"v1",…},{"id":"v2",…}]}
//        versions/v1.md          sealed, read-only snapshots
//        audio/v1.m4a            voice note recorded for v1
//        audio/v1.transcript.md  raw transcript of that voice note
//
//  An entry without that folder has a single version, v1, which is the top-level file.
//  A locked entry (`NoteLock.swift`) keeps the same layout with every file but entry.json
//  encrypted as `<name>.fwlock`; reads and writes go through `cipher`.
//  Pure file-system logic over a root folder so it can be tested (and used by an agent that
//  reviews every version).
//

import Foundation

struct EntryVersion: Codable, Equatable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable {
        case typed
        case voiceNote = "voice-note"
    }

    /// "v1", "v2", …
    let id: String
    let n: Int
    let createdAt: Date
    var source: Source
    /// Voice note for this version, relative to the entry folder (e.g. "audio/v1.m4a").
    var audio: String?
    /// Earlier voice notes recorded for the same version, oldest first (rare; omitted when empty).
    var previousAudio: [String]?

    init(n: Int, createdAt: Date, source: Source = .typed, audio: String? = nil) {
        self.id = "v\(n)"
        self.n = n
        self.createdAt = createdAt
        self.source = source
        self.audio = audio
    }

    /// Every voice note of this version, oldest first.
    var allAudio: [String] { (previousAudio ?? []) + (audio.map { [$0] } ?? []) }
}

struct EntryManifest: Codable, Equatable, Sendable {
    /// Id of the version held by the top-level file.
    var current: String
    var versions: [EntryVersion]

    /// What an entry without an `Entries/` folder implicitly has: one typed version.
    static func single(createdAt: Date) -> EntryManifest {
        let first = EntryVersion(n: 1, createdAt: createdAt)
        return EntryManifest(current: first.id, versions: [first])
    }

    var currentVersion: EntryVersion? { versions.first(where: { $0.id == current }) }
    var sealedVersions: [EntryVersion] { versions.filter { $0.id != current } }
    var hasVoiceNote: Bool { versions.contains { $0.audio != nil } }

    func version(_ id: String) -> EntryVersion? { versions.first(where: { $0.id == id }) }

    /// Shown once there is something to switch between or play back.
    var isInteresting: Bool { versions.count > 1 || hasVoiceNote }
}

/// Where a voice note ended up after `attachVoiceNote`.
struct VoiceNoteAttachment: Equatable, Sendable {
    let versionId: String
    /// Relative to the entry folder.
    let audioPath: String
    let audioURL: URL
    let manifest: EntryManifest
    /// For a locked entry: the original recording, kept unencrypted (in the temporary folder)
    /// only for transcription. The caller deletes it afterwards.
    var temporaryPlaintextURL: URL? = nil
}

struct EntryVersionStore: Sendable {
    enum Failure: LocalizedError, Equatable {
        case emptyVersion
        case unknownVersion(String)
        case missingEntry(String)

        var errorDescription: String? {
            switch self {
            case .emptyVersion: return "Write something before starting a new version."
            case .unknownVersion(let id): return "This entry has no version \(id)."
            case .missingEntry(let filename): return "Couldn't find \(filename)."
            }
        }
    }

    static let directoryName = "Entries"
    static let manifestName = "entry.json"
    static let versionsDirectoryName = "versions"
    static let audioDirectoryName = "audio"

    /// The entries folder (`EntryStorage.shared.rootURL` in the app).
    let root: URL
    /// Keys for locked entries while they are open (`NoteLockSession`); nil = locked entries
    /// can't be read or written.
    var cipher: NoteCipher?
    /// Writes and deletes of locking, unlocking and recovery-key changes (tests inject failures).
    var lockFileOperations: any NoteLockFileOperations = StandardNoteLockFileOperations()

    init(root: URL, cipher: NoteCipher? = nil) {
        self.root = root
        self.cipher = cipher
    }

    // MARK: Paths

    var entriesURL: URL { root.appendingPathComponent(Self.directoryName, isDirectory: true) }

    /// The top-level file holding the current version.
    func entryFileURL(for entryFilename: String) -> URL {
        root.appendingPathComponent(entryFilename)
    }

    /// `Entries/[UUID]-[date]/` — may not exist yet. Reviews (e.g. `annotations.json`) belong here.
    func entryDirectory(for entryFilename: String) -> URL {
        entriesURL.appendingPathComponent((entryFilename as NSString).deletingPathExtension, isDirectory: true)
    }

    func manifestURL(for entryFilename: String) -> URL {
        entryDirectory(for: entryFilename).appendingPathComponent(Self.manifestName)
    }

    func sealedTextURL(for versionId: String, entryFilename: String) -> URL {
        entryDirectory(for: entryFilename)
            .appendingPathComponent(Self.versionsDirectoryName, isDirectory: true)
            .appendingPathComponent("\(versionId).md")
    }

    /// Absolute URL of a path stored in the manifest (e.g. a version's `audio`).
    func url(forRelativePath path: String, entryFilename: String) -> URL {
        entryDirectory(for: entryFilename).appendingPathComponent(path)
    }

    /// `[UUID]-[date].fwlock`: the top-level file of a locked entry.
    func lockedEntryFileURL(for entryFilename: String) -> URL {
        root.appendingPathComponent((entryFilename as NSString).deletingPathExtension + "." + LockedFileFormat.fileExtension)
    }

    /// `audio/v1.m4a` → `audio/v1.transcript.md`.
    static func transcriptPath(forAudio audioPath: String) -> String {
        (audioPath as NSString).deletingPathExtension + ".transcript.md"
    }

    // MARK: Reading

    /// The saved manifest, or nil when the entry has no `Entries/` folder (single version).
    /// Throws if a manifest exists but can't be read.
    func savedManifest(for entryFilename: String) throws -> EntryManifest? {
        let url = manifestURL(for: entryFilename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Self.decoder.decode(EntryManifest.self, from: Data(contentsOf: url))
    }

    /// The entry's versions; an entry without a (readable) manifest has just v1.
    func manifest(for entryFilename: String) -> EntryManifest {
        do {
            if let saved = try savedManifest(for: entryFilename) { return saved }
        } catch {
            print("Versions: unreadable manifest for \(entryFilename): \(error)")
        }
        return .single(createdAt: createdAt(ofEntry: entryFilename))
    }

    /// Every version, oldest first, with metadata.
    func versions(for entryFilename: String) -> [EntryVersion] {
        manifest(for: entryFilename).versions
    }

    /// The text of any version; the current one is read from the top-level file.
    func text(of versionId: String, for entryFilename: String) throws -> String {
        let manifest = manifest(for: entryFilename)
        guard manifest.version(versionId) != nil else { throw Failure.unknownVersion(versionId) }
        let url = versionId == manifest.current
            ? entryFileURL(for: entryFilename)
            : sealedTextURL(for: versionId, entryFilename: entryFilename)
        return try readText(url, entryFilename: entryFilename)
    }

    /// The current version's text (decrypted for a locked entry).
    func currentText(for entryFilename: String) throws -> String {
        try readText(entryFileURL(for: entryFilename), entryFilename: entryFilename)
    }

    /// Bytes of a file stored in the manifest (e.g. a voice note), decrypted for a locked entry.
    func data(atRelativePath path: String, entryFilename: String) throws -> Data {
        try readData(url(forRelativePath: path, entryFilename: entryFilename), entryFilename: entryFilename)
    }

    func fileExists(atRelativePath path: String, entryFilename: String) -> Bool {
        fileExists(url(forRelativePath: path, entryFilename: entryFilename), entryFilename: entryFilename)
    }

    /// Manifests of every entry that has an `Entries/` folder, keyed by entry filename.
    func savedManifests() -> [String: EntryManifest] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: entriesURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var result: [String: EntryManifest] = [:]
        for folder in folders {
            let filename = folder.lastPathComponent + ".md"
            if let manifest = try? savedManifest(for: filename) {
                result[filename] = manifest
            }
        }
        return result
    }

    // MARK: Writing

    func saveManifest(_ manifest: EntryManifest, for entryFilename: String) throws {
        let url = manifestURL(for: entryFilename)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(manifest).write(to: url, options: .atomic)
    }

    /// Seals the current version and starts the next one from an empty page:
    /// copies the top-level file to `versions/vN.md`, records vN+1 as current, then empties the
    /// top-level file. Each write is atomic and happens in that order, so an interruption can
    /// at worst leave the old text in the new version, never lose it.
    @discardableResult
    func sealCurrent(entryFilename: String, now: Date = Date()) throws -> EntryManifest {
        let entryURL = entryFileURL(for: entryFilename)
        guard fileExists(entryURL, entryFilename: entryFilename) else { throw Failure.missingEntry(entryFilename) }
        let text = try readText(entryURL, entryFilename: entryFilename)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.emptyVersion }

        // A corrupt manifest throws here rather than being replaced.
        var manifest = try savedManifest(for: entryFilename) ?? .single(createdAt: createdAt(ofEntry: entryFilename))
        let sealedId = manifest.current

        let sealedURL = sealedTextURL(for: sealedId, entryFilename: entryFilename)
        try FileManager.default.createDirectory(at: sealedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeText(text, to: sealedURL, entryFilename: entryFilename)

        let next = EntryVersion(n: (manifest.versions.map(\.n).max() ?? 0) + 1, createdAt: now)
        manifest.versions.append(next)
        manifest.current = next.id
        try saveManifest(manifest, for: entryFilename)

        try writeText("", to: entryURL, entryFilename: entryFilename)
        return manifest
    }

    /// Moves a recorded voice note into `audio/` as the current version's audio. A version whose
    /// text is still empty becomes a voice-note version; one that already had a voice note keeps
    /// the earlier file in `previousAudio`. A locked entry gets an encrypted copy and the
    /// recording stays where it is (`temporaryPlaintextURL`) for transcription.
    func attachVoiceNote(from audioURL: URL, to entryFilename: String, now: Date = Date()) throws -> VoiceNoteAttachment {
        var manifest = try savedManifest(for: entryFilename) ?? .single(createdAt: createdAt(ofEntry: entryFilename))
        guard let index = manifest.versions.firstIndex(where: { $0.id == manifest.current }) else {
            throw Failure.unknownVersion(manifest.current)
        }
        let versionId = manifest.current
        let ext = audioURL.pathExtension.isEmpty ? "m4a" : audioURL.pathExtension.lowercased()

        let fileManager = FileManager.default
        let audioDirectory = entryDirectory(for: entryFilename).appendingPathComponent(Self.audioDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        var name = "\(versionId).\(ext)"
        var counter = 2
        while fileExists(audioDirectory.appendingPathComponent(name), entryFilename: entryFilename) {
            name = "\(versionId)-\(counter).\(ext)"
            counter += 1
        }
        let destination = audioDirectory.appendingPathComponent(name)
        let locked = isLocked(entryFilename)
        if locked {
            try writeData(Data(contentsOf: audioURL), to: destination, entryFilename: entryFilename)
        } else {
            try fileManager.moveItem(at: audioURL, to: destination)
        }

        let path = Self.audioDirectoryName + "/" + name
        let currentText = (try? currentText(for: entryFilename)) ?? ""
        var version = manifest.versions[index]
        if let earlier = version.audio {
            version.previousAudio = (version.previousAudio ?? []) + [earlier]
        }
        version.audio = path
        if currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            version.source = .voiceNote
        }
        manifest.versions[index] = version
        do {
            try saveManifest(manifest, for: entryFilename)
        } catch {
            // Don't leave an untracked recording behind: put it back where it came from.
            if locked {
                try? fileManager.removeItem(at: lockedURL(for: destination, entryFilename: entryFilename))
            } else {
                try? fileManager.moveItem(at: destination, to: audioURL)
            }
            throw error
        }
        return VoiceNoteAttachment(versionId: versionId, audioPath: path, audioURL: destination, manifest: manifest,
                                   temporaryPlaintextURL: locked ? audioURL : nil)
    }

    /// Writes the raw transcript next to a voice note (`audio/v1.transcript.md`).
    func saveTranscript(_ transcript: String, forAudio audioPath: String, entryFilename: String) throws {
        let url = url(forRelativePath: Self.transcriptPath(forAudio: audioPath), entryFilename: entryFilename)
        try writeText(transcript, to: url, entryFilename: entryFilename)
    }

    /// Replaces the current version's text (encrypted for a locked entry).
    func saveCurrentText(_ text: String, for entryFilename: String) throws {
        try writeText(text, to: entryFileURL(for: entryFilename), entryFilename: entryFilename)
    }

    // MARK: Locked entries

    /// Whether the entry is locked (its top-level file is `.fwlock`). Every other file of a
    /// locked entry is stored as `<name>.fwlock`, except `entry.json`.
    func isLocked(_ entryFilename: String) -> Bool {
        FileManager.default.fileExists(atPath: lockedEntryFileURL(for: entryFilename).path)
    }

    /// Where the plain path `url` of an entry's file is stored once the entry is locked.
    func lockedURL(for url: URL, entryFilename: String) -> URL {
        url.path == entryFileURL(for: entryFilename).path
            ? lockedEntryFileURL(for: entryFilename)
            : url.appendingPathExtension(LockedFileFormat.fileExtension)
    }

    func readData(_ url: URL, entryFilename: String) throws -> Data {
        guard isLocked(entryFilename) else { return try Data(contentsOf: url) }
        guard let cipher else { throw NoteLockError.locked }
        return try cipher.open(Data(contentsOf: lockedURL(for: url, entryFilename: entryFilename)))
    }

    /// Writes atomically; a locked entry's file is encrypted with the key the entry was locked with.
    func writeData(_ data: Data, to url: URL, entryFilename: String) throws {
        guard isLocked(entryFilename) else {
            try data.write(to: url, options: .atomic)
            return
        }
        guard let cipher else { throw NoteLockError.locked }
        let keyID = try LockedFileFormat.header(ofFileAt: lockedEntryFileURL(for: entryFilename)).keyID
        try cipher.seal(data, keyID: keyID).write(to: lockedURL(for: url, entryFilename: entryFilename), options: .atomic)
    }

    func fileExists(_ url: URL, entryFilename: String) -> Bool {
        let stored = isLocked(entryFilename) ? lockedURL(for: url, entryFilename: entryFilename) : url
        return FileManager.default.fileExists(atPath: stored.path)
    }

    private func readText(_ url: URL, entryFilename: String) throws -> String {
        let data = try readData(url, entryFilename: entryFilename)
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return text
    }

    private func writeText(_ text: String, to url: URL, entryFilename: String) throws {
        try writeData(Data(text.utf8), to: url, entryFilename: entryFilename)
    }

    /// Removes every sealed version, voice note and review of an entry.
    func deleteEntryDirectory(for entryFilename: String) throws {
        let directory = entryDirectory(for: entryFilename)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: Helpers

    /// The timestamp in a `[UUID]-[yyyy-MM-dd-HH-mm-ss].md` filename, else the file's creation date.
    func createdAt(ofEntry entryFilename: String) -> Date {
        if let date = Self.timestamp(inEntryFilename: entryFilename) { return date }
        let values = try? entryFileURL(for: entryFilename).resourceValues(forKeys: [.creationDateKey])
        return values?.creationDate ?? Date(timeIntervalSince1970: 0)
    }

    static func timestamp(inEntryFilename filename: String) -> Date? {
        guard filename.hasSuffix("].md"), let divider = filename.range(of: "]-[") else { return nil }
        let start = divider.upperBound
        let end = filename.index(filename.endIndex, offsetBy: -4)
        guard start <= end else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter.date(from: String(filename[start..<end]))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
