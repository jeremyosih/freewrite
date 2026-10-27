//
//  Storage.swift
//  freewrite
//
//  Where entries live on disk: the sandbox container's Documents/Freewrite by default, or a
//  folder the user picked in Settings (kept as a security-scoped bookmark).
//

import AppKit
import Observation

/// The single source of truth for the entries folder. Every path the app reads or writes
/// (entries, `Videos/`, `Entries/`, thumbnails, transcripts) is derived from `rootURL`.
@MainActor
@Observable
final class EntryStorage {
    static let shared = EntryStorage()

    /// Folder holding the `.md` entries. Changes when the user switches folders.
    private(set) var rootURL: URL
    /// Set when a saved custom folder couldn't be opened at launch; cleared once shown.
    var unavailableFolderNotice: String?

    /// True while entries are being moved or copied to a new folder.
    private(set) var isTransferring = false

    /// The folder the security-scoped access was started on (custom folders only).
    @ObservationIgnored private var accessedURL: URL?

    var videosURL: URL { rootURL.appendingPathComponent(StorageTransfer.videosDirectoryName, isDirectory: true) }
    /// Carries the keys of open locked notes, so it can read and write them.
    var versionStore: EntryVersionStore { EntryVersionStore(root: rootURL, cipher: NoteLockSession.shared.cipher) }
    var isUsingDefault: Bool { accessedURL == nil }

    static let defaultRootURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Freewrite", isDirectory: true)

    private init() {
        rootURL = Self.defaultRootURL
        if let bookmark = UserDefaults.standard.data(forKey: SettingsKey.storageBookmark) {
            do {
                let url = try Self.resolveBookmark(bookmark)
                accessedURL = url
                rootURL = url
            } catch {
                print("Storage: falling back to default folder: \(error)")
                UserDefaults.standard.removeObject(forKey: SettingsKey.storageBookmark)
                let folder = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path.map { " “\($0)”" } ?? ""
                unavailableFolderNotice = "Freewrite couldn't open your entries folder\(folder), so it's using the default folder for now. If the folder moved or its drive is disconnected, choose it again in Settings › Storage."
            }
        }
        ensureDirectories()
    }

    /// Bookmark for `url`, or nil for the default folder. `url` must come from an open panel
    /// so the sandbox lets us bookmark it.
    private static func bookmark(for url: URL) throws -> Data? {
        guard !isSameFolder(url, defaultRootURL) else { return nil }
        return try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Starts using `url` as the entries folder, ending access to the previous custom folder.
    private func switchTo(_ url: URL, bookmark: Data?) {
        let previousAccess = accessedURL
        if let bookmark {
            UserDefaults.standard.set(bookmark, forKey: SettingsKey.storageBookmark)
            _ = url.startAccessingSecurityScopedResource()
            accessedURL = url
            rootURL = url
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.storageBookmark)
            accessedURL = nil
            rootURL = Self.defaultRootURL
        }
        previousAccess?.stopAccessingSecurityScopedResource()
        ensureDirectories()
    }

    func isCurrentFolder(_ url: URL) -> Bool {
        Self.isSameFolder(url, rootURL)
    }

    // MARK: Changing folders

    /// Asks for a folder, then switches to it (offering to move or copy the current entries).
    func chooseFolder() async {
        let panel = NSOpenPanel()
        panel.title = "Choose Entries Folder"
        panel.message = "Freewrite will keep your entries in this folder."
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = rootURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await changeFolder(to: url)
    }

    func useDefaultFolder() async {
        await changeFolder(to: Self.defaultRootURL)
    }

    private func changeFolder(to destination: URL) async {
        guard !isTransferring, !isCurrentFolder(destination) else { return }
        let source = rootURL
        // Bookmark first: if the folder can't be kept, fail before touching any files.
        let bookmark: Data?
        do {
            bookmark = try Self.bookmark(for: destination)
        } catch {
            showAlert("Couldn't use this folder", error.localizedDescription)
            return
        }

        var mode: StorageTransfer.Mode?
        if !StorageTransfer.items(in: source).isEmpty {
            let alert = NSAlert()
            alert.messageText = "Bring your entries to the new folder?"
            alert.informativeText = "Move or copy your entries from “\(source.path)” to “\(destination.path)”, or just switch if the new folder already has the entries you want. Files with the same name are never overwritten."
            alert.addButton(withTitle: "Move")
            alert.addButton(withTitle: "Copy")
            alert.addButton(withTitle: "Just Switch")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: mode = .move
            case .alertSecondButtonReturn: mode = .copy
            case .alertThirdButtonReturn: mode = nil
            default: return
            }
        }

