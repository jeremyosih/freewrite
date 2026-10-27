//
//  ContentView.swift
//  freewrite
//
//  Created by thorfinn on 2/14/25.
//

import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import PDFKit

enum EntryType {
    case text
    case video
}

struct HumanEntry: Identifiable {
    let id: UUID
    let date: String
    let filename: String
    var previewText: String
    var entryType: EntryType
    var videoFilename: String?
    /// Number of versions (1 unless the entry has an `Entries/` manifest).
    var versionCount = 1
    var hasVoiceNote = false
    /// Encrypted on disk (`[UUID]-[date].fwlock`); `filename` stays the logical `.md` name.
    var isLocked = false
    /// A locked entry with a newer plain `.md` next to it (edits from an interrupted unlock),
    /// brought back into the note when it's opened.
    var hasNewerPlainCopy = false

    static func createNew() -> HumanEntry {
        let id = UUID()
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let dateString = dateFormatter.string(from: now)

        // For display
        dateFormatter.dateFormat = "MMM d"
        let displayDate = dateFormatter.string(from: now)

        return HumanEntry(
            id: id,
            date: displayDate,
            filename: "[\(id)]-[\(dateString)].md",
            previewText: "",
            entryType: .text,
            videoFilename: nil
        )
    }

    static func createVideoEntry() -> HumanEntry {
        let id = UUID()
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let dateString = dateFormatter.string(from: now)

        // For display
        dateFormatter.dateFormat = "MMM d"
        let displayDate = dateFormatter.string(from: now)

        let videoFilename = "[\(id)]-[\(dateString)].mov"

        return HumanEntry(
            id: id,
            date: displayDate,
            filename: "[\(id)]-[\(dateString)].md",
            previewText: "Video Entry",
            entryType: .video,
            videoFilename: videoFilename
        )
    }
}

/// First lock on this Mac: the note to lock once the recovery key is saved.
struct RecoverySetupRequest: Identifiable {
    let id = UUID()
    let entryId: UUID
    let recoveryKey: RecoveryKey
}

struct HeartEmoji: Identifiable {
    let id = UUID()
    var position: CGPoint
    var offset: CGFloat = 0
}

struct ContentView: View {
    private struct VideoPermissionPopoverItem: Identifiable {
        let id = UUID()
        let message: String
        let buttonLabel: String
        let settingsPane: String
    }

    @State private var entries: [HumanEntry] = []
    @State private var text: String = ""  // Remove initial welcome text since we'll handle it in createNewEntry
    
    @State private var isFullscreen = false
    @AppStorage(SettingsKey.fontName) private var selectedFont: String = WritingFont.defaultName
    @AppStorage(SettingsKey.fontSize) private var fontSizeSetting: Double = WritingFont.defaultSize
    @AppStorage(SettingsKey.colorScheme) private var colorSchemeSetting: String = "light"
    @AppStorage(SettingsKey.sessionMinutes) private var sessionMinutes: Int = 15
    @State private var keyDownMonitor: Any?
    @State private var scrollWheelMonitor: Any?
    @State private var timeRemaining: Int = 900  // Changed to 900 seconds (15 minutes)
    @State private var timerIsRunning = false
    @State private var isHoveringTimer = false
    @State private var isHoveringFullscreen = false
    @State private var blinkCount = 0
    @State private var isBlinking = false
    @State private var opacity: Double = 1.0
    @State private var shouldShowGray = true // New state to control color
    @State private var lastClickTime: Date? = nil
    @State private var bottomNavOpacity: Double = 1.0
    @State private var isHoveringBottomNav = false
    @State private var selectedEntryIndex: Int = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var selectedEntryId: UUID? = nil
    @State private var hoveredEntryId: UUID? = nil
    @State private var showingSidebar = false  // Add this state variable
    @State private var hoveredTrashId: UUID? = nil
    @State private var hoveredExportId: UUID? = nil
    @State private var placeholderText: String = ""  // Add this line
    @State private var isHoveringNewEntry = false
    @State private var isHoveringClock = false
    @State private var isHoveringHistory = false
    @State private var isHoveringHistoryText = false
    @State private var isHoveringHistoryPath = false
    @State private var isHoveringHistoryArrow = false
    @State private var isHoveringCopyTranscript = false
    @State private var isHoveringSettings = false
    @State private var didCopyTranscript: Bool = false
    @State private var selectedVideoHasTranscript = false
    /// Hex progress or failure per video entry; only the selected entry's is shown.
    @State private var transcriptionStatuses: [UUID: String] = [:]
    @State private var showingCommandPalette = false
    @State private var paletteIndex: PaletteIndex? = nil
    /// Identifies the palette opening a document read belongs to, so a slower read from an
    /// earlier opening can't replace newer results.
    @State private var paletteLoadID: UUID? = nil
    @AppStorage(SettingsKey.shortcuts) private var shortcutsJSON = "{}"
    @AppStorage(SettingsKey.bottomBarLayout) private var bottomBarLayoutJSON = ""
    @Environment(\.openSettings) private var openSettings
    @State private var backspaceDisabled = false // Add state for backspace toggle
    @State private var isHoveringBackspaceToggle = false // Add state for backspace toggle hover
    @State private var showingVideoRecording = false // Add state for video recording view
    @State private var isHoveringVideoButton = false // Add state for video button hover
    @State private var currentVideoURL: URL? = nil // Add state for current video being viewed
    @State private var isPreparingVideoRecording = false
    @State private var preparedCameraManager: CameraManager? = nil
    @State private var videoRecordingPreparationID: UUID? = nil
    @State private var videoPermissionPopoverItems: [VideoPermissionPopoverItem] = []
    @State private var videoPermissionPopoverFallbackMessage: String? = nil
    /// Saved manifest of the selected text entry; nil while it has a single version.
    @State private var entryManifest: EntryManifest? = nil
    /// A sealed version shown read-only in place of the current text (`text` is left alone).
    @State private var viewedVersion: EntryVersion? = nil
    @State private var viewedVersionText = ""
    @State private var isHoveringVersion = false
    @State private var isHoveringBackToCurrent = false
    @State private var isHoveringPlayVoiceNote = false
    @State private var voiceRecorder = VoiceNoteRecorder()
    @State private var voicePlayer = VoiceNotePlayer()
    @State private var isRequestingMicrophone = false
    @State private var isHoveringVoiceNoteButton = false
    @State private var isHoveringStopVoiceNote = false
    @State private var isHoveringDiscardVoiceNote = false
    // AI reviewers (Reviews.swift): notes on the selected entry, anchored to `annotationsBaseText`
    // for the current version.
    @ObservedObject private var reviews = ReviewService.shared
    @AppStorage(ReviewerStore.key) private var reviewersJSON = ""
    @State private var annotations: [Annotation] = []
    @State private var annotationsEntryId: UUID? = nil
    @State private var annotationsBaseText = ""
    @State private var annotationSaveTask: Task<Void, Never>? = nil
    /// Anchors moved by typing, not written yet (saved after a 1 s pause or by `flushAnnotationAnchors`).
    @State private var pendingAnchors: PendingAnchors? = nil
    /// The floating bar menu that's open (BarMenu.swift), its keyboard highlight and key monitor.
    @State private var openBarMenu: BarMenuKind? = nil
    @State private var barMenuHighlight: String? = nil
    @State private var barMenuKeyMonitor: Any?
    @State private var isHoveringOverflow = false
    /// Items in the "…" menu of the bar on screen.
    @State private var barOverflow: [BottomBarItem] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringReview = false
    /// Keys of locked notes while they are open (Touch ID / Apple Watch / password).
    private let noteLock = NoteLockSession.shared
    /// The locked note whose decrypted text is in `text`; nil while the selected locked note
    /// shows the "This note is locked" placeholder. Never save a locked note unless it's this.
    @State private var openLockedNoteId: UUID? = nil
    /// Last text written for the open locked note, so loading it doesn't rewrite the file.
    @State private var lockedNoteSavedText: String? = nil
    @State private var isUnlockingNotes = false
    @State private var isHoveringLock = false
    /// First lock on this Mac: the recovery key to save before the note is locked.
    @State private var recoverySetup: RecoverySetupRequest? = nil
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    let entryHeight: CGFloat = 40
    
    private var fontSize: CGFloat { CGFloat(fontSizeSetting) }
    private var colorScheme: ColorScheme { colorSchemeSetting == "dark" ? .dark : .light }
    let placeholderOptions = [
        "Begin writing",
        "Pick a thought and go",
        "Start typing",
        "What's on your mind",
        "Just start",
        "Type your first thought",
        "Start with one sentence",
        "Just say it"
    ]
    
    // Add file manager and save timer
    private let fileManager = FileManager.default
    private let saveTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    
    // Entries folder (default container folder or the one picked in Settings › Storage)
    private let storage = EntryStorage.shared