        if let mode {
            guard !StorageTransfer.overlaps(source, destination) else {
                showAlert("Choose a different folder", "The new folder can't be inside Freewrite's Videos or Entries folder (or contain the current one there).")
                return
            }
            isTransferring = true
            defer { isTransferring = false }

            let firstPass = await Task.detached(priority: .userInitiated) {
                StorageTransfer.copy(from: source, to: destination)
            }.value
            // Final pass on the main actor, where entries are saved, so nothing written during
            // the first pass is missed before the originals are removed and the folder switches.
            var report = firstPass
            report.merge(StorageTransfer.copy(from: source, to: destination, alreadyCopied: Set(firstPass.copied)))
            // Anything removed from the old folder since the first pass shouldn't come back.
            report = StorageTransfer.dropVanished(from: report, source: source, destination: destination)

            guard report.succeeded else {
                let failures = report.failed.keys.sorted().prefix(5).joined(separator: "\n")
                showAlert("Some entries couldn't be copied", "Nothing was deleted and Freewrite is still using “\(source.path)”.\n\n\(failures)")
                return
            }
            if mode == .move {
                report = StorageTransfer.removeOriginals(of: report, in: source)
            }
            switchTo(destination, bookmark: bookmark)
            showSummary(of: report, mode: mode, source: source)
        } else {
            switchTo(destination, bookmark: bookmark)
        }
    }

    private func showSummary(of report: StorageTransfer.Report, mode: StorageTransfer.Mode, source: URL) {
        guard !report.skipped.isEmpty || !report.notRemoved.isEmpty else { return }
        var lines = ["\(mode == .move ? "Moved" : "Copied") \(report.copied.count) file(s)."]
        if !report.skipped.isEmpty {
            lines.append("Skipped \(report.skipped.count) because the new folder already has a file with the same name\(mode == .move ? " (the originals are still in “\(source.path)”)" : ""):")
            lines.append(contentsOf: report.skipped.prefix(5))
            if report.skipped.count > 5 { lines.append("…") }
        }
        if !report.notRemoved.isEmpty {
            lines.append("\(report.notRemoved.count) original(s) couldn't be removed from “\(source.path)”.")
        }
        showAlert("Entries folder changed", lines.joined(separator: "\n"))
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    nonisolated static func isSameFolder(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func ensureDirectories() {
        do {
            try FileManager.default.createDirectory(at: videosURL, withIntermediateDirectories: true)
        } catch {
            print("Storage: error creating \(videosURL.path): \(error)")
        }
    }

    /// Resolves a saved bookmark, refreshes it when stale and starts security-scoped access,
    /// which is kept for the app's lifetime (or until the user switches folders).
    private static func resolveBookmark(_ data: Data) throws -> URL {
        var isStale = false
        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
        guard url.startAccessingSecurityScopedResource() else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            url.stopAccessingSecurityScopedResource()
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        if isStale, let refreshed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(refreshed, forKey: SettingsKey.storageBookmark)
        }
        return url
    }
}

/// Copies or moves Freewrite's files (top-level `.md`/`.fwlock`/legacy `.mov` entries and the
/// managed subfolders) between two entry folders. Pure file-system logic so it can be tested.
enum StorageTransfer {
    enum Mode: Sendable {
        case copy
        case move
    }

    static let videosDirectoryName = "Videos"
    /// Subfolders owned by Freewrite that are transferred as a whole.
    static let managedDirectoryNames = [videosDirectoryName, EntryVersionStore.directoryName]
    /// Files the Finder recreates on its own; a folder holding only these counts as empty.
    private static let disposableFiles: Set<String> = [".DS_Store"]

    struct Report: Sendable, Equatable {
        /// Relative paths copied to the destination (or refreshed there).
        var copied: [String] = []
        /// Relative paths left alone because the destination already had a file with that name.
        var skipped: [String] = []
        /// Relative paths that failed, with the error message.
        var failed: [String: String] = [:]
        /// Originals that couldn't be deleted after a move (they are still in the old folder).
        var notRemoved: [String] = []

        var succeeded: Bool { failed.isEmpty }

        mutating func merge(_ other: Report) {
            copied += other.copied.filter { !copied.contains($0) }
            skipped += other.skipped.filter { !skipped.contains($0) }
            failed.merge(other.failed) { _, new in new }
            notRemoved += other.notRemoved
        }
    }

    /// Relative paths of every Freewrite file in `root`, sorted.
    /// `Entries/<entry>` for a path inside an entry's version folder, else nil.
    static func entryFolder(of item: String) -> String? {
        let parts = item.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == EntryVersionStore.directoryName else { return nil }
        return parts[0] + "/" + parts[1]
    }

    static func items(in root: URL) -> [String] {
        let fileManager = FileManager.default
        var result: [String] = []

        let topLevel = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        for url in topLevel where isEntryFilename(url.lastPathComponent) && isRegularFile(url) {
            result.append(url.lastPathComponent)
        }

        for name in managedDirectoryNames {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            let prefix = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            for case let url as URL in enumerator where isRegularFile(url) {
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                guard path.hasPrefix(prefix) else { continue }
                result.append(name + "/" + path.dropFirst(prefix.count))
            }
        }
        return result.sorted()
    }