    private let thumbnailMemoryCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 512
        return cache
    }()
    
    
    private func getDocumentsDirectory() -> URL {
        storage.rootURL
    }

    private func getVideosDirectory() -> URL {
        storage.videosURL
    }

    /// Versions and voice notes; re-read after any `await` since the folder can change.
    private var versionStore: EntryVersionStore {
        storage.versionStore
    }

    private func getVideoEntryDirectory(for videoFilename: String) -> URL {
        let baseName = (videoFilename as NSString).deletingPathExtension
        return getVideosDirectory().appendingPathComponent(baseName, isDirectory: true)
    }

    private func getManagedVideoURL(for filename: String) -> URL {
        getVideoEntryDirectory(for: filename).appendingPathComponent(filename)
    }

    private func getVideoThumbnailURL(for filename: String) -> URL {
        getVideoEntryDirectory(for: filename).appendingPathComponent("thumbnail.jpg")
    }

    private func getVideoTranscriptURL(for filename: String) -> URL {
        getVideoEntryDirectory(for: filename).appendingPathComponent("transcript.md")
    }

    @discardableResult
    private func ensureVideoEntryDirectoryExists(for videoFilename: String) throws -> URL {
        let directory = getVideoEntryDirectory(for: videoFilename)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func getVideoURL(for filename: String) -> URL {
        // Current production layout: Videos/[entry-base]/[entry-filename].mov
        let managedVideoURL = getManagedVideoURL(for: filename)
        if fileManager.fileExists(atPath: managedVideoURL.path) {
            return managedVideoURL
        }

        // Backward compatibility: older builds stored videos flat under Videos/
        let flatVideosURL = getVideosDirectory().appendingPathComponent(filename)
        if fileManager.fileExists(atPath: flatVideosURL.path) {
            return flatVideosURL
        }

        // Backward compatibility: oldest builds stored videos in root Freewrite folder
        let rootVideosURL = getDocumentsDirectory().appendingPathComponent(filename)
        if fileManager.fileExists(atPath: rootVideosURL.path) {
            return rootVideosURL
        }

        // Default to managed path for newly created entries.
        return managedVideoURL
    }

    private func hasVideoAsset(for filename: String) -> Bool {
        let managedVideoURL = getManagedVideoURL(for: filename)
        if fileManager.fileExists(atPath: managedVideoURL.path) {
            return true
        }

        let flatVideosURL = getVideosDirectory().appendingPathComponent(filename)
        if fileManager.fileExists(atPath: flatVideosURL.path) {
            return true
        }

        let rootVideosURL = getDocumentsDirectory().appendingPathComponent(filename)
        return fileManager.fileExists(atPath: rootVideosURL.path)
    }

    private let historyDebugEnabled = true

    private func historyDebug(_ message: String) {
        guard historyDebugEnabled else { return }
        print("[HistoryDebug] \(message)")
    }

    private func debugEntrySummary(_ entry: HumanEntry) -> String {
        let shortID = String(entry.id.uuidString.prefix(8))
        let type = entry.entryType == .video ? "video" : "text"
        let videoFilename = resolvedVideoFilename(for: entry) ?? "-"
        return "id=\(shortID) type=\(type) file=\(entry.filename) video=\(videoFilename)"
    }

    private func logEntriesOrder(_ reason: String, limit: Int = 20) {
        guard historyDebugEnabled else { return }
        historyDebug("ORDER SNAPSHOT (\(reason)) total=\(entries.count) selected=\(selectedEntryId?.uuidString ?? "nil")")
        for (index, entry) in entries.prefix(limit).enumerated() {
            historyDebug("#\(index + 1) \(debugEntrySummary(entry))")
        }
    }

    private func resolvedVideoFilename(for entry: HumanEntry) -> String? {
        guard entry.entryType == .video else {
            return nil
        }
        if let videoFilename = entry.videoFilename, !videoFilename.isEmpty {
            return videoFilename
        }
        return entry.filename.replacingOccurrences(of: ".md", with: ".mov")
    }

    private func persistThumbnail(_ image: NSImage, for videoFilename: String) {
        do {
            let directory = try ensureVideoEntryDirectoryExists(for: videoFilename)
            let thumbnailURL = directory.appendingPathComponent("thumbnail.jpg")
            guard let tiff = image.tiffRepresentation,
                  let bitmapRep = NSBitmapImageRep(data: tiff),
                  let imageData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
                print("Could not convert thumbnail image to JPEG data")
                return
            }
            try imageData.write(to: thumbnailURL, options: .atomic)
        } catch {
            print("Error saving thumbnail: \(error)")
        }
    }

    private func loadThumbnailImage(for videoFilename: String) -> NSImage? {
        let cacheKey = videoFilename as NSString
        if let cachedImage = thumbnailMemoryCache.object(forKey: cacheKey) {
            return cachedImage
        }

        let thumbnailURL = getVideoThumbnailURL(for: videoFilename)
        if fileManager.fileExists(atPath: thumbnailURL.path),
           let image = NSImage(contentsOf: thumbnailURL) {
            thumbnailMemoryCache.setObject(image, forKey: cacheKey)
            return image
        }

        // Backward compatibility: generate once for old video entries, then persist.
        let videoURL = getVideoURL(for: videoFilename)
        guard fileManager.fileExists(atPath: videoURL.path),
              let generated = generateVideoThumbnail(from: videoURL) else {
            historyDebug("THUMBNAIL MISS video=\(videoFilename) thumbnailPath=\(thumbnailURL.path) videoPath=\(videoURL.path)")
            return nil
        }
        persistThumbnail(generated, for: videoFilename)
        thumbnailMemoryCache.setObject(generated, forKey: cacheKey)
        historyDebug("THUMBNAIL GENERATED video=\(videoFilename) thumbnailPath=\(thumbnailURL.path)")
        return generated
    }

    private func deleteVideoAssets(for videoFilename: String) {
        thumbnailMemoryCache.removeObject(forKey: videoFilename as NSString)

        let managedDirectory = getVideoEntryDirectory(for: videoFilename)
        let managedVideoURL = managedDirectory.appendingPathComponent(videoFilename)
        let managedThumbnailURL = managedDirectory.appendingPathComponent("thumbnail.jpg")
        let managedTranscriptURL = managedDirectory.appendingPathComponent("transcript.md")
        let flatVideosURL = getVideosDirectory().appendingPathComponent(videoFilename)
        let rootVideosURL = getDocumentsDirectory().appendingPathComponent(videoFilename)

        let candidateURLs = [managedVideoURL, managedThumbnailURL, managedTranscriptURL, flatVideosURL, rootVideosURL]
        for url in candidateURLs where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                print("Error deleting video asset \(url.lastPathComponent): \(error)")
            }
        }

        if fileManager.fileExists(atPath: managedDirectory.path) {
            do {
                try fileManager.removeItem(at: managedDirectory)
            } catch {
                print("Error deleting video entry directory: \(error)")
            }
        }
    }

    private func loadTranscriptText(for videoFilename: String) -> String? {
        let transcriptURL = getVideoTranscriptURL(for: videoFilename)
        guard fileManager.fileExists(atPath: transcriptURL.path),
              let content = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            return nil
        }
        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func previewTextFromTranscript(_ transcript: String?) -> String {
        guard let transcript else {
            return "Video Entry"
        }

        let normalized = transcript
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return "Video Entry"
        }

        var preview = String(normalized.prefix(10))

        while let last = preview.last, (!last.isLetter && !last.isNumber) {
            preview.removeLast()
        }

        if preview.isEmpty {
            return "Video Entry"
        }

        return preview + "..."
    }

    private func videoPreviewText(for videoFilename: String) -> String {
        previewTextFromTranscript(loadTranscriptText(for: videoFilename))
    }

    private func copyTranscriptForSelectedVideoEntry() {
        guard let selectedEntryId,
              let selectedEntry = entries.first(where: { $0.id == selectedEntryId }),
              let videoFilename = resolvedVideoFilename(for: selectedEntry),
              let transcript = loadTranscriptText(for: videoFilename) else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcript, forType: .string)
        didCopyTranscript = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            didCopyTranscript = false
        }
    }
    
    private func parseCanonicalEntryFilename(_ filename: String) -> (uuid: UUID, timestamp: Date)? {
        StorageTransfer.parseEntryFilename(filename)
    }
    
    private func isEntryNewer(_ lhs: HumanEntry, than rhs: HumanEntry) -> Bool {
        let lhsTimestamp = parseCanonicalEntryFilename(lhs.filename)?.timestamp ?? .distantPast
        let rhsTimestamp = parseCanonicalEntryFilename(rhs.filename)?.timestamp ?? .distantPast
        if lhsTimestamp == rhsTimestamp {
            return lhs.filename > rhs.filename
        }
        return lhsTimestamp > rhsTimestamp
    }
    
    private func isEntryFromToday(_ entry: HumanEntry, calendar: Calendar = .current, today: Date = Date()) -> Bool {
        guard let timestamp = parseCanonicalEntryFilename(entry.filename)?.timestamp else {
            return false
        }
        return calendar.isDate(timestamp, inSameDayAs: today)
    }
    
    // Add function to save text
    private func saveText() {
        let documentsDirectory = getDocumentsDirectory()
        let fileURL = documentsDirectory.appendingPathComponent("entry.md")
        
        print("Attempting to save file to: \(fileURL.path)")
        
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            print("Successfully saved file")
        } catch {
            print("Error saving file: \(error)")
            print("Error details: \(error.localizedDescription)")
        }
    }
    
    // Add function to load text
    private func loadText() {
        let documentsDirectory = getDocumentsDirectory()
        let fileURL = documentsDirectory.appendingPathComponent("entry.md")
        
        print("Attempting to load file from: \(fileURL.path)")
        
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                text = try String(contentsOf: fileURL, encoding: .utf8)
                print("Successfully loaded file")
            } else {
                print("File does not exist yet")
            }
        } catch {
            print("Error loading file: \(error)")
            print("Error details: \(error.localizedDescription)")
        }
    }
    
    // Add function to load existing entries
    private func loadExistingEntries() {
        let documentsDirectory = getDocumentsDirectory()
        print("Looking for entries in: \(documentsDirectory.path)")
        print("Looking for videos in: \(getVideosDirectory().path)")
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil)
            // A locked note is `[UUID]-[date].fwlock`; if an interrupted lock or unlock left the
            // `.md` too, the locked note is listed. When it's opened, an identical `.md` is deleted
            // and a newer, different one becomes its current text (`reconcileLeftoverPlainFiles`),
            // so edits in it are never hidden for good.
            let lockedFiles = fileURLs.filter { $0.pathExtension == LockedFileFormat.fileExtension }
            let lockedBases = Set(lockedFiles.map { $0.deletingPathExtension().lastPathComponent })
            let mdFiles = fileURLs.filter { $0.pathExtension == "md" && !lockedBases.contains($0.deletingPathExtension().lastPathComponent) }
                + lockedFiles

            print("Found \(mdFiles.count) .md files")
            let manifests = versionStore.savedManifests()
            let lockStore = versionStore

            // Process each file
            let entriesWithDates = mdFiles.compactMap { fileURL -> (entry: HumanEntry, date: Date, content: String)? in
                let filename = fileURL.lastPathComponent
                print("Processing: \(filename)")

                // Only accept canonical entry filenames: [UUID]-[yyyy-MM-dd-HH-mm-ss].md (or .fwlock)
                let isLocked = fileURL.pathExtension == LockedFileFormat.fileExtension
                guard let parsed = StorageTransfer.parseEntryFilename(filename, extension: fileURL.pathExtension) else {
                    print("Skipping non-canonical entry filename: \(filename)")
                    return nil
                }
                let uuid = parsed.uuid
                let fileDate = parsed.timestamp
                if isLocked {
                    // No preview or video: nothing of a locked note is read until it's opened.
                    // (entry.json stays plain, so the version count is known.)
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "MMM d"
                    let logicalFilename = fileURL.deletingPathExtension().lastPathComponent + ".md"
                    return (
                        entry: HumanEntry(
                            id: uuid,
                            date: dateFormatter.string(from: fileDate),
                            filename: logicalFilename,
                            previewText: "",
                            entryType: .text,
                            videoFilename: nil,
                            versionCount: manifests[logicalFilename]?.versions.count ?? 1,
                            hasVoiceNote: manifests[logicalFilename]?.hasVoiceNote ?? false,
                            isLocked: true,
                            hasNewerPlainCopy: lockStore.hasNewerPlainCopy(logicalFilename)
                        ),
                        date: fileDate,
                        content: ""
                    )
                }

                // Check if there's a corresponding video file
                let videoFilename = filename.replacingOccurrences(of: ".md", with: ".mov")
                let hasVideo = hasVideoAsset(for: videoFilename)

                // Read file contents for preview
                do {
                    let content = try String(contentsOf: fileURL, encoding: .utf8)
                    let preview = content
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let truncated = preview.isEmpty ? "" : (preview.count > 30 ? String(preview.prefix(30)) + "..." : preview)

                    // Format display date
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "MMM d"
                    let displayDate = dateFormatter.string(from: fileDate)

                    let manifest = hasVideo ? nil : manifests[filename]
                    return (
                        entry: HumanEntry(
                            id: uuid,
                            date: displayDate,
                            filename: filename,
                            previewText: hasVideo ? videoPreviewText(for: videoFilename) : truncated,
                            entryType: hasVideo ? .video : .text,
                            videoFilename: hasVideo ? videoFilename : nil,
                            versionCount: manifest?.versions.count ?? 1,
                            hasVoiceNote: manifest?.hasVoiceNote ?? false
                        ),
                        date: fileDate,
                        content: content  // Store the full content to check for welcome message
                    )
                } catch {
                    print("Error reading file: \(error)")
                    return nil
                }
            }
            
            // Sort and extract entries - store in temporary variable
            let loadedEntries = entriesWithDates
                .sorted {
                    if $0.date == $1.date {
                        return $0.entry.filename > $1.entry.filename
                    }
                    return $0.date > $1.date
                }
                .map { $0.entry }

            print("Successfully loaded and sorted \(loadedEntries.count) entries")

            // Check if we need to create a new entry
            let calendar = Calendar.current
            let today = Date()
            let hasEntryToday = loadedEntries.contains { isEntryFromToday($0, calendar: calendar, today: today) }
            let hasEmptyTextEntryToday = loadedEntries.contains {
                isEntryFromToday($0, calendar: calendar, today: today) &&
                $0.entryType == .text &&
                !$0.isLocked &&
                $0.previewText.isEmpty
            }

            // Check if we have only one entry and it's the welcome message
            let hasOnlyWelcomeEntry = loadedEntries.count == 1 && entriesWithDates.first?.content.contains("Welcome to Freewrite.") == true

            // Now assign to the state variable
            entries = loadedEntries
            logEntriesOrder("loadExistingEntries")

            // Never open directly into a video or a locked note on startup; create a fresh text entry instead.
            if let latestEntry = entries.first, latestEntry.entryType == .video || latestEntry.isLocked {
                print("Latest entry is a video or locked, creating new text entry for startup")
                createNewEntry()
                return
            }

            if entries.isEmpty {
                // First time user - create entry with welcome message
                print("First time user, creating welcome entry")
                createNewEntry()
            } else if !hasEntryToday && !hasOnlyWelcomeEntry {
                // No entries at all for today - create a new text entry
                print("No entry for today, creating new entry")
                createNewEntry()
            } else {
                // Prefer an empty text entry from today for writing continuity; otherwise pick latest entry.
                if hasEmptyTextEntryToday,
                   let todayEntry = entries.first(where: {
                       isEntryFromToday($0, calendar: calendar, today: today) &&
                       $0.entryType == .text &&
                       !$0.isLocked &&
                       $0.previewText.isEmpty
                   }) {
                    selectedEntryId = todayEntry.id
                    loadEntry(entry: todayEntry)
                } else if hasOnlyWelcomeEntry {
                    // If we only have the welcome entry, select it
                    selectedEntryId = entries[0].id
                    loadEntry(entry: entries[0])
                } else if let latestEntry = entries.first {
                    selectedEntryId = latestEntry.id
                    loadEntry(entry: latestEntry)
                }
            }
            
        } catch {
            print("Error loading directory contents: \(error)")
            print("Creating default entry after error")
            createNewEntry()
        }
    }
    
    // MARK: - Bottom bar

    /// Thin gap between the window's top edge and the editor's scroll area.
    private let editorTopMargin: CGFloat = 4
    /// Space before a note's first line; scrolls away with the text.
    private let noteTopInset: CGFloat = 16

    private var textColor: Color { colorScheme == .light ? Color.gray : Color.gray.opacity(0.8) }
    private var textHoverColor: Color { colorScheme == .light ? Color.black : Color.white }

    private var bottomBarLayout: BottomBarLayout { BottomBarLayout.decode(bottomBarLayoutJSON) }

    private func isBottomBarItemAvailable(_ item: BottomBarItem) -> Bool {
        switch item {
        // Writing-only controls.
        case .backspace, .lock: return currentVideoURL == nil
        // Nothing of a locked note is shown (or sent to a reviewer) until it's opened.
        case .versions, .recordVoiceNote: return currentVideoURL == nil && !isSelectedNoteClosed
        // Locked notes are never sent to a reviewer, open or not.
        case .review: return currentVideoURL == nil && selectedTextEntry?.isLocked != true
        default: return true
        }
    }

    /// The bottom bar with `overflow` moved into a "…" menu.
    private func bottomBarRow(overflow: [BottomBarItem], isViewingVideoEntry: Bool) -> some View {
        HStack {
            HStack(spacing: 8) {
                if !isViewingVideoEntry && textEntryStatusVisible {
                    textEntryStatus(textColor: textColor, textHoverColor: textHoverColor)
                }
                if isViewingVideoEntry {
                    HStack(spacing: 8) {
                        if let transcriptionStatus {
                            Text(transcriptionStatus)
                                .font(.system(size: 13))
                                .foregroundColor(textColor)
                                .lineLimit(1)
                                .frame(maxWidth: 280, alignment: .leading)
                                .help(transcriptionStatus)
                        }
                        if selectedVideoHasTranscript {
                            Button(action: {
                                copyTranscriptForSelectedVideoEntry()
                            }) {
                                Text(didCopyTranscript ? "Copied Transcript" : "Copy Transcript")
                                    .font(.system(size: 13))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("copyTranscriptButton")
                            .foregroundColor(isHoveringCopyTranscript ? textHoverColor : textColor)
                            .onHover { hovering in
                                isHoveringCopyTranscript = hovering
                                isHoveringBottomNav = hovering
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                        }
                    }
                }
                bottomBarGroup(bottomBarLayout.left.filter { !overflow.contains($0) }, leading: isViewingVideoEntry ? (transcriptionStatus != nil || selectedVideoHasTranscript) : textEntryStatusVisible)
            }
            .padding(8)
            .cornerRadius(6)
            .onHover { hovering in
                isHoveringBottomNav = hovering
            }
            // Sized first, then the right side; otherwise both get an equal share and the
            // status, separators and version label are squeezed while the spacer keeps room.
            .layoutPriority(2)

            Spacer()

            HStack(spacing: 8) {
                bottomBarGroup(bottomBarLayout.right.filter { !overflow.contains($0) }, overflow: overflow)
            }
            .barMenuAnchor(.barRight)
            .padding(8)
            .cornerRadius(6)
            .onHover { hovering in
                isHoveringBottomNav = hovering
            }
            .layoutPriority(1)
            // While a voice note records, the bar turns into its controls.
            .opacity(voiceRecorder.isRecording ? 0 : 1)
            .allowsHitTesting(!voiceRecorder.isRecording)
            .overlay(alignment: .trailing) {
                if voiceRecorder.isRecording {
                    voiceNoteRecordingBar(textColor: textColor, textHoverColor: textHoverColor)
                }
            }
        }
    }

    /// Visible bar items that may move into "…", in the order they do.
    private var barOverflowCandidates: [BottomBarItem] {
        let visible = Set((bottomBarLayout.left + bottomBarLayout.right).filter(isBottomBarItemAvailable))
        return Self.overflowOrder.filter(visible.contains)
    }

    @ViewBuilder
    private func bottomBarGroup(_ items: [BottomBarItem], leading: Bool = false, overflow: [BottomBarItem] = []) -> some View {
        // nil is the "…" button, placed before the gear so Settings stays last.
        let visible: [BottomBarItem?] = {
            var visible: [BottomBarItem?] = items.filter(isBottomBarItemAvailable)
            if !overflow.isEmpty {
                visible.insert(nil, at: visible.firstIndex(of: .settings) ?? visible.endIndex)
            }
            return visible
        }()
        ForEach(Array(visible.enumerated()), id: \.element) { index, item in
            if index > 0 || leading {
                Text("•")
                    .foregroundColor(.gray)
            }
            if let item {
                bottomBarItemView(item)
            } else {
                overflowButton(items: overflow, textColor: textColor, textHoverColor: textHoverColor)
            }
        }
    }

    @ViewBuilder
    private func bottomBarItemView(_ item: BottomBarItem) -> some View {
        switch item {
        case .versions:
            versionsButton(textColor: textColor, textHoverColor: textHoverColor)
        case .recordVoiceNote:
            voiceNoteButton(textColor: textColor, textHoverColor: textHoverColor)
        case .review:
            reviewButton(textColor: textColor, textHoverColor: textHoverColor)
        case .timer:
                Button(timerButtonTitle) {
                    let now = Date()
                    if let lastClick = lastClickTime,
                       now.timeIntervalSince(lastClick) < 0.3 {
                        timeRemaining = sessionMinutes * 60
                        timerIsRunning = false
                        lastClickTime = nil
                    } else {
                        timerIsRunning.toggle()
                        lastClickTime = now
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(timerIsRunning ? "Pause timer" : "Start timer")
                .accessibilityValue(timerButtonTitle)
                .accessibilityIdentifier("timerButton")
                .foregroundColor(timerColor)
                .onHover { hovering in
                    isHoveringTimer = hovering
                    isHoveringBottomNav = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
        case .recordVideo:
                Button(action: {
                    guard !isPreparingVideoRecording else { return }
                    startVideoRecordingPreflight()
                }) {
                    Group {
                        if isPreparingVideoRecording {
                            ProgressView()
                                .controlSize(.small)
                                .tint(isHoveringVideoButton ? textHoverColor : textColor)
                        } else {
                            Image(systemName: "video.fill")
                                .foregroundColor(isHoveringVideoButton ? textHoverColor : textColor)
                        }
                    }
                    .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Record video")
                .accessibilityIdentifier("recordVideoButton")
                .onHover { hovering in
                    isHoveringVideoButton = hovering
                    isHoveringBottomNav = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .barMenuAnchor(.item(.recordVideo))
        case .backspace:
                Button(action: {
                    backspaceDisabled.toggle()
                }) {
                    Text(backspaceDisabled ? "Backspace is Off" : "Backspace is On")
                        .foregroundColor(isHoveringBackspaceToggle ? textHoverColor : textColor)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("backspaceToggle")
                .onHover { hovering in
                    isHoveringBackspaceToggle = hovering
                    isHoveringBottomNav = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
        case .fullscreen:
                Button(isFullscreen ? "Minimize" : "Fullscreen") {
                    if let window = NSApplication.shared.windows.first {
                        window.toggleFullScreen(nil)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("fullscreenButton")
                .foregroundColor(isHoveringFullscreen ? textHoverColor : textColor)
                .onHover { hovering in
                    isHoveringFullscreen = hovering
                    isHoveringBottomNav = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
        case .newEntry:
                Button(action: {
                    createNewEntry()
                }) {
                    Text("New Entry")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("newEntryButton")
                .foregroundColor(isHoveringNewEntry ? textHoverColor : textColor)
                .onHover { hovering in
                    isHoveringNewEntry = hovering
                    isHoveringBottomNav = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
        case .history:
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingSidebar.toggle()
                    }
                }) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundColor(isHoveringClock ? textHoverColor : textColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showingSidebar ? "Hide history" : "Show history")
                .accessibilityIdentifier("historyButton")
                .onHover { hovering in
                    isHoveringClock = hovering
                    isHoveringBottomNav = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
        case .lock:
                lockButton(textColor: textColor, textHoverColor: textHoverColor)
        case .settings:
                Button(action: { SettingsWindow.toggle(openSettings) }) {
                    Image(systemName: "gearshape")
                        .foregroundColor(isHoveringSettings ? textHoverColor : textColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("settingsButton")
                .help("Settings")
                .onHover { hovering in
                    isHoveringSettings = hovering
                    isHoveringBottomNav = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
        }
    }

    /// Saves the current text entry, then selects and loads another one (at a sealed
    /// version when `version` is given; otherwise at its current version).
    private func selectEntry(id: UUID, version: String? = nil) {
        guard selectedEntryId != id else {
            if let version {
                showVersion(version)
            } else {
                showCurrentVersion()
            }
            return
        }
        if let currentId = selectedEntryId,
           let currentEntry = entries.first(where: { $0.id == currentId }),
           currentEntry.entryType == .text {
            saveEntry(entry: currentEntry)
        }

        // Re-resolve from source of truth after any state mutations.
        guard let targetEntry = entries.first(where: { $0.id == id }) else {
            historyDebug("SELECT target missing id=\(id.uuidString)")
            return
        }
        selectedEntryId = targetEntry.id
        historyDebug("SELECT resolved target \(debugEntrySummary(targetEntry))")
        loadEntry(entry: targetEntry)
        if let version {
            showVersion(version)
        }
    }

    private func openCommandPalette() {
        let loadID = UUID()
        paletteLoadID = loadID
        paletteIndex = nil
        showingCommandPalette = true
        // Read and fold every entry's text (or video transcript) off the main thread.
        let sources: [(entry: HumanEntry, url: URL?)] = entries.map { entry in
            // Locked notes are listed by date only; their files are never read for search.
            if entry.isLocked { return (entry, nil) }
            if entry.entryType == .video {
                return (entry, resolvedVideoFilename(for: entry).map(getVideoTranscriptURL(for:)))
            }
            return (entry, getDocumentsDirectory().appendingPathComponent(entry.filename))
        }
        let store = versionStore
        let reviewActions = paletteReviewActions
        Task {
            let index = await Task.detached(priority: .userInitiated) {
                PaletteIndex(sources.flatMap { source in
                    let current = PaletteDocument(
                        id: source.entry.id,
                        date: source.entry.date,
                        isVideo: source.entry.entryType == .video,
                        body: source.url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "",
                        isLocked: source.entry.isLocked
                    )
                    guard source.entry.entryType == .text, !source.entry.isLocked, source.entry.versionCount > 1 else { return [current] }
                    let filename = source.entry.filename
                    let sealed = store.manifest(for: filename).sealedVersions.reversed().map { version in
                        PaletteDocument(
                            id: source.entry.id,
                            date: source.entry.date,
                            isVideo: false,
                            body: (try? store.text(of: version.id, for: filename)) ?? "",
                            version: version.id
                        )
                    }
                    return [current] + sealed
                }, reviewActions: reviewActions)
            }.value
            if showingCommandPalette && paletteLoadID == loadID {
                paletteIndex = index
            }
        }
    }

    private func performPaletteItem(_ item: PaletteItem) {
        showingCommandPalette = false
        switch item {
        case .entry(let document, _):
            selectEntry(id: document.id, version: document.version)
            if document.isLocked && !noteLock.isUnlocked {
                openLockedNotes()
            }
        case .command(let command):
            handle(command)
        case .review(let reviewer, let versionId):
            // The row names a version; a menu command (New Version) may have changed it meanwhile.
            guard displayedVersion?.id == versionId else {
                showStatus("This entry is now on \(displayedVersion?.id ?? "another version"). Open ⌘K again to review it.")
                return
            }
            if let profile = reviewerProfiles.first(where: { $0.id == reviewer.id }) {
                startReview(profile)
            }
        case .clearReview:
            clearReview()
        case .reviewerSettings:
            openReviewerSettings()
        case .settings:
            SettingsWindow.toggle(openSettings)
        }
    }

    /// Review actions for the version on screen; reviewers only when a review could start now
    /// (never for locked notes, which reviewers can't read, like the bar's Review item).
    private var paletteReviewActions: PaletteReviewActions {
        guard let entry = selectedTextEntry, !isSelectedNoteClosed, let version = displayedVersion else { return .none }
        return PaletteReviewActions(
            versionId: version.id,
            reviewers: runningReview == nil && !entry.isLocked ? reviewerProfiles.map { .init(id: $0.id, name: $0.name) } : [],
            noteCount: annotations.filter { $0.versionId == version.id && $0.status != .dismissed }.count
        )
    }

    private func handle(_ command: AppCommand) {
        switch command {
        case .commandPalette:
            if showingCommandPalette {
                showingCommandPalette = false
            } else if !isPreparingVideoRecording && !showingVideoRecording && !voiceRecorder.isRecording {
                // The video recorder / voice-note bar owns the window while it's up.
                openCommandPalette()
            }
        case .newEntry:
            createNewEntry()
        case .newVersion:
            createNewVersion()
        case .recordVoiceNote:
            toggleVoiceNoteRecording()
        case .reviewEntry:
            openReviewMenu()
        case .toggleNoteLock:
            if let selectedEntryId, let entry = entries.first(where: { $0.id == selectedEntryId }) {
                toggleNoteLock(entry)
            }
        case .toggleHistory:
            withAnimation(.easeInOut(duration: 0.2)) {
                showingSidebar.toggle()
            }
        case .toggleTimer:
            timerIsRunning.toggle()
        case .recordVideo:
            startVideoRecordingPreflight()
        case .toggleBackspace:
            backspaceDisabled.toggle()
        case .toggleTheme:
            colorSchemeSetting = colorScheme == .light ? "dark" : "light"
        case .increaseFontSize, .decreaseFontSize:
            let sizes = WritingFont.sizes
            let index = sizes.firstIndex(of: fontSizeSetting) ?? sizes.firstIndex(of: WritingFont.defaultSize) ?? 0
            let step = command == .increaseFontSize ? 1 : -1
            fontSizeSetting = sizes[min(max(index + step, 0), sizes.count - 1)]
        case .showWelcomeEntry:
            showWelcomeEntry()
        }
    }

    private func startVideoRecordingPreflight() {
        guard !isPreparingVideoRecording, !showingVideoRecording, !voiceRecorder.isRecording else {
            return
        }

        showingCommandPalette = false
        closeBarMenu(.videoPermission)
        videoPermissionPopoverItems = []
        videoPermissionPopoverFallbackMessage = nil

        let preparationID = UUID()
        let manager = CameraManager()
        manager.requiresSpeechRecognition = TranscriptionEngine.current == .apple

        videoRecordingPreparationID = preparationID
        preparedCameraManager = manager

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isPreparingVideoRecording = true
        }

        manager.onReadyToRecord = { [weak manager] in
            guard let manager else { return }
            DispatchQueue.main.async {
                finishVideoRecordingPreflight(
                    preparationID: preparationID,
                    manager: manager,
                    presentationDelay: 0.5
                )
            }
        }

        manager.onCannotRecord = { [weak manager] in
            guard let manager else { return }
            DispatchQueue.main.async {
                guard self.videoRecordingPreparationID == preparationID else {
                    return
                }
                let payload = self.videoPermissionPopoverPayload(
                    cameraGranted: manager.permissionGranted,
                    microphoneGranted: manager.microphonePermissionGranted,
                    speechGranted: manager.hasRequiredSpeechPermission
                )
                self.videoPermissionPopoverItems = payload.items
                self.videoPermissionPopoverFallbackMessage = payload.fallbackMessage
                self.showBarMenu(.videoPermission)
                self.clearVideoRecordingPreparationState()
            }
        }

        manager.checkPermissions()
    }

    private func finishVideoRecordingPreflight(
        preparationID: UUID,
        manager: CameraManager,
        presentationDelay: TimeInterval = 0
    ) {
        let presentRecorder = {
            guard videoRecordingPreparationID == preparationID else {
                return
            }

            videoRecordingPreparationID = nil
            manager.onReadyToRecord = nil
            manager.onCannotRecord = nil
            preparedCameraManager = manager

            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isPreparingVideoRecording = false
                showingVideoRecording = true
            }
        }

        if presentationDelay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + presentationDelay) {
                presentRecorder()
            }
        } else {
            presentRecorder()
        }
    }

    private func clearVideoRecordingPreparationState() {
        preparedCameraManager?.onReadyToRecord = nil
        preparedCameraManager?.onCannotRecord = nil
        videoRecordingPreparationID = nil
        isPreparingVideoRecording = false
        preparedCameraManager = nil
    }

    private func videoPermissionPopoverPayload(
        cameraGranted: Bool,
        microphoneGranted: Bool,
        speechGranted: Bool
    ) -> (items: [VideoPermissionPopoverItem], fallbackMessage: String?) {
        var items: [VideoPermissionPopoverItem] = []
        if !cameraGranted {
            items.append(
                VideoPermissionPopoverItem(
                    message: "Hey, we need camera permission.",
                    buttonLabel: "Open Camera Settings",
                    settingsPane: "Privacy_Camera"
                )
            )
        }
        if !microphoneGranted {
            items.append(
                VideoPermissionPopoverItem(
                    message: "Hey, we need microphone permission.",
                    buttonLabel: "Open Microphone Settings",
                    settingsPane: "Privacy_Microphone"
                )
            )
        }
        if !speechGranted {
            items.append(
                VideoPermissionPopoverItem(
                    message: "Hey, we need speech recognition permission.",
                    buttonLabel: "Open Speech Settings",
                    settingsPane: "Privacy_SpeechRecognition"
                )
            )
        }

        if items.isEmpty {
            return (
                items: [],
                fallbackMessage: "Could not prepare camera right now. Please try again."
            )
        }

        return (
            items: items,
            fallbackMessage: nil
        )
    }

    private func openVideoPermissionSettings(_ settingsPane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsPane)") {
            NSWorkspace.shared.open(url)
        }
    }


    // MARK: Locked notes

    /// The selected text entry is locked and not open: the placeholder replaces the editor and
    /// nothing of the note (text, versions, voice notes) is shown or written.
    private var isSelectedNoteClosed: Bool {
        guard let entry = selectedTextEntry else { return false }
        return entry.isLocked && openLockedNoteId != entry.id
    }

    /// Forgets which locked note is in `text`, so nothing saves into it any more.
    private func closeLockedNote() {
        openLockedNoteId = nil
        lockedNoteSavedText = nil
    }

    /// Asks for Touch ID / Apple Watch / the Mac password. The selected note then loads via
    /// `.onChange(of: noteLock.isUnlocked)`.
    private func openLockedNotes() {
        guard !isUnlockingNotes else { return }
        isUnlockingNotes = true
        Task {
            defer { isUnlockingNotes = false }
            do {
                try await noteLock.unlock()
            } catch NoteLockError.cancelled {
                // Stay closed, no alert.
            } catch {
                showStatus(error.localizedDescription)
            }
        }
    }

    /// Opens locked notes if needed (one prompt). False if the user cancelled or it failed.
    private func ensureNotesOpen(reason: String) async -> Bool {
        do {
            try await noteLock.unlock(reason: reason)
            return true
        } catch NoteLockError.cancelled {
            return false
        } catch {
            showStatus(error.localizedDescription)
            return false
        }
    }

    private func toggleNoteLock(_ entry: HumanEntry) {
        if entry.isLocked {
            confirmUnlockNote(entry)
        } else {
            lockNote(entry)
        }
    }

    /// Locks a text entry. The first time, the recovery key sheet comes first.
    private func lockNote(_ entry: HumanEntry) {
        guard entry.entryType == .text else {
            NSSound.beep()
            showStatus("Video entries can't be locked yet.")
            return
        }
        guard !storage.isTransferring, !voiceRecorder.isRecording else {
            NSSound.beep()
            return
        }
        guard transcriptionStatuses[entry.id]?.hasPrefix("Transcribing") != true else {
            showStatus("Wait for the voice note's transcript before locking this note.", for: entry.id)
            return
        }
        guard noteLock.isAvailable else {
            showStatus(NoteLockError.unavailable.localizedDescription, for: entry.id)
            return
        }
        if let vaultError = noteLock.vaultError {
            showStatus(vaultError, for: entry.id)
            return
        }
        guard noteLock.hasVault else {
            recoverySetup = RecoverySetupRequest(entryId: entry.id, recoveryKey: .generate())
            return
        }
        Task {
            guard await ensureNotesOpen(reason: "lock this note") else { return }
            // Re-resolve: things may have changed while the prompt was up.
            guard let entry = entries.first(where: { $0.id == entry.id }), !entry.isLocked else { return }
            performLock(entry)
        }
    }

    private func performLock(_ entry: HumanEntry) {
        let isSelected = selectedEntryId == entry.id
        if isSelected {
            showCurrentVersion()
            guard saveEntry(entry: entry) else {
                showStatus("Couldn't save this note, so it wasn't locked.", for: entry.id)
                return
            }
        }
        do {
            let notRemoved = try versionStore.lock(entryFilename: entry.filename)
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index].isLocked = true
                entries[index].previewText = ""
            }
            if isSelected {
                // It stays open until locked notes close (idle, sleep).
                openLockedNoteId = entry.id
                lockedNoteSavedText = text
            }
            showStatus(notRemoved.isEmpty
                       ? "Note locked."
                       : "Note locked, but \(notRemoved.count) plain file(s) couldn't be deleted.", for: entry.id)
        } catch {
            showStatus("Couldn't lock this note: \(error.localizedDescription)", for: entry.id)
        }
    }

    /// Turns a locked note back into plain files, after confirming.
    private func confirmUnlockNote(_ entry: HumanEntry) {
        guard !storage.isTransferring, !voiceRecorder.isRecording else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Unlock this note?"
        alert.informativeText = "It will be saved as plain files again, readable by anything that can open your entries folder. To just read it, use Unlock on the note instead: it stays encrypted on disk."
        alert.addButton(withTitle: "Unlock Note")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            guard await ensureNotesOpen(reason: "unlock this note") else { return }
            guard let entry = entries.first(where: { $0.id == entry.id }), entry.isLocked else { return }
            if openLockedNoteId == entry.id {
                guard saveEntry(entry: entry) else {
                    showStatus("Couldn't save this note, so it wasn't unlocked.", for: entry.id)
                    return
                }
            }
            // The note only shows as unlocked once its files are plain: a failure leaves it locked.
            let staleFiles: [URL]
            do {
                staleFiles = try versionStore.unlock(entryFilename: entry.filename)
            } catch {
                showStatus("Couldn't unlock this note: \(error.localizedDescription)", for: entry.id)
                return
            }
            guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
            entries[index].isLocked = false
            entries[index].hasNewerPlainCopy = false
            applyManifest(versionStore.manifest(for: entry.filename), toEntry: entry.id)
            updatePreviewText(for: entries[index])
            if selectedEntryId == entry.id {
                loadEntry(entry: entries[index])
            }
            showStatus(staleFiles.isEmpty
                       ? "Note unlocked."
                       : "Note unlocked, but \(staleFiles.count) old encrypted file(s) couldn't be deleted.", for: entry.id)
        }
    }

    /// Deals with plain files an interrupted lock or unlock left next to a locked note that's
    /// being opened, and tells the user when that changed the note.
    private func reconcileLeftoverPlainFiles(of entry: HumanEntry, in store: EntryVersionStore) {
        do {
            let result = try store.reconcileLeftoverPlainFiles(of: entry.filename)
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index].hasNewerPlainCopy = false
            }
            if result.restoredNewerText {
                applyManifest(store.manifest(for: entry.filename), toEntry: entry.id)
                showStatus(result.sealedVersion.map { "Brought back edits saved while this note was being unlocked; the text they replaced is \($0)." }
                           ?? "Brought back edits saved while this note was being unlocked.", for: entry.id)
            } else if !result.kept.isEmpty {
                showStatus("\(result.kept.count) plain file(s) next to this locked note differ from it and were left in place.", for: entry.id)
            }
        } catch {
            showStatus("Couldn't tidy up this note's plain copies: \(error.localizedDescription)", for: entry.id)
        }
    }

    /// Bottom-bar item: the selected note's lock state; click to lock or unlock it.
    private func lockButton(textColor: Color, textHoverColor: Color) -> some View {
        let isLocked = selectedTextEntry?.isLocked == true
        return Button(action: {
            if let entry = selectedTextEntry {
                toggleNoteLock(entry)
            }
        }) {
            Image(systemName: isLocked ? "lock.fill" : "lock.open")
                .foregroundColor(isHoveringLock ? textHoverColor : textColor)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .disabled(selectedTextEntry == nil || storage.isTransferring)
        .accessibilityLabel(isLocked ? "Unlock note" : "Lock note")
        .accessibilityValue(isLocked ? "Locked" : "Not locked")
        .accessibilityIdentifier("lockNoteButton")
        .help(isLocked ? "This note is locked. Click to unlock it for good." : "Lock this note: encrypt it and require Touch ID to open it")
        .onHover { hovering in
            isHoveringLock = hovering
            hoverCursor(hovering)
        }
    }

    /// Shown instead of the editor while the selected locked note is closed.
    private var lockedNotePlaceholder: some View {
        let entry = selectedTextEntry
        let keyID = entry.flatMap { versionStore.lockKeyID(of: $0.filename) }
        let lockedElsewhere = keyID.map { !noteLock.hasKey($0) } ?? false
        return VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(textColor)
            Text("This note is locked")
                .font(.custom(selectedFont, size: fontSize))
                .foregroundColor(colorScheme == .light ? Color(red: 0.20, green: 0.20, blue: 0.20) : Color(red: 0.9, green: 0.9, blue: 0.9))
            if entry?.hasNewerPlainCopy == true {
                Text("Changes saved to this note while it was being unlocked are kept and come back when you open it.")
                    .font(.system(size: 13))
                    .foregroundColor(textColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .accessibilityIdentifier("lockedNoteNewerPlainCopy")
            }
            if lockedElsewhere {
                Text("It was locked on another Mac. Unlock it once with your recovery key in Settings › Privacy.")
                    .font(.system(size: 13))
                    .foregroundColor(textColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Button("Open Privacy Settings") {
                    UserDefaults.standard.set("privacy", forKey: "settingsPane")
                    openSettings()
                }
                .accessibilityIdentifier("openPrivacySettingsButton")
            } else {
                Text("Open it with Touch ID, your Apple Watch or your Mac password. It stays encrypted on disk.")
                    .font(.system(size: 13))
                    .foregroundColor(textColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Button(isUnlockingNotes ? "Unlocking…" : "Unlock") {
                    openLockedNotes()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isUnlockingNotes)
                .accessibilityIdentifier("unlockLockedNoteButton")
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Versions

    /// The selected entry when it's a text entry shown in the editor.
    private var selectedTextEntry: HumanEntry? {
        guard currentVideoURL == nil, let selectedEntryId,
              let entry = entries.first(where: { $0.id == selectedEntryId }),
              entry.entryType == .text else { return nil }
        return entry
    }

    /// The version on screen: a sealed one being viewed, else the current one.
    private var displayedVersion: EntryVersion? {
        viewedVersion ?? entryManifest?.currentVersion
    }

    private func showVersion(_ versionId: String) {
        guard let entry = selectedTextEntry, !isSelectedNoteClosed, let manifest = entryManifest else { return }
        guard versionId != manifest.current else {
            showCurrentVersion()
            return
        }
        guard let version = manifest.version(versionId) else { return }
        do {
            viewedVersionText = try versionStore.text(of: versionId, for: entry.filename)
            viewedVersion = version
            voicePlayer.stop()
        } catch {
            showStatus("Couldn't open \(versionId): \(error.localizedDescription)")
        }
    }

    private func showCurrentVersion() {
        guard viewedVersion != nil else { return }
        viewedVersion = nil
        viewedVersionText = ""
        voicePlayer.stop()
    }

    /// Forgets the version state of the previously selected entry.
    private func resetVersionState(for entry: HumanEntry?) {
        viewedVersion = nil
        viewedVersionText = ""
        closeBarMenu()
        voicePlayer.stop()
        if let entry, entry.entryType == .text {
            // Every text entry has at least v1, so the version menu (and New Version) is always there.
            entryManifest = versionStore.manifest(for: entry.filename)
        } else {
            entryManifest = nil
        }
    }

    /// Keeps the history row (badge, palette search) in step with the entry's manifest.
    private func applyManifest(_ manifest: EntryManifest, toEntry id: UUID) {
        if selectedEntryId == id {
            entryManifest = manifest
        }
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].versionCount = manifest.versions.count
            entries[index].hasVoiceNote = manifest.hasVoiceNote
        }
    }

    /// Seals the current text as vN and continues on an empty page as vN+1.
    private func createNewVersion() {
        guard let entry = selectedTextEntry, !isSelectedNoteClosed, !voiceRecorder.isRecording else { return }
        showCurrentVersion()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            showStatus(EntryVersionStore.Failure.emptyVersion.localizedDescription)
            return
        }
        // The store seals what's on disk, so make sure that's exactly what's on screen.
        guard saveEntry(entry: entry) else {
            showStatus("Couldn't save this entry, so no new version was started.")
            return
        }
        // Same for the notes on it: their positions must match the text being sealed.
        flushAnnotationAnchors()
        do {
            let sealedId = entryManifest?.current ?? versionStore.manifest(for: entry.filename).current
            let manifest = try versionStore.sealCurrent(entryFilename: entry.filename)
            applyManifest(manifest, toEntry: entry.id)
            placeholderText = placeholderOptions.randomElement() ?? "Begin writing"
            text = ""
            updatePreviewText(for: entry)
            let automatic = reviewerProfiles.filter(\.autoRunOnNewVersion)
            if !automatic.isEmpty {
                runReviews(automatic, on: entry, versionId: sealedId)
            }
        } catch {
            showStatus("Couldn't start a new version: \(error.localizedDescription)")
        }
    }

    /// Bottom-bar status (transcribing, errors) for the selected entry.
    private var transcriptionStatus: String? {
        selectedEntryId.flatMap { transcriptionStatuses[$0] }
    }

    /// Shows a message in the bottom bar for a few seconds, on `entryId` (default: the selected entry).
    private func showStatus(_ message: String, for entryId: UUID? = nil) {
        guard let id = entryId ?? selectedEntryId else { return }
        transcriptionStatuses[id] = message
        Task {
            try? await Task.sleep(for: .seconds(6))
            if transcriptionStatuses[id] == message {
                transcriptionStatuses[id] = nil
            }
        }
    }

    private func versionDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        return formatter.string(from: date)
    }

    /// "voice note · Oct 27 09:12" for sealed versions, "current" (+ voice note) for the current one.
    private func versionDetail(_ version: EntryVersion, in manifest: EntryManifest) -> String {
        var parts: [String] = []
        if version.audio != nil { parts.append("voice note") }
        parts.append(version.id == manifest.current ? "current" : versionDateString(version.createdAt))
        return parts.joined(separator: " · ")
    }

    // MARK: Voice notes

    private func toggleVoiceNoteRecording() {
        if voiceRecorder.isRecording {
            stopVoiceNote()
            return
        }
        guard !isRequestingMicrophone, !isPreparingVideoRecording, !showingVideoRecording else { return }
        closeBarMenu(.microphonePermission)
        isRequestingMicrophone = true
        Task {
            let granted = await VoiceNoteRecorder.requestMicrophoneAccess()
            isRequestingMicrophone = false
            guard granted else {
                showBarMenu(.microphonePermission)
                return
            }
            do {
                voicePlayer.stop()
                voiceRecorder.onUnexpectedStop = { url, reason in
                    if let url {
                        saveVoiceNote(from: url)
                        showStatus("\(reason) What was recorded is saved.")
                    } else {
                        showStatus(reason)
                    }
                }
                try voiceRecorder.start()
                withAnimation(.easeOut(duration: 0.2)) {
                    bottomNavOpacity = 1.0
                }
            } catch {
                showStatus("Couldn't record: \(error.localizedDescription)")
            }
        }
    }

    private func stopVoiceNote() {
        guard let audioURL = voiceRecorder.stop() else {
            showStatus("Nothing was recorded.")
            return
        }
        saveVoiceNote(from: audioURL)
    }

    /// Files a finished recording. An empty text entry (or one that already has versions) gets it
    /// as its current version's voice note; otherwise it starts a new entry, like a video does.
    private func saveVoiceNote(from audioURL: URL) {
        let store = versionStore
        var target: HumanEntry
        var isNewEntry = false
        if let selected = selectedTextEntry, !isSelectedNoteClosed,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (entryManifest?.versions.count ?? 1) > 1 {
            saveEntry(entry: selected)
            target = selected
        } else {
            if let selected = selectedTextEntry, !isSelectedNoteClosed {
                saveEntry(entry: selected)
            }
            target = HumanEntry.createNew()
            do {
                try "".write(to: store.entryFileURL(for: target.filename), atomically: true, encoding: .utf8)
            } catch {
                showStatus("Couldn't save the voice note: \(error.localizedDescription)")
                return
            }
            isNewEntry = true
        }

        let attachment: VoiceNoteAttachment
        do {
            attachment = try store.attachVoiceNote(from: audioURL, to: target.filename)
        } catch {
            if isNewEntry {
                try? FileManager.default.removeItem(at: store.entryFileURL(for: target.filename))
            }
            showStatus("Couldn't save the voice note: \(error.localizedDescription)")
            return
        }

        target.versionCount = attachment.manifest.versions.count
        target.hasVoiceNote = true
        if isNewEntry {
            entries.insert(target, at: 0)
            entries.sort { isEntryNewer($0, than: $1) }
            selectedEntryId = target.id
            currentVideoURL = nil
            selectedVideoHasTranscript = false
            didCopyTranscript = false
            closeLockedNote()
            text = ""
            placeholderText = placeholderOptions.randomElement() ?? "Begin writing"
            resetVersionState(for: target)
        } else {
            showCurrentVersion()
        }
        applyManifest(attachment.manifest, toEntry: target.id)
        transcribeVoiceNote(attachment, entryId: target.id, entryFilename: target.filename)
    }

    /// Transcribes with the engine from Settings, keeps the raw transcript next to the audio and
    /// adds it to the version's text (if that version is still the current one).
    private func transcribeVoiceNote(_ attachment: VoiceNoteAttachment, entryId: UUID, entryFilename: String) {
        let engine = TranscriptionEngine.current
        let progress = engine == .hex ? "Transcribing with Hex…" : "Transcribing…"
        transcriptionStatuses[entryId] = progress
        // The folder the recording was saved in. The entries folder may change while this runs.
        // For a locked note it also holds the keys, so the transcript can be saved encrypted
        // even if locked notes close meanwhile.
        let origin = versionStore
        // A locked note's recording is transcribed from the plain temporary file, deleted after.
        let audioToTranscribe = attachment.temporaryPlaintextURL ?? attachment.audioURL
        Task {
            defer {
                if let temporary = attachment.temporaryPlaintextURL {
                    try? FileManager.default.removeItem(at: temporary)
                }
            }
            do {
                let transcript = try await engine.transcribe(fileURL: audioToTranscribe)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // The transcript goes next to the recording wherever it is now: still in the old
                // folder ("Just Switch"), moved, or copied (then both copies get it).
                let current = EntryVersionStore(root: versionStore.root, cipher: origin.cipher)
                let candidates = current.root == origin.root ? [origin] : [current, origin]
                let holders = candidates.filter { store in
                    store.fileExists(atRelativePath: attachment.audioPath, entryFilename: entryFilename)
                }
                guard let store = holders.first else {
                    showStatus("The voice note was moved before its transcript finished.", for: entryId)
                    return
                }
                for holder in holders {
                    do {
                        try holder.saveTranscript(transcript, forAudio: attachment.audioPath, entryFilename: entryFilename)
                    } catch {
                        print("Voice note: couldn't save transcript in \(holder.root.path): \(error)")
                    }
                }
                guard !transcript.isEmpty else {
                    showStatus("No speech found in the voice note.", for: entryId)
                    return
                }
                guard store.manifest(for: entryFilename).current == attachment.versionId else {
                    showStatus("Transcript saved with \(attachment.versionId).", for: entryId)
                    return
                }
                let isOpenHere = !store.isLocked(entryFilename) || openLockedNoteId == entryId
                if store.root == current.root && selectedEntryId == entryId && currentVideoURL == nil && isOpenHere {
                    text = appending(transcript, to: text)  // autosaved like typing
                } else {
                    let existing = (try? store.currentText(for: entryFilename)) ?? ""
                    try store.saveCurrentText(appending(transcript, to: existing), for: entryFilename)
                    if store.root == current.root, let entry = entries.first(where: { $0.id == entryId }) {
                        updatePreviewText(for: entry)
                    }
                }
                if transcriptionStatuses[entryId] == progress {
                    transcriptionStatuses[entryId] = nil
                }
            } catch {
                showStatus("\(engine == .hex ? "Hex" : "Transcription"): \(error.localizedDescription)", for: entryId)
            }
        }
    }

    private func appending(_ transcript: String, to existing: String) -> String {
        guard !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return transcript }
        let body = existing.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return body + "\n\n" + transcript
    }

    /// Plays or pauses a voice note of the selected entry (decrypted in memory for a locked note).
    private func toggleVoiceNote(_ url: URL) {
        guard let entry = selectedTextEntry, entry.isLocked else {
            voicePlayer.toggle(url)
            return
        }
        guard !isSelectedNoteClosed else { return }
        let store = versionStore
        voicePlayer.toggle(url) {
            try store.readData(url, entryFilename: entry.filename)
        }
    }

    private func audioURL(for version: EntryVersion) -> URL? {
        audioURLs(for: version).last
    }

    /// Every voice note recorded for a version, oldest first.
    private func audioURLs(for version: EntryVersion) -> [URL] {
        guard let entry = selectedTextEntry else { return [] }
        return version.allAudio.map { versionStore.url(forRelativePath: $0, entryFilename: entry.filename) }
    }

    var timerButtonTitle: String {
        if !timerIsRunning && timeRemaining == 900 {
            return "15:00"
        }
        let minutes = timeRemaining / 60
        let seconds = timeRemaining % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    var timerColor: Color {
        if timerIsRunning {
            return isHoveringTimer ? (colorScheme == .light ? .black : .white) : .gray.opacity(0.8)
        } else {
            return isHoveringTimer ? (colorScheme == .light ? .black : .white) : (colorScheme == .light ? .gray : .gray.opacity(0.8))
        }
    }
    
    var lineHeight: CGFloat {
        let font = NSFont(name: selectedFont, size: fontSize) ?? .systemFont(ofSize: fontSize)
        let defaultLineHeight = getLineHeight(font: font)
        return (fontSize * 1.5) - defaultLineHeight
    }
    
    
    var body: some View {
        let navHeight: CGFloat = 68
        let isViewingVideoEntry = currentVideoURL != nil
        
        HStack(spacing: 0) {
            // Main content
            ZStack {
                Color(colorScheme == .light ? .white : .black)
                    .ignoresSafeArea()

                // Show video player if a video entry is selected
                if let videoURL = currentVideoURL {
                    VideoPlayerView(
                        videoURL: videoURL,
                        isPlaybackSuspended: isPreparingVideoRecording || showingVideoRecording
                    )
                        .id(videoURL.path)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(edges: .top)
                } else if isSelectedNoteClosed {
                    lockedNotePlaceholder
                        .padding(.bottom, navHeight)
                } else {
                    // Show text editor for text entries
                    // Accessibility label/identifier ("Entry text" / "editor") live on the NSTextView.
                    // A sealed version is shown read-only from its own text; `text` (the current
                    // version, autosaved) is never touched while viewing it.
                    WritingEditor(
                        text: viewedVersion == nil ? $text : .constant(viewedVersionText),
                        font: WritingEditor.font(named: selectedFont, size: fontSize),
                        lineSpacing: lineHeight,
                        textColor: colorScheme == .light
                            ? NSColor(srgbRed: 0.20, green: 0.20, blue: 0.20, alpha: 1)
                            : NSColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1),
                        isDark: colorScheme == .dark,
                        highlights: editorHighlights,
                        onDismissHighlight: { dismissAnnotation(id: $0) },
                        focusKey: selectedEntryId,
                        canTakeFocus: !showingCommandPalette,
                        isEditable: viewedVersion == nil,
                        verticalInset: noteTopInset
                    )
                    // Text fades out under the thin top margin as it scrolls up.
                    .mask {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: noteTopInset)
                            Color.black
                        }
                    }
                    .background(Color(colorScheme == .light ? .white : .black))
                    .frame(maxWidth: 650)
                    .padding(.top, editorTopMargin)
                    .padding(.bottom, bottomNavOpacity > 0 ? navHeight : 0)
                    .colorScheme(colorScheme)
                    .onAppear {
                        placeholderText = placeholderOptions.randomElement() ?? "Begin writing"
                        // Removed findSubview code which was causing errors

                        // Add keyboard monitor for backspace/delete keys (once; onAppear can fire repeatedly)
                        guard keyDownMonitor == nil else { return }
                        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                            // Check if backspace is disabled and the key is delete/backspace
                            // Only the writing editor: leave the palette search and the Settings window alone.
                            let isSettingsWindow = event.window?.identifier?.rawValue.contains("Settings") == true
                            if backspaceDisabled && !showingCommandPalette && !isSettingsWindow
                                && (event.keyCode == 51 || event.keyCode == 117) {
                                // Block the backspace/delete key
                                return nil
                            }
                            return event
                        }
                    }
                    .onDisappear {
                        if let keyDownMonitor {
                            NSEvent.removeMonitor(keyDownMonitor)
                            self.keyDownMonitor = nil
                        }
                    }
                    .overlay(
                        ZStack(alignment: .topLeading) {
                            if viewedVersion == nil && text.isEmpty {
                                Text(placeholderText)
                                    .font(.custom(selectedFont, size: fontSize))
                                    .foregroundColor(colorScheme == .light ? .gray.opacity(0.5) : .gray.opacity(0.6))
                                    .allowsHitTesting(false)
                                    .offset(x: 5, y: editorTopMargin + noteTopInset)
                            }
                        }, alignment: .topLeading
                    )
                }

                VStack {
                    Spacer()
                    // Items move into "…" (right to left in `overflowOrder`) rather than being
                    // clipped when the bar doesn't fit; Settings always stays.
                    ViewThatFits(in: .horizontal) {
                        ForEach(0...barOverflowCandidates.count, id: \.self) { count in
                            bottomBarRow(overflow: Array(barOverflowCandidates.prefix(count)), isViewingVideoEntry: isViewingVideoEntry)
                        }
                    }
                    .padding()
                    .background(Color(colorScheme == .light ? .white : .black))
                    .opacity(bottomNavOpacity)
                    .onHover { hovering in
                        isHoveringBottomNav = hovering
                        if hovering {
                            withAnimation(.easeOut(duration: 0.2)) {
                                bottomNavOpacity = 1.0
                            }
                        } else if timerIsRunning && !voiceRecorder.isRecording {
                            withAnimation(.easeIn(duration: 1.0)) {
                                bottomNavOpacity = 0.0
                            }
                        }
                    }
                }
            }
            
            // Right sidebar
            if showingSidebar {
                Divider()
                    .ignoresSafeArea(edges: .top)
                
                VStack(spacing: 0) {
                    // Header
                    Button(action: {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: getDocumentsDirectory().path)
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Text("History")
                                        .font(.system(size: 13))
                                        .foregroundColor(isHoveringHistory ? textHoverColor : textColor)
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 10))
                                        .foregroundColor(isHoveringHistory ? textHoverColor : textColor)
                                }
                                Text(getDocumentsDirectory().path)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .onHover { hovering in
                        isHoveringHistory = hovering
                    }
                    
                    Divider()
                    
                    // Entries List
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                Button(action: {
                                    historyDebug("ROW TAP \(debugEntrySummary(entry))")
                                    selectEntry(id: entry.id)
                                }) {
                                    HStack(alignment: .top) {
                                        // Show video thumbnail for video entries
                                        if let videoFilename = resolvedVideoFilename(for: entry) {
                                            if let thumbnail = loadThumbnailImage(for: videoFilename) {
                                                Image(nsImage: thumbnail)
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fill)
                                                    .frame(width: 40, height: 40)
                                                    .cornerRadius(4)
                                                    .overlay(
                                                        Image(systemName: "play.circle.fill")
                                                            .foregroundColor(.white)
                                                            .font(.system(size: 16))
                                                    )
                                            } else {
                                                // Fallback if thumbnail generation fails
                                                ZStack {
                                                    Rectangle()
                                                        .fill(Color.gray.opacity(0.3))
                                                        .frame(width: 40, height: 40)
                                                        .cornerRadius(4)
                                                    Image(systemName: "video.fill")
                                                        .foregroundColor(.gray)
                                                        .font(.system(size: 16))
                                                }
                                            }
                                        }

                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                if entry.isLocked {
                                                    // Never a preview: the text is encrypted.
                                                    Label("Locked note", systemImage: "lock.fill")
                                                        .labelStyle(.titleAndIcon)
                                                        .font(.system(size: 13))
                                                        .lineLimit(1)
                                                        .foregroundColor(.primary)
                                                } else {
                                                    Text(entry.previewText.isEmpty && entry.hasVoiceNote ? "Voice Note" : entry.previewText)
                                                        .font(.system(size: 13))
                                                        .lineLimit(1)
                                                        .foregroundColor(.primary)
                                                }

                                                Spacer()

                                                if hoveredEntryId != entry.id && !entry.isLocked {
                                                    historyBadges(for: entry)
                                                }
                                                
                                                // Export/Trash icons that appear on hover
                                                if hoveredEntryId == entry.id {
                                                    HStack(spacing: 8) {
                                                        // Export PDF button
                                                        Button(action: {
                                                            exportEntryAsPDF(entry: entry)
                                                        }) {
                                                            Image(systemName: "arrow.down.circle")
                                                                .font(.system(size: 11))
                                                                .foregroundColor(hoveredExportId == entry.id ? 
                                                                    (colorScheme == .light ? .black : .white) : 
                                                                    (colorScheme == .light ? .gray : .gray.opacity(0.8)))
                                                        }
                                                        .buttonStyle(.plain)
                                                        .accessibilityLabel("Export as PDF")
                                                        .accessibilityIdentifier("exportEntryButton")
                                                        .help("Export entry as PDF")
                                                        .onHover { hovering in
                                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                                hoveredExportId = hovering ? entry.id : nil
                                                            }
                                                            if hovering {
                                                                NSCursor.pointingHand.push()
                                                            } else {
                                                                NSCursor.pop()
                                                            }
                                                        }
                                                        
                                                        // Trash icon
                                                        Button(action: {
                                                            deleteEntry(entry: entry)
                                                        }) {
                                                            Image(systemName: "trash")
                                                                .font(.system(size: 11))
                                                                .foregroundColor(hoveredTrashId == entry.id ? .red : .gray)
                                                        }
                                                        .buttonStyle(.plain)
                                                        .accessibilityLabel("Delete entry")
                                                        .accessibilityIdentifier("deleteEntryButton")
                                                        .disabled(storage.isTransferring)
                                                        .onHover { hovering in
                                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                                hoveredTrashId = hovering ? entry.id : nil
                                                            }
                                                            if hovering {
                                                                NSCursor.pointingHand.push()
                                                            } else {
                                                                NSCursor.pop()
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                            
                                            Text(entry.date)
                                                .font(.system(size: 12))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(backgroundColor(for: entry))
                                    )
                                }
                                .buttonStyle(PlainButtonStyle())
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        hoveredEntryId = hovering ? entry.id : nil
                                    }
                                }
                                .onAppear {
                                    NSCursor.pop()  // Reset cursor when button appears
                                }
                                .help("Click to select this entry")  // Add tooltip
                                .contextMenu {
                                    if entry.entryType == .video {
                                        Button("Lock Note (not available for videos yet)") {}
                                            .disabled(true)
                                    } else {
                                        Button(entry.isLocked ? "Unlock Note…" : "Lock Note") {
                                            toggleNoteLock(entry)
                                        }
                                        .disabled(storage.isTransferring || !noteLock.isAvailable)
                                    }
                                }
                                .accessibilityLabel(entry.isLocked
                                    ? "Locked note, \(entry.date)"
                                    : "\(entry.previewText.isEmpty ? (entry.hasVoiceNote ? "Voice note" : "Empty entry") : entry.previewText), \(entry.date)\(entry.versionCount > 1 ? ", \(entry.versionCount) versions" : "")")
                                .accessibilityAddTraits(selectedEntryId == entry.id ? .isSelected : [])
                                .accessibilityIdentifier("historyRow-\(entry.id.uuidString)")
                                
                                if entry.id != entries.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
                .frame(width: 200)
                // Extend the sidebar background under the hidden title bar so the column
                // isn't cut off ~30pt below the top of the window.
                .background(Color(colorScheme == .light ? .white : NSColor.black).ignoresSafeArea(edges: .top))
            }
        }
        .overlayPreferenceValue(BarMenuAnchorKey.self) { anchors in
            barMenuOverlay(anchors)
        }
        .overlay {
            if showingCommandPalette {
                CommandPaletteView(
                    index: paletteIndex,
                    shortcutsJSON: shortcutsJSON,
                    onSelect: performPaletteItem,
                    onDismiss: { showingCommandPalette = false }
                )
                .zIndex(5)
            }
        }
        .overlay {
            if showingVideoRecording {
                VideoRecordingView(
                    isPresented: $showingVideoRecording,
                    cameraManager: preparedCameraManager
                ) { videoURL, transcript in
                    // Save the video and create entry
                    saveVideoEntry(from: videoURL, transcript: transcript)
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        showingVideoRecording = false
                    }
                }
                .zIndex(10)
            }
        }
        .frame(minWidth: 1100, minHeight: 600)
        .animation(.easeInOut(duration: 0.2), value: showingSidebar)
        .preferredColorScheme(colorScheme)
        .onAppear {
            WritingWindow.openCount += 1
            installTimerScrollMonitor()
            showingSidebar = false  // Hide sidebar by default
            timeRemaining = sessionMinutes * 60
            loadExistingEntries()
        }
        .onDisappear {
            WritingWindow.openCount -= 1
            closeBarMenu()
            if let scrollWheelMonitor {
                NSEvent.removeMonitor(scrollWheelMonitor)
                self.scrollWheelMonitor = nil
            }
            flushAnnotationAnchors()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            flushAnnotationAnchors()
        }
        // A bar menu belongs to what was on screen when it opened.
        .onChange(of: selectedEntryId) { closeBarMenu() }
        .onChange(of: currentVideoURL) { closeBarMenu() }
        .onChange(of: showingCommandPalette) { if showingCommandPalette { closeBarMenu() } }
        .onChange(of: voiceRecorder.isRecording) { if voiceRecorder.isRecording { closeBarMenu() } }
        .onChange(of: storage.rootURL) {
            // The entries folder changed in Settings; show what's in the new one.
            // Reviews stay tied to the folder they started in, so they stop here.
            reviews.stopReviews(outside: storage.rootURL)
            flushAnnotationAnchors()
            currentVideoURL = nil
            closeLockedNote()
            resetVersionState(for: nil)
            loadExistingEntries()
        }
        .onChange(of: noteLock.isUnlocked) { _, isUnlocked in
            if isUnlocked {
                // Opened (here or from Settings): show the selected locked note.
                if let entry = selectedTextEntry, entry.isLocked, openLockedNoteId != entry.id {
                    loadEntry(entry: entry)
                }
            } else if let entry = selectedTextEntry, entry.isLocked {
                // Closed after idle/sleep: every edit is already saved, so just forget the text.
                closeLockedNote()
                resetVersionState(for: entry)
                text = ""
            }
        }
        .sheet(item: $recoverySetup) { request in
            RecoveryKeySheet(recoveryKey: request.recoveryKey, mode: .setUp) { confirmed in
                recoverySetup = nil
                guard confirmed else { return }
                do {
                    try noteLock.createVault(recovery: request.recoveryKey)
                } catch {
                    showStatus("Couldn't set up locking: \(error.localizedDescription)")
                    return
                }
                if let entry = entries.first(where: { $0.id == request.entryId }) {
                    lockNote(entry)
                }
            }
        }
        .alert("Entries Folder Unavailable", isPresented: Binding(
            get: { storage.unavailableFolderNotice != nil },
            set: { if !$0 { storage.unavailableFolderNotice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(storage.unavailableFolderNotice ?? "")
        }
        .onChange(of: sessionMinutes) { _, minutes in
            if !timerIsRunning {
                timeRemaining = minutes * 60
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.notification)) { notification in
            guard let rawValue = notification.object as? String,
                  let command = AppCommand(rawValue: rawValue) else { return }
            handle(command)
        }
        .onChange(of: showingVideoRecording) { _, isShowing in
            if !isShowing {
                clearVideoRecordingPreparationState()
            }
        }
        .onChange(of: text) {
            // Save current entry when text changes (a locked one only while it's open, encrypted)
            if let currentId = selectedEntryId,
               let currentEntry = entries.first(where: { $0.id == currentId }),
               currentEntry.entryType == .text {
                saveEntry(entry: currentEntry)
            }
            followAnnotationEdits()
        }
        .onChange(of: annotationContext) {
            reloadAnnotations()
        }
        .onReceive(reviews.annotationsChanged) { filename in
            if filename == selectedTextEntry?.filename {
                reloadAnnotations()
            }
        }
        .onReceive(timer) { _ in
            // A long voice note isn't "idle": keep locked notes open while it records.
            if voiceRecorder.isRecording {
                noteLock.noteActivity()
            }
            if timerIsRunning && timeRemaining > 0 {
                timeRemaining -= 1
            } else if timeRemaining == 0 {
                timerIsRunning = false
                if !isHoveringBottomNav {
                    withAnimation(.easeOut(duration: 1.0)) {
                        bottomNavOpacity = 1.0
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            isFullscreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            isFullscreen = false
        }
    }
    
    /// Scrolling over the timer changes it in 5-minute steps. Installed once per window, not by
    /// the timer button, which comes and goes as the bar overflows.
    private func installTimerScrollMonitor() {
        guard scrollWheelMonitor == nil else { return }
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            if isHoveringTimer {
                let scrollBuffer = event.deltaY * 0.25

                if abs(scrollBuffer) >= 0.1 {
                    let currentMinutes = timeRemaining / 60
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                    let direction = -scrollBuffer > 0 ? 5 : -5
                    let newMinutes = currentMinutes + direction
                    let roundedMinutes = (newMinutes / 5) * 5
                    let newTime = roundedMinutes * 60
                    timeRemaining = min(max(newTime, 0), 2700)
                }
            }
            return event
        }
    }

    // MARK: Version & voice note controls

    private func hoverCursor(_ hovering: Bool) {
        isHoveringBottomNav = hovering
        if hovering {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    /// Version menu button (bottom bar item): shows the displayed version; click to switch
    /// versions or start a new one.
    @ViewBuilder
    private func versionsButton(textColor: Color, textHoverColor: Color) -> some View {
        if let manifest = entryManifest {
            Button(action: {
                toggleBarMenu(.versions)
            }) {
                HStack(spacing: 3) {
                    Text(displayedVersion?.id ?? manifest.current)
                        .font(.system(size: 13).monospacedDigit())
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                }
                .foregroundColor(isHoveringVersion || openBarMenu == .versions ? textHoverColor : textColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Version \(displayedVersion?.n ?? 1) of \(manifest.versions.count)")
            .accessibilityIdentifier("versionButton")
            .help("Versions")
            .onHover { hovering in
                isHoveringVersion = hovering
                isHoveringBottomNav = hovering
                hoverCursor(hovering)
            }
            .barMenuAnchor(.item(.versions))
        }
    }

    /// Voice notes of the version on screen (the current one, or a sealed one being viewed).
    private var displayedAudioURLs: [URL] {
        guard !isSelectedNoteClosed else { return [] }
        return displayedVersion.map(audioURLs(for:)) ?? []
    }

    /// Fixed start of the left side for text entries: the read-only notice of a sealed version,
    /// the displayed version's voice note (or its player) and transient status (transcribing,
    /// reviews, errors).
    private var textEntryStatusVisible: Bool {
        viewedVersion != nil || !displayedAudioURLs.isEmpty || transcriptionStatus != nil || runningReview != nil
    }

    @ViewBuilder
    private func textEntryStatus(textColor: Color, textHoverColor: Color) -> some View {
        let urls = displayedAudioURLs
        let parts = [viewedVersion != nil, !urls.isEmpty, transcriptionStatus != nil || runningReview != nil]
        let separatorBefore = { (index: Int) in parts[..<index].contains(true) }
        if let viewedVersion {
            Text("Viewing \(viewedVersion.id) · read-only")
                .font(.system(size: 13))
                .foregroundColor(textColor)
                .fixedSize()
            Text("•")
                .foregroundColor(.gray)
            Button("Back to current") {
                showCurrentVersion()
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .fixedSize()
            .accessibilityIdentifier("backToCurrentVersionButton")
            .foregroundColor(isHoveringBackToCurrent ? textHoverColor : textColor)
            .onHover { hovering in
                isHoveringBackToCurrent = hovering
                hoverCursor(hovering)
            }
        }
        if !urls.isEmpty {
            if separatorBefore(1) {
                Text("•")
                    .foregroundColor(.gray)
            }
            voiceNoteControls(urls, textColor: textColor, textHoverColor: textHoverColor)
        }
        if let status = transcriptionStatus ?? runningReview.map({ "\($0.reviewerName) is reading \($0.versionId)…" }) {
            if separatorBefore(2) {
                Text("•")
                    .foregroundColor(.gray)
            }
            Text(status)
                .font(.system(size: 13))
                .foregroundColor(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 280, alignment: .leading)
                .help(status)
        }
    }

    /// The player while one of `urls` is loaded; otherwise "Play voice note", or "2 voice notes"
    /// opening a menu to choose one.
    @ViewBuilder
    private func voiceNoteControls(_ urls: [URL], textColor: Color, textHoverColor: Color) -> some View {
        if let loaded = voicePlayer.url, let index = urls.firstIndex(of: loaded) {
            if urls.count > 1 {
                voiceNotesMenuButton(title: "\(index + 1)/\(urls.count)", textColor: textColor, textHoverColor: textHoverColor)
            }
            VoiceNotePlayerBar(player: voicePlayer, textColor: textColor, textHoverColor: textHoverColor) {
                voicePlayer.stop()
            }
            .fixedSize()
        } else if urls.count == 1, let url = urls.first {
            Button(action: {
                toggleVoiceNote(url)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                    Text("Play voice note")
                        .font(.system(size: 13))
                }
                .foregroundColor(isHoveringPlayVoiceNote ? textHoverColor : textColor)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityIdentifier("playVoiceNoteButton")
            .onHover { hovering in
                isHoveringPlayVoiceNote = hovering
                hoverCursor(hovering)
            }
        } else {
            voiceNotesMenuButton(title: "\(urls.count) voice notes", systemImage: "play.fill", textColor: textColor, textHoverColor: textHoverColor)
        }
    }

    private func voiceNotesMenuButton(title: String, systemImage: String? = nil, textColor: Color, textHoverColor: Color) -> some View {
        Button(action: {
            toggleBarMenu(.voiceNotes)
        }) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10))
                }
                Text(title)
                    .font(.system(size: 13).monospacedDigit())
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
            }
            .foregroundColor(isHoveringPlayVoiceNote || openBarMenu == .voiceNotes ? textHoverColor : textColor)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Choose voice note")
        .accessibilityIdentifier("playVoiceNotesMenu")
        .onHover { hovering in
            isHoveringPlayVoiceNote = hovering
            hoverCursor(hovering)
        }
        .barMenuAnchor(.voiceNotes)
    }

    /// Microphone next to the video camera; records an audio-only voice note.
    private func voiceNoteButton(textColor: Color, textHoverColor: Color) -> some View {
        Button(action: {
            toggleVoiceNoteRecording()
        }) {
            Group {
                if isRequestingMicrophone {
                    ProgressView()
                        .controlSize(.small)
                        .tint(isHoveringVoiceNoteButton ? textHoverColor : textColor)
                } else {
                    Image(systemName: "mic.fill")
                        .foregroundColor(isHoveringVoiceNoteButton ? textHoverColor : textColor)
                }
            }
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Record voice note")
        .accessibilityIdentifier("recordVoiceNoteButton")
        .onHover { hovering in
            isHoveringVoiceNoteButton = hovering
            hoverCursor(hovering)
        }
        .barMenuAnchor(.item(.recordVoiceNote))
    }

    /// `● 3:42 ▁▃▅▂ Stop • Discard`, shown in place of the utility buttons while recording.
    private func voiceNoteRecordingBar(textColor: Color, textHoverColor: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
            Text(voiceRecorder.elapsed.clockString)
                .font(.system(size: 13).monospacedDigit())
                .foregroundColor(textColor)
                .accessibilityLabel("Recording, \(voiceRecorder.elapsed.clockString)")
            LevelMeter(levels: voiceRecorder.levels, color: textColor)
                .accessibilityHidden(true)
            Text("•")
                .foregroundColor(.gray)
            Button("Stop") {
                stopVoiceNote()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop and save voice note")
            .accessibilityIdentifier("stopVoiceNoteButton")
            .foregroundColor(isHoveringStopVoiceNote ? textHoverColor : textColor)
            .onHover { hovering in
                isHoveringStopVoiceNote = hovering
                hoverCursor(hovering)
            }
            Text("•")
                .foregroundColor(.gray)
            Button("Discard") {
                voiceRecorder.discard()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard voice note")
            .accessibilityIdentifier("discardVoiceNoteButton")
            .foregroundColor(isHoveringDiscardVoiceNote ? textHoverColor : textColor)
            .onHover { hovering in
                isHoveringDiscardVoiceNote = hovering
                hoverCursor(hovering)
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func historyBadges(for entry: HumanEntry) -> some View {
        HStack(spacing: 4) {
            if entry.hasVoiceNote {
                Image(systemName: "waveform")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            if entry.versionCount > 1 {
                Text("v\(entry.versionCount)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.secondary.opacity(0.4), lineWidth: 0.5)
                    )
            }
        }
        .accessibilityHidden(true)
    }

    private func backgroundColor(for entry: HumanEntry) -> Color {
        if entry.id == selectedEntryId {
            return Color.gray.opacity(0.1)  // More subtle selection highlight
        } else if entry.id == hoveredEntryId {
            return Color.gray.opacity(0.05)  // Even more subtle hover state
        } else {
            return Color.clear
        }
    }
    
    private func updatePreviewText(for entry: HumanEntry) {
        if entry.entryType == .video {
            if let index = entries.firstIndex(where: { $0.id == entry.id }),
               let videoFilename = resolvedVideoFilename(for: entry) {
                entries[index].previewText = videoPreviewText(for: videoFilename)
            }
            return
        }

        // A locked note never gets a preview (it would leak its first words into the sidebar).
        guard !entry.isLocked else { return }

        let documentsDirectory = getDocumentsDirectory()
        let fileURL = documentsDirectory.appendingPathComponent(entry.filename)
        
        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let preview = content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let truncated = preview.isEmpty ? "" : (preview.count > 30 ? String(preview.prefix(30)) + "..." : preview)
            
            // Find and update the entry in the entries array
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index].previewText = truncated
            }
        } catch {
            print("Error updating preview text: \(error)")
        }
    }
    
    /// Writes `text` (always the current version) to the entry's top-level file.
    @discardableResult
    private func saveEntry(entry: HumanEntry) -> Bool {
        guard entry.entryType == .text else {
            return false
        }
        if entry.isLocked {
            // Only the open note, and only encrypted: `text` is empty while it's closed.
            guard openLockedNoteId == entry.id else { return false }
            guard lockedNoteSavedText != text else { return true }
            do {
                try versionStore.saveCurrentText(text, for: entry.filename)
                lockedNoteSavedText = text
                return true
            } catch {
                print("Error saving locked entry: \(error)")
                return false
            }
        }

        let documentsDirectory = getDocumentsDirectory()
        let fileURL = documentsDirectory.appendingPathComponent(entry.filename)
        
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            print("Successfully saved entry: \(entry.filename)")
            updatePreviewText(for: entry)  // Update preview after saving
            return true
        } catch {
            print("Error saving entry: \(error)")
            return false
        }
    }
    
    private func loadEntry(entry: HumanEntry) {
        resetVersionState(for: entry)
        closeLockedNote()
        if let videoFilename = resolvedVideoFilename(for: entry) {
            // Load video entry
            let videoURL = getVideoURL(for: videoFilename)
            let thumbnailURL = getVideoThumbnailURL(for: videoFilename)
            let transcriptURL = getVideoTranscriptURL(for: videoFilename)
            historyDebug("LOAD VIDEO \(debugEntrySummary(entry)) resolvedVideoPath=\(videoURL.path) videoExists=\(fileManager.fileExists(atPath: videoURL.path)) thumbnailPath=\(thumbnailURL.path) thumbnailExists=\(fileManager.fileExists(atPath: thumbnailURL.path))")
            text = ""
            didCopyTranscript = false
            selectedVideoHasTranscript = fileManager.fileExists(atPath: transcriptURL.path)
            if fileManager.fileExists(atPath: videoURL.path) {
                currentVideoURL = videoURL
                print("Successfully loaded video entry: \(videoFilename)")
            } else {
                print("Video file missing for entry: \(videoFilename)")
            }
        } else {
            // Load text entry
            historyDebug("LOAD TEXT \(debugEntrySummary(entry))")
            currentVideoURL = nil
            selectedVideoHasTranscript = false
            didCopyTranscript = false
            if entry.isLocked {
                // Decrypted into memory only, and only while locked notes are open.
                let store = versionStore
                guard store.cipher != nil else {
                    text = ""
                    return
                }
                do {
                    reconcileLeftoverPlainFiles(of: entry, in: store)
                    let rawText = try store.currentText(for: entry.filename)
                    let loaded = String(rawText.drop(while: { $0 == "\n" }))
                    lockedNoteSavedText = loaded
                    openLockedNoteId = entry.id
                    text = loaded
                } catch {
                    text = ""
                    showStatus(error.localizedDescription, for: entry.id)
                }
                return
            }
            let documentsDirectory = getDocumentsDirectory()
            let fileURL = documentsDirectory.appendingPathComponent(entry.filename)

            do {
                if fileManager.fileExists(atPath: fileURL.path) {
                    let rawText = try String(contentsOf: fileURL, encoding: .utf8)
                    // Strip legacy leading newlines from older entries
                    text = String(rawText.drop(while: { $0 == "\n" }))
                    print("Successfully loaded entry: \(entry.filename)")
                }
            } catch {
                print("Error loading entry: \(error)")
            }
        }
    }
    
    private func createNewEntry() {
        let newEntry = HumanEntry.createNew()
        entries.insert(newEntry, at: 0) // Add to the beginning
        selectedEntryId = newEntry.id
        currentVideoURL = nil
        selectedVideoHasTranscript = false
        didCopyTranscript = false
        closeLockedNote()
        resetVersionState(for: nil)
        historyDebug("NEW ENTRY created \(debugEntrySummary(newEntry))")
        logEntriesOrder("createNewEntry")

        // If this is the first entry (entries was empty before adding this one)
        if entries.count == 1 {
            if let welcomeMessage = Self.welcomeMessage() {
                text = welcomeMessage
            }
            // Save the welcome message immediately
            saveEntry(entry: newEntry)
            // Update the preview text
            updatePreviewText(for: newEntry)
        } else {
            text = ""
            // Randomize placeholder text for new entry
            placeholderText = placeholderOptions.randomElement() ?? "Begin writing"
            // Save the empty entry
            saveEntry(entry: newEntry)
        }
    }
    
    /// The welcome text from default.md.
    private static func welcomeMessage() -> String? {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Settings › About › Welcome entry: a new entry holding the welcome text.
    private func showWelcomeEntry() {
        guard !isPreparingVideoRecording, !showingVideoRecording, !voiceRecorder.isRecording,
              let welcomeMessage = Self.welcomeMessage() else { return }
        createNewEntry()
        guard let entry = entries.first(where: { $0.id == selectedEntryId }) else { return }
        text = welcomeMessage
        saveEntry(entry: entry)
        updatePreviewText(for: entry)
    }

    private func saveVideoEntry(from tempURL: URL, transcript: String?) {
        let replacementEntry = selectedEntryId
            .flatMap { id in entries.first(where: { $0.id == id }) }
            .flatMap { entry -> HumanEntry? in
                guard entry.entryType == .text, !entry.isLocked else { return nil }
                guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                // An entry with versions or a voice note keeps them; the video gets its own entry.
                guard entryManifest?.isInteresting != true else { return nil }
                return entry
            }

        let videoEntry: HumanEntry
        if let replacementEntry {
            let videoFilename = replacementEntry.filename.replacingOccurrences(of: ".md", with: ".mov")
            videoEntry = HumanEntry(
                id: replacementEntry.id,
                date: replacementEntry.date,
                filename: replacementEntry.filename,
                previewText: previewTextFromTranscript(transcript),
                entryType: .video,
                videoFilename: videoFilename
            )
        } else {
            let newEntry = HumanEntry.createVideoEntry()
            videoEntry = HumanEntry(
                id: newEntry.id,
                date: newEntry.date,
                filename: newEntry.filename,
                previewText: previewTextFromTranscript(transcript),
                entryType: .video,
                videoFilename: newEntry.videoFilename
            )
        }

        // Get the documents directory
        let documentsDirectory = getDocumentsDirectory()

        // Save the video file
        if let videoFilename = videoEntry.videoFilename {
            do {
                let videoEntryDirectory = try ensureVideoEntryDirectoryExists(for: videoFilename)
                let videoDestURL = videoEntryDirectory.appendingPathComponent(videoFilename)
                let transcriptURL = videoEntryDirectory.appendingPathComponent("transcript.md")
                let cleanedTranscript = transcript?.trimmingCharacters(in: .whitespacesAndNewlines)

                // Copy the video file from temp location to documents directory
                if fileManager.fileExists(atPath: videoDestURL.path) {
                    try fileManager.removeItem(at: videoDestURL)
                }
                try fileManager.copyItem(at: tempURL, to: videoDestURL)
                print("Successfully saved video: \(videoFilename)")

                if let thumbnailImage = generateVideoThumbnail(from: videoDestURL) {
                    persistThumbnail(thumbnailImage, for: videoFilename)
                    print("Successfully saved thumbnail for video: \(videoFilename)")
                } else {
                    print("Could not generate thumbnail for video: \(videoFilename)")
                }

                // Create the metadata file
                let metadataURL = documentsDirectory.appendingPathComponent(videoEntry.filename)
                let metadataContent = "Video Entry"
                try metadataContent.write(to: metadataURL, atomically: true, encoding: .utf8)

                if let cleanedTranscript, !cleanedTranscript.isEmpty {
                    try cleanedTranscript.write(to: transcriptURL, atomically: true, encoding: .utf8)
                    print("Successfully saved transcript for video: \(videoFilename)")
                } else if fileManager.fileExists(atPath: transcriptURL.path) {
                    try fileManager.removeItem(at: transcriptURL)
                }

                let selectNewVideoEntry = {
                    if let existingIndex = self.entries.firstIndex(where: { $0.id == videoEntry.id }) {
                        self.entries[existingIndex] = videoEntry
                    } else {
                        self.entries.insert(videoEntry, at: 0)
                    }
                    self.entries.sort { self.isEntryNewer($0, than: $1) }
                    guard let insertedEntry = self.entries.first(where: { $0.id == videoEntry.id }) else {
                        print("Could not find saved video entry in entries array")
                        return
                    }
                    self.selectedEntryId = insertedEntry.id
                    self.resetVersionState(for: insertedEntry)
                    self.currentVideoURL = videoDestURL
                    self.text = ""
                    self.didCopyTranscript = false
                    self.selectedVideoHasTranscript = (cleanedTranscript?.isEmpty == false)
                    print("Successfully loaded new video entry: \(videoFilename)")
                    self.historyDebug("VIDEO SAVE selected \(self.debugEntrySummary(insertedEntry)) videoPath=\(videoDestURL.path)")
                    self.logEntriesOrder("saveVideoEntry")
                }
                
                if Thread.isMainThread {
                    selectNewVideoEntry()
                } else {
                    DispatchQueue.main.async {
                        selectNewVideoEntry()
                    }
                }

                if TranscriptionEngine.current == .hex {
                    transcribeWithHex(videoURL: videoDestURL, entryId: videoEntry.id)
                }

                if replacementEntry != nil {
                    print("Successfully replaced empty text entry with video entry")
                } else {
                    print("Successfully created video entry")
                }
            } catch {
                print("Error saving video entry: \(error)")
            }
        }
    }

    /// Replaces the saved transcript with Hex's once it finishes. On failure the live Apple
    /// transcript (if any) stays, and the reason shows briefly in the bottom bar.
    /// `videoURL` is where the recording was saved; the transcript goes next to it, and next to
    /// its copy if the entries folder was moved or copied while Hex was working.
    private func transcribeWithHex(videoURL: URL, entryId: UUID) {
        transcriptionStatuses[entryId] = "Transcribing with Hex…"
        Task {
            do {
                let transcript = try await HexTranscriber.transcribe(mediaURL: videoURL)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !transcript.isEmpty && saveHexTranscript(transcript, forRecordingAt: videoURL) {
                    if let index = entries.firstIndex(where: { $0.id == entryId }) {
                        entries[index].previewText = previewTextFromTranscript(transcript)
                    }
                    if selectedEntryId == entryId {
                        selectedVideoHasTranscript = true
                        didCopyTranscript = false
                    }
                }
                transcriptionStatuses[entryId] = nil
            } catch {
                let message = "Hex: \(error.localizedDescription)"
                transcriptionStatuses[entryId] = message
                try? await Task.sleep(for: .seconds(6))
                if transcriptionStatuses[entryId] == message {
                    transcriptionStatuses[entryId] = nil
                }
            }
        }
    }

    /// Writes `transcript` into every folder that still holds the recording: where it was saved
    /// and, after a folder move/copy, its counterpart in the current entries folder. Write
    /// failures are logged. Returns whether any copy was written.
    private func saveHexTranscript(_ transcript: String, forRecordingAt videoURL: URL) -> Bool {
        let videoFilename = videoURL.lastPathComponent
        var directories = [videoURL.deletingLastPathComponent()]
        let currentDirectory = getVideoEntryDirectory(for: videoFilename)
        if !EntryStorage.isSameFolder(currentDirectory, directories[0]) {
            directories.append(currentDirectory)
        }
        var saved = false
        for directory in directories
        where fileManager.fileExists(atPath: directory.appendingPathComponent(videoFilename).path) {
            let transcriptURL = directory.appendingPathComponent("transcript.md")
            do {
                try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
                saved = true
            } catch {
                print("Hex: couldn't save transcript to \(transcriptURL.path): \(error)")
            }
        }
        if !saved {
            print("Hex: transcript not saved; the recording \(videoFilename) is no longer where it was saved or in the entries folder")
        }
        return saved
    }

    private func deleteEntry(entry: HumanEntry) {
        // A transfer in progress would copy the entry back into the new folder.
        guard !storage.isTransferring else {
            NSSound.beep()
            return
        }
        // Delete the file from the filesystem (`.fwlock` for a locked note)
        let documentsDirectory = getDocumentsDirectory()
        let plainURL = documentsDirectory.appendingPathComponent(entry.filename)
        let lockedURL = versionStore.lockedEntryFileURL(for: entry.filename)
        // A review still running would write notes and a summary for an entry that's gone.
        reviews.stopReviews(of: entry.filename, in: documentsDirectory)

        do {
            if entry.isLocked {
                try fileManager.removeItem(at: lockedURL)
                // A plain copy left behind by an interrupted lock goes too.
                try? fileManager.removeItem(at: plainURL)
                if openLockedNoteId == entry.id { closeLockedNote() }
            } else {
                try fileManager.removeItem(at: plainURL)
            }
            print("Successfully deleted file: \(entry.filename)")

            // If this is a video entry, also delete the video file
            if let videoFilename = resolvedVideoFilename(for: entry) {
                deleteVideoAssets(for: videoFilename)
                print("Successfully deleted video assets: \(videoFilename)")
            }

            // Sealed versions and voice notes
            do {
                try versionStore.deleteEntryDirectory(for: entry.filename)
            } catch {
                print("Error deleting versions of \(entry.filename): \(error)")
            }

            // Remove the entry from the entries array
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries.remove(at: index)
                historyDebug("DELETE ENTRY removed \(debugEntrySummary(entry))")
                logEntriesOrder("deleteEntry")

                // If the deleted entry was selected, select the first entry or create a new one
                if selectedEntryId == entry.id {
                    if let firstEntry = entries.first {
                        selectedEntryId = firstEntry.id
                        loadEntry(entry: firstEntry)
                    } else {
                        createNewEntry()
                    }
                }
            }
        } catch {
            print("Error deleting file: \(error)")
        }
    }
    
    // Extract a title from entry content for PDF export
    private func extractTitleFromContent(_ content: String, date: String) -> String {
        // Clean up content by removing leading/trailing whitespace and newlines
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // If content is empty, just use the date
        if trimmedContent.isEmpty {
            return "Entry \(date)"
        }
        
        // Split content into words, ignoring newlines and removing punctuation
        let words = trimmedContent
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { word in
                word.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'()[]{}<>"))
                    .lowercased()
            }
            .filter { !$0.isEmpty }
        
        // If we have at least 4 words, use them
        if words.count >= 4 {
            return "\(words[0])-\(words[1])-\(words[2])-\(words[3])"
        }
        
        // If we have fewer than 4 words, use what we have
        if !words.isEmpty {
            return words.joined(separator: "-")
        }
        
        // Fallback to date if no words found
        return "Entry \(date)"
    }
    
    private func exportEntryAsPDF(entry: HumanEntry) {
        // First make sure the current entry is saved
        if selectedEntryId == entry.id {
            saveEntry(entry: entry)
        }
        
        // Get entry content (a locked note only while it's open; the PDF is a plain copy the user asked for)
        if entry.isLocked && !noteLock.isUnlocked {
            showStatus("Open the locked note before exporting it.", for: selectedEntryId)
            return
        }

        do {
            // Read the content of the entry
            let entryContent = try versionStore.currentText(for: entry.filename)
            
            // Extract a title from the entry content and add .pdf extension
            let suggestedFilename = extractTitleFromContent(entryContent, date: entry.date) + ".pdf"
            
            // Create save panel
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [UTType.pdf]
            savePanel.nameFieldStringValue = suggestedFilename
            savePanel.isExtensionHidden = false  // Make sure extension is visible
            
            // Show save dialog
            if savePanel.runModal() == .OK, let url = savePanel.url {
                // Create PDF data
                if let pdfData = createPDFFromText(text: entryContent) {
                    try pdfData.write(to: url)
                    print("Successfully exported PDF to: \(url.path)")
                }
            }
        } catch {
            print("Error in PDF export: \(error)")
        }
    }
    
    private func createPDFFromText(text: String) -> Data? {
        // Letter size page dimensions
        let pageWidth: CGFloat = 612.0  // 8.5 x 72
        let pageHeight: CGFloat = 792.0 // 11 x 72
        let margin: CGFloat = 72.0      // 1-inch margins
        
        // Calculate content area
        let contentRect = CGRect(
            x: margin,
            y: margin,
            width: pageWidth - (margin * 2),
            height: pageHeight - (margin * 2)
        )
        
        // Create PDF data container
        let pdfData = NSMutableData()
        
        // Configure text formatting attributes
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineHeight
        
        let font = NSFont(name: selectedFont, size: fontSize) ?? .systemFont(ofSize: fontSize)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1.0),
            .paragraphStyle: paragraphStyle
        ]
        
        // Trim the initial newlines before creating the PDF
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Create the attributed string with formatting
        let attributedString = NSAttributedString(string: trimmedText, attributes: textAttributes)
        
        // Create a Core Text framesetter for text layout
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        
        // Create a PDF context with the data consumer
        guard let pdfContext = CGContext(consumer: CGDataConsumer(data: pdfData as CFMutableData)!, mediaBox: nil, nil) else {
            print("Failed to create PDF context")
            return nil
        }
        
        // Track position within text
        var currentRange = CFRange(location: 0, length: 0)
        var pageIndex = 0
        
        // Create a path for the text frame
        let framePath = CGMutablePath()
        framePath.addRect(contentRect)
        
        // Continue creating pages until all text is processed
        while currentRange.location < attributedString.length {
            // Begin a new PDF page
            pdfContext.beginPage(mediaBox: nil)
            
            // Fill the page with white background
            pdfContext.setFillColor(NSColor.white.cgColor)
            pdfContext.fill(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
            
            // Create a frame for this page's text
            let frame = CTFramesetterCreateFrame(
                framesetter, 
                currentRange, 
                framePath, 
                nil
            )
            
            // Draw the text frame
            CTFrameDraw(frame, pdfContext)
            
            // Get the range of text that was actually displayed in this frame
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            
            // Move to the next block of text for the next page
            currentRange.location += visibleRange.length
            
            // Finish the page
            pdfContext.endPage()
            pageIndex += 1
            
            // Safety check - don't allow infinite loops
            if pageIndex > 1000 {
                print("Safety limit reached - stopping PDF generation")
                break
            }
        }
        
        // Finalize the PDF document
        pdfContext.closePDF()
        
        return pdfData as Data
    }
}

// Helper function to calculate line height
func getLineHeight(font: NSFont) -> CGFloat {
    return font.ascender - font.descender + font.leading
}

// Add helper extension to find NSTextView
extension NSView {
    func findTextView() -> NSView? {
        if self is NSTextView {
            return self
        }
        for subview in subviews {
            if let textView = subview.findTextView() {
                return textView
            }
        }
        return nil
    }
}

// Add helper extension for finding subviews of a specific type
extension NSView {
    func findSubview<T: NSView>(ofType type: T.Type) -> T? {
        if let typedSelf = self as? T {
            return typedSelf
        }
        for subview in subviews {
            if let found = subview.findSubview(ofType: type) {
                return found
            }
        }
        return nil
    }
}

#Preview {
    ContentView()
}

/// Small bar meter of recent input levels.
private struct LevelMeter: View {
    let levels: [Float]
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(color.opacity(0.7))
                    .frame(width: 2, height: 2 + CGFloat(level) * 12)
            }
        }
        .frame(height: 14)
        .animation(.linear(duration: 0.08), value: levels)
    }
}

// MARK: - Reviews

extension ContentView {
    private var reviewerProfiles: [ReviewerProfile] { ReviewerStore.decode(reviewersJSON) }

    private var annotationStore: AnnotationStore { AnnotationStore(versionStore: versionStore) }

    /// The review running on the selected entry, if any.
    private var runningReview: ReviewActivity? {
        selectedTextEntry.flatMap { reviews.activeRuns[$0.filename] }
    }

    /// Changes when another entry, version or folder is on screen: annotations are reloaded then.
    private var annotationContext: String {
        [selectedTextEntry?.filename ?? "", entryManifest?.current ?? "", storage.rootURL.path].joined(separator: "|")
    }

    /// Active notes of the version on screen, coloured per kind of note.
    private var editorHighlights: [EditorHighlight] {
        guard let version = displayedVersion, annotationsEntryId == selectedEntryId, !annotations.isEmpty else { return [] }
        let profiles = Dictionary(reviewerProfiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return annotations
            .filter { $0.versionId == version.id && $0.status == .active }
            .map { annotation in
                let kind = annotation.resolvedKind
                let reviewer = profiles[annotation.reviewerId]?.name ?? annotation.reviewerId.capitalized
                return EditorHighlight(
                    id: annotation.id,
                    range: annotation.anchor.range,
                    color: kind.highlightColor,
                    comment: annotation.comment,
                    title: "\(kind.title) · \(reviewer)",
                    titleColor: kind.nsColor,
                    underlineColor: kind.underlineColor
                )
            }
    }

    /// Reads `annotations.json` for the selected entry and re-anchors the current version's notes
    /// to the text in the editor (saving any offsets or statuses that changed).
    private func reloadAnnotations() {
        // Anchors moved by the last edits belong to the text they were typed in; save them first.
        flushAnnotationAnchors()
        guard let entry = selectedTextEntry else {
            annotations = []
            annotationsEntryId = nil
            return
        }
        var loaded: [Annotation]
        do {
            loaded = try annotationStore.load(for: entry.filename)
        } catch {
            print("Reviews: unreadable annotations for \(entry.filename): \(error)")
            loaded = []
        }
        if let current = entryManifest?.current {
            let anchored = AnnotationAnchoring.reanchor(loaded, versionId: current, in: text)
            if anchored != loaded {
                persistAnchors(anchored, entryFilename: entry.filename)
            }
            loaded = anchored
        }
        annotations = loaded
        annotationsEntryId = entry.id
        annotationsBaseText = text
    }

    /// Moves the current version's notes along with typing (and orphans those whose quote is gone).
    private func followAnnotationEdits() {
        guard viewedVersion == nil, let entry = selectedTextEntry, annotationsEntryId == entry.id,
              let current = entryManifest?.current else { return }
        let old = annotationsBaseText
        annotationsBaseText = text
        guard annotations.contains(where: { $0.versionId == current && $0.status != .dismissed }) else { return }
        let moved = AnnotationAnchoring.followEdit(annotations, versionId: current, from: old, to: text)
        guard moved != annotations else { return }
        annotations = moved
        pendingAnchors = PendingAnchors(annotations: moved, entryFilename: entry.filename, store: annotationStore)
        annotationSaveTask?.cancel()
        annotationSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            flushAnnotationAnchors()
        }
    }

    /// Writes the anchors typing moved, now, into the folder and entry they were typed in.
    /// Runs before anything that reloads the notes or seals the text (switching entry, version
    /// or folder, New Version, closing the window, quitting).
    private func flushAnnotationAnchors() {
        annotationSaveTask?.cancel()
        annotationSaveTask = nil
        guard let pending = pendingAnchors else { return }
        pendingAnchors = nil
        persistAnchors(pending.annotations, entryFilename: pending.entryFilename, in: pending.store)
    }

    /// Writes anchors/statuses into the file, merging by id so notes a running review added meanwhile stay.
    private func persistAnchors(_ updated: [Annotation], entryFilename: String, in store: AnnotationStore? = nil) {
        let byId = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        do {
            try (store ?? annotationStore).update(for: entryFilename) { stored in
                for index in stored.indices {
                    guard stored[index].status != .dismissed, let mine = byId[stored[index].id] else { continue }
                    stored[index].anchor = mine.anchor
                    stored[index].status = mine.status
                }
            }
        } catch {
            print("Reviews: couldn't save annotation anchors: \(error)")
        }
    }

    private func dismissAnnotation(id: String) {
        guard let entry = selectedTextEntry else { return }
        do {
            try annotationStore.update(for: entry.filename) { stored in
                if let index = stored.firstIndex(where: { $0.id == id }) {
                    stored[index].status = .dismissed
                }
            }
            if let index = annotations.firstIndex(where: { $0.id == id }) {
                annotations[index].status = .dismissed
            }
        } catch {
            showStatus("Couldn't dismiss the note: \(error.localizedDescription)")
        }
    }

    /// Removes every note on the version on screen.
    private func clearReview() {
        guard let entry = selectedTextEntry, let version = displayedVersion else { return }
        do {
            try annotationStore.update(for: entry.filename) { stored in
                stored.removeAll { $0.versionId == version.id }
            }
            annotations.removeAll { $0.versionId == version.id }
        } catch {
            showStatus("Couldn't clear the review: \(error.localizedDescription)")
        }
    }

    // MARK: Running

    private func openReviewerSettings() {
        UserDefaults.standard.set("agents", forKey: "settingsPane")
        if let window = SettingsWindow.window {
            window.makeKeyAndOrderFront(nil)
        } else {
            SettingsWindow.toggle(openSettings)
        }
    }

    private func openReviewMenu() {
        guard selectedTextEntry != nil, !voiceRecorder.isRecording, !showingVideoRecording else {
            NSSound.beep()
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            bottomNavOpacity = 1.0
        }
        if openBarMenu != .review {
            Task { await reviews.refreshCredentials() }
        }
        toggleBarMenu(.review)
    }

    /// Reviews the version on screen with `profile`.
    private func startReview(_ profile: ReviewerProfile) {
        guard let entry = selectedTextEntry, let version = displayedVersion else { return }
        if version.id == entryManifest?.current {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                showStatus("Write something first, then ask for a review.")
                return
            }
            // Reviewers read the file; make sure it's what's on screen.
            guard saveEntry(entry: entry) else {
                showStatus("Couldn't save this entry, so it wasn't reviewed.")
                return
            }
        }
        runReviews([profile], on: entry, versionId: version.id)
    }

    /// Runs reviewers one after another (one review per entry at a time).
    private func runReviews(_ profiles: [ReviewerProfile], on entry: HumanEntry, versionId: String) {
        Task {
            for profile in profiles {
                do {
                    let outcome = try await reviews.review(entryFilename: entry.filename, entryId: entry.id, versionId: versionId, profile: profile)
                    let notes = outcome.added == 1 ? "1 note" : "\(outcome.added) notes"
                    showStatus(outcome.added == 0 ? "\(profile.name) had nothing to add." : "\(profile.name) left \(notes) on \(versionId).", for: entry.id)
                } catch ReviewError.stopped(let reason) {
                    // The rest of the queue would run on an entry that's gone or in another folder.
                    if reason == .folderChanged {
                        showStatus("\(profile.name): \(ReviewError.stopped(reason).localizedDescription)")
                    }
                    return
                } catch {
                    showStatus("\(profile.name): \(error.localizedDescription)", for: entry.id)
                }
            }
        }
    }

    // MARK: Views

    private func reviewButton(textColor: Color, textHoverColor: Color) -> some View {
        Button(action: openReviewMenu) {
            Group {
                if runningReview != nil {
                    ProgressView()
                        .controlSize(.small)
                        .tint(isHoveringReview ? textHoverColor : textColor)
                } else {
                    Image(systemName: "sparkles")
                        .foregroundColor(isHoveringReview || openBarMenu == .review ? textHoverColor : textColor)
                }
            }
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(runningReview == nil ? "Review with" : "Review running")
        .accessibilityIdentifier("reviewButton")
        .help("Review with…")
        .onHover { hovering in
            isHoveringReview = hovering
            hoverCursor(hovering)
        }
        .barMenuAnchor(.item(.review))
    }

    /// Review with…: reviewers, the latest summary for the version, Clear Review, settings.
    private var reviewMenuContent: BarMenuContent {
        let version = displayedVersion
        let versionNotes = annotations.filter { $0.versionId == version?.id && $0.status != .dismissed }
        let summary = selectedTextEntry.flatMap { entry in
            version.flatMap { annotationStore.latestSummary(versionId: $0.id, entryFilename: entry.filename) }
        }
        let configured = reviews.credentialStates.values.contains(where: \.isConfigured)
        var footer: String?
        if let runningReview {
            footer = "\(runningReview.reviewerName) is reading \(runningReview.versionId)…"
        } else if !configured && !reviews.credentialStates.isEmpty {
            footer = "Add a Claude key or sign in to ChatGPT first."
        }
        var sections = [
            BarMenuSection(
                id: "reviewers",
                header: "Review \(version?.id ?? "v1") with",
                note: "Sends this entry's text to the reviewer's provider.",
                actions: reviewerProfiles.map { profile in
                    BarMenuAction(
                        id: "reviewWith-\(profile.id)",
                        title: profile.name,
                        dot: Color(nsColor: profile.color.nsColor),
                        isEnabled: runningReview == nil
                    ) { startReview(profile) }
                },
                footer: footer
            ),
        ]
        if let summary {
            sections.append(BarMenuSection(id: "summary", paragraph: summary))
        }
        sections.append(BarMenuSection(id: "legend", accessory: AnyView(
            AnnotationKindLegend(notes: versionNotes.filter { $0.status == .active })
        )))
        if !versionNotes.isEmpty {
            sections.append(BarMenuSection(id: "clear", actions: [
                BarMenuAction(
                    id: "clearReviewButton",
                    title: "Clear Review (\(versionNotes.count == 1 ? "1 note" : "\(versionNotes.count) notes"))"
                ) { clearReview() },
            ]))
        }
        sections.append(BarMenuSection(id: "settings", actions: [
            BarMenuAction(id: "reviewersAndModelsButton", title: "Reviewers & Models…") {
                openReviewerSettings()
            },
        ]))
        return BarMenuContent(width: 270, sections: sections)
    }
}

// MARK: - Bar menus

extension ContentView {
    /// What `kind` shows right now; nil when it has nothing to show (e.g. no text entry).
    private func barMenuContent(_ kind: BarMenuKind) -> BarMenuContent? {
        switch kind {
        case .versions:
            guard let manifest = entryManifest else { return nil }
            let versions = manifest.versions.reversed().map { version in
                BarMenuAction(
                    id: "versionRow-\(version.id)",
                    title: version.id,
                    detail: versionDetail(version, in: manifest),
                    isChecked: version.id == displayedVersion?.id
                ) { showVersion(version.id) }
            }
            return BarMenuContent(width: 270, sections: [
                BarMenuSection(id: "versions", actions: versions),
                BarMenuSection(id: "new", actions: [
                    BarMenuAction(
                        id: "newVersionButton",
                        title: "New Version",
                        detail: ShortcutStore.shortcut(for: .newVersion, in: shortcutsJSON)?.displayString
                    ) { createNewVersion() },
                ]),
            ])
        case .review:
            guard selectedTextEntry != nil else { return nil }
            return reviewMenuContent
        case .voiceNotes:
            let urls = displayedAudioURLs
            guard !urls.isEmpty else { return nil }
            return BarMenuContent(width: 220, sections: [
                BarMenuSection(
                    id: "notes",
                    header: "Voice notes on \(displayedVersion?.id ?? "v1")",
                    actions: urls.enumerated().map { index, url in
                        BarMenuAction(
                            id: "voiceNoteRow-\(index + 1)",
                            title: "Voice note \(index + 1)",
                            detail: index == urls.count - 1 ? "latest" : nil,
                            isChecked: voicePlayer.url == url
                        ) {
                            if voicePlayer.url != url { toggleVoiceNote(url) }
                        }
                    }
                ),
            ])
        case .videoPermission:
            var sections: [BarMenuSection] = []
            if let fallback = videoPermissionPopoverFallbackMessage {
                sections.append(BarMenuSection(id: "fallback", paragraph: fallback))
            }
            for item in videoPermissionPopoverItems {
                sections.append(BarMenuSection(id: "\(item.id)", paragraph: item.message, actions: [
                    BarMenuAction(id: "openSettings-\(item.id)", title: item.buttonLabel, trailingSymbol: "arrow.up.forward") {
                        openVideoPermissionSettings(item.settingsPane)
                    },
                ]))
            }
            return sections.isEmpty ? nil : BarMenuContent(width: 320, sections: sections)
        case .microphonePermission:
            return BarMenuContent(width: 320, sections: [
                BarMenuSection(
                    id: "microphone",
                    paragraph: "Hey, we need microphone permission to record voice notes.",
                    actions: [
                        BarMenuAction(id: "openMicrophoneSettings", title: "Open Microphone Settings", trailingSymbol: "arrow.up.forward") {
                            openVideoPermissionSettings("Privacy_Microphone")
                        },
                    ]
                ),
            ])
        case .overflow:
            let actions = barOverflow.filter(isBottomBarItemAvailable).map(overflowAction(for:))
            return actions.isEmpty ? nil : BarMenuContent(width: 250, sections: [BarMenuSection(id: "items", actions: actions)])
        }
    }

    /// Where `kind` hangs from: its control, else the "…" button, else the right of the bar.
    private func barMenuAnchors(_ kind: BarMenuKind) -> [BarMenuAnchor] {
        switch kind {
        case .versions: return [.item(.versions), .overflow]
        case .review: return [.item(.review), .overflow]
        case .voiceNotes: return [.voiceNotes]
        case .videoPermission: return [.item(.recordVideo), .overflow]
        case .microphonePermission: return [.item(.recordVoiceNote), .overflow]
        case .overflow: return [.overflow]
        }
    }

    private func showBarMenu(_ kind: BarMenuKind) {
        barMenuHighlight = nil
        withAnimation(.easeOut(duration: 0.15)) {
            openBarMenu = kind
            bottomNavOpacity = 1.0
        }
        installBarMenuKeyMonitor()
    }

    private func toggleBarMenu(_ kind: BarMenuKind) {
        if openBarMenu == kind {
            closeBarMenu()
        } else {
            showBarMenu(kind)
        }
    }

    /// Closes the open menu (only if it's `kind`, when given).
    private func closeBarMenu(_ kind: BarMenuKind? = nil) {
        guard let open = openBarMenu, kind == nil || kind == open else { return }
        withAnimation(.easeIn(duration: 0.15)) {
            openBarMenu = nil
        }
        barMenuHighlight = nil
        if let barMenuKeyMonitor {
            NSEvent.removeMonitor(barMenuKeyMonitor)
            self.barMenuKeyMonitor = nil
        }
    }

    private func chooseBarMenuAction(_ action: BarMenuAction) {
        guard action.isEnabled else { return }
        closeBarMenu()
        action.perform()
    }

    /// While a menu is open: Esc closes it, ↑/↓ move the highlight, ↩ chooses. Other keys
    /// (except ⌘ shortcuts) are swallowed, like a native menu, so nothing is typed behind it.
    private func installBarMenuKeyMonitor() {
        guard barMenuKeyMonitor == nil else { return }
        barMenuKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let kind = openBarMenu,
                  event.window?.identifier?.rawValue.contains("Settings") != true,
                  !event.modifierFlags.contains(.command) else { return event }
            guard let content = barMenuContent(kind) else {
                closeBarMenu()
                return event
            }
            switch event.keyCode {
            case 53: // Esc
                closeBarMenu()
            case 125: // ↓
                barMenuHighlight = content.action(after: barMenuHighlight, step: 1)?.id
            case 126: // ↑
                barMenuHighlight = content.action(after: barMenuHighlight, step: -1)?.id
            case 36, 76: // ↩, enter
                if let action = content.enabledActions.first(where: { $0.id == barMenuHighlight }) {
                    chooseBarMenuAction(action)
                }
            default:
                break
            }
            return nil
        }
    }

    /// The open menu above its control; a click anywhere outside it closes it.
    @ViewBuilder
    private func barMenuOverlay(_ anchors: [BarMenuAnchor: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            if let kind = openBarMenu,
               let content = barMenuContent(kind),
               let anchor = (barMenuAnchors(kind) + [.barRight]).lazy.compactMap({ anchors[$0] }).first {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { closeBarMenu() }
                    .accessibilityHidden(true)
                BarMenuPlacement(anchor: proxy[anchor]) {
                    BarMenuCard(
                        content: content,
                        isDark: colorScheme == .dark,
                        highlighted: $barMenuHighlight,
                        onChoose: chooseBarMenuAction
                    )
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                .id(kind)
            }
        }
    }

    // MARK: Overflow

    /// Bar items that move into "…" first when the bar is too narrow. Settings and the version
    /// menu always stay.
    private static let overflowOrder: [BottomBarItem] = [
        .fullscreen, .backspace, .newEntry, .timer, .recordVideo, .recordVoiceNote, .review, .lock, .history,
    ]

    private func overflowAction(for item: BottomBarItem) -> BarMenuAction {
        let command: AppCommand? = switch item {
        case .timer: .toggleTimer
        case .recordVideo: .recordVideo
        case .recordVoiceNote: .recordVoiceNote
        case .review: .reviewEntry
        case .backspace: .toggleBackspace
        case .newEntry: .newEntry
        case .history: .toggleHistory
        case .versions: .newVersion
        case .lock: .toggleNoteLock
        case .fullscreen, .settings: nil
        }
        let title = switch item {
        case .timer: timerIsRunning ? "Pause Timer" : "Start Timer"
        case .review: "Review with…"
        case .backspace: backspaceDisabled ? "Turn Backspace On" : "Turn Backspace Off"
        case .fullscreen: isFullscreen ? "Exit Fullscreen" : "Fullscreen"
        case .history: showingSidebar ? "Hide History" : "Show History"
        case .lock: selectedTextEntry?.isLocked == true ? "Unlock Note…" : "Lock Note"
        default: item.title
        }
        let detail = item == .timer ? timerButtonTitle : command.flatMap { ShortcutStore.shortcut(for: $0, in: shortcutsJSON)?.displayString }
        let isEnabled = item != .lock || (selectedTextEntry != nil && !storage.isTransferring)
        return BarMenuAction(id: "overflow-\(item.rawValue)", title: title, detail: detail, isEnabled: isEnabled) {
            switch item {
            case .fullscreen:
                NSApplication.shared.windows.first?.toggleFullScreen(nil)
            case .settings:
                SettingsWindow.toggle(openSettings)
            default:
                if let command { handle(command) }
            }
        }
    }

    private func overflowButton(items: [BottomBarItem], textColor: Color, textHoverColor: Color) -> some View {
        Button(action: {
            barOverflow = items
            toggleBarMenu(.overflow)
        }) {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 16, height: 14)
                .foregroundColor(isHoveringOverflow || openBarMenu == .overflow ? textHoverColor : textColor)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More")
        .accessibilityIdentifier("bottomBarOverflowButton")
        .help("More")
        .onHover { hovering in
            isHoveringOverflow = hovering
            hoverCursor(hovering)
        }
        // The open menu follows the bar as it gets wider or narrower.
        .onAppear { barOverflow = items }
        .onChange(of: items) { barOverflow = items }
        .onDisappear { closeBarMenu(.overflow) }
        .barMenuAnchor(.overflow)
    }
}

/// Annotation anchors moved by typing and not saved yet, with the folder and entry they belong to.
struct PendingAnchors {
    let annotations: [Annotation]
    let entryFilename: String
    let store: AnnotationStore
}