    /// Copies every Freewrite file from `source` to `destination` without overwriting anything
    /// that was already there. Paths in `alreadyCopied` (copied by an earlier pass) are refreshed
    /// if the original changed since, so a second pass picks up writes made during the first.
    static func copy(from source: URL, to destination: URL, alreadyCopied: Set<String> = []) -> Report {
        let fileManager = FileManager.default
        var report = Report()
        let sourceItems = items(in: source)
        // An entry's version folder (`Entries/<entry>/`) moves as a unit: if the destination
        // already has that folder from elsewhere, none of it is copied, so its entry.json and
        // versions never mix with another copy's history.
        let ownedFolders = Set(alreadyCopied.compactMap(entryFolder(of:)))
        let blockedFolders = Set(sourceItems.compactMap(entryFolder(of:)).filter { folder in
            !ownedFolders.contains(folder) && fileManager.fileExists(atPath: destination.appendingPathComponent(folder).path)
        })
        for item in sourceItems {
            if let folder = entryFolder(of: item), blockedFolders.contains(folder) {
                report.skipped.append(item)
                continue
            }
            let sourceURL = source.appendingPathComponent(item)
            let destinationURL = destination.appendingPathComponent(item)
            let exists = fileManager.fileExists(atPath: destinationURL.path)

            if exists && !alreadyCopied.contains(item) {
                report.skipped.append(item)
                continue
            }
            if exists && isSameFile(sourceURL, destinationURL) {
                report.copied.append(item)
                continue
            }
            do {
                try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Copy under a hidden temporary name first so an interrupted copy never looks like an entry.
                let partialURL = destinationURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).partial")
                try fileManager.copyItem(at: sourceURL, to: partialURL)
                do {
                    if exists {
                        _ = try fileManager.replaceItemAt(destinationURL, withItemAt: partialURL)
                    } else {
                        try fileManager.moveItem(at: partialURL, to: destinationURL)
                    }
                } catch {
                    try? fileManager.removeItem(at: partialURL)
                    throw error
                }
                report.copied.append(item)
            } catch {
                report.failed[item] = error.localizedDescription
            }
        }
        return report
    }

    /// Deletes the originals of everything in `report.copied` — only when the whole copy
    /// succeeded — then prunes the empty managed folders left behind.
    static func removeOriginals(of report: Report, in source: URL) -> Report {
        var report = report
        guard report.succeeded else { return report }
        let fileManager = FileManager.default
        for item in report.copied {
            let url = source.appendingPathComponent(item)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                report.notRemoved.append(item)
            }
        }
        for name in managedDirectoryNames {
            removeEmptyDirectories(in: source.appendingPathComponent(name, isDirectory: true))
        }
        return report
    }

    /// Removes destination copies of files that disappeared from `source` after they were copied
    /// (e.g. an entry deleted during the transfer) and drops them from the report.
    static func dropVanished(from report: Report, source: URL, destination: URL) -> Report {
        var report = report
        let fileManager = FileManager.default
        report.copied.removeAll { item in
            guard !fileManager.fileExists(atPath: source.appendingPathComponent(item).path) else { return false }
            let copy = destination.appendingPathComponent(item)
            try? fileManager.removeItem(at: copy)
            // Prune the entry's video folder if that was its last file.
            let parent = copy.deletingLastPathComponent()
            if item.contains("/"), !managedDirectoryNames.contains(where: { EntryStorage.isSameFolder(parent, destination.appendingPathComponent($0)) }) {
                removeEmptyDirectories(in: parent)
            }
            return true
        }
        return report
    }

    /// Full transfer in one call (used by tests; the app runs `copy` off the main thread and
    /// the final pass + removal on it so no save can slip in between).
    static func transfer(from source: URL, to destination: URL, mode: Mode) -> Report {
        let report = copy(from: source, to: destination)
        return mode == .move ? removeOriginals(of: report, in: source) : report
    }

    /// Whether one folder sits inside the other's managed subfolders, where a transfer
    /// would copy its own output.
    static func overlaps(_ source: URL, _ destination: URL) -> Bool {
        func path(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path + "/" }
        for (outer, inner) in [(source, destination), (destination, source)] {
            for name in managedDirectoryNames where path(inner).hasPrefix(path(outer.appendingPathComponent(name))) {
                return true
            }
        }
        return false
    }

    static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let left = try? lhs.resourceValues(forKeys: keys),
              let right = try? rhs.resourceValues(forKeys: keys) else { return false }
        return left.fileSize == right.fileSize && left.contentModificationDate == right.contentModificationDate
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    /// Whether `filename` is a canonical entry file: `[UUID]-[yyyy-MM-dd-HH-mm-ss].md`, a locked
    /// entry with the same name and `.fwlock`, or a legacy top-level video with `.mov`.
    static func isEntryFilename(_ filename: String) -> Bool {
        ["md", LockedFileFormat.fileExtension, "mov"].contains { parseEntryFilename(filename, extension: $0) != nil }
    }

    /// UUID and timestamp of a canonical `[UUID]-[yyyy-MM-dd-HH-mm-ss].<extension>` filename
    /// (the check the entry loader uses), or nil for any other file.
    static func parseEntryFilename(_ filename: String, extension pathExtension: String = "md") -> (uuid: UUID, timestamp: Date)? {
        let suffix = "]." + pathExtension
        guard filename.hasPrefix("["),
              filename.hasSuffix(suffix),
              let divider = filename.range(of: "]-[") else {
            return nil
        }

        let uuidStart = filename.index(after: filename.startIndex)
        let uuidString = String(filename[uuidStart..<divider.lowerBound])
        guard let uuid = UUID(uuidString: uuidString) else {
            return nil
        }

        let timestampStart = divider.upperBound
        let timestampEnd = filename.index(filename.endIndex, offsetBy: -suffix.count) // before "].<extension>"
        guard timestampStart <= timestampEnd else { return nil }
        let timestampString = String(filename[timestampStart..<timestampEnd])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        guard let timestamp = formatter.date(from: timestampString) else {
            return nil
        }

        return (uuid: uuid, timestamp: timestamp)
    }

    /// Removes `directory` and its subfolders if they hold nothing but disposable files
    /// (`.DS_Store`). Any other file, hidden or not, keeps the folder.
    @discardableResult
    private static func removeEmptyDirectories(in directory: URL) -> Bool {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return false }
        var isEmpty = true
        for child in children {
            if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if !removeEmptyDirectories(in: child) { isEmpty = false }
            } else if !disposableFiles.contains(child.lastPathComponent) {
                isEmpty = false
            }
        }
        guard isEmpty else { return false }
        return (try? fileManager.removeItem(at: directory)) != nil
    }
}
