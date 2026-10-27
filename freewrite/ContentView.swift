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
    @State private var showingVideoPermissionPopover = false
    @State private var videoPermissionPopoverItems: [VideoPermissionPopoverItem] = []
    @State private var videoPermissionPopoverFallbackMessage: String? = nil
    /// Saved manifest of the selected text entry; nil while it has a single version.
    @State private var entryManifest: EntryManifest? = nil
    /// A sealed version shown read-only in place of the current text (`text` is left alone).
    @State private var viewedVersion: EntryVersion? = nil
    @State private var viewedVersionText = ""
    @State private var showingVersionMenu = false
    @State private var isHoveringVersion = false
    @State private var isHoveringBackToCurrent = false
    @State private var isHoveringPlayVoiceNote = false
    @State private var voiceRecorder = VoiceNoteRecorder()
    @State private var voicePlayer = VoiceNotePlayer()
    @State private var isRequestingMicrophone = false
    @State private var isHoveringVoiceNoteButton = false
    @State private var isHoveringStopVoiceNote = false
    @State private var isHoveringDiscardVoiceNote = false
    @State private var showingMicrophonePermissionPopover = false
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
            let mdFiles = fileURLs.filter { $0.pathExtension == "md" }

            print("Found \(mdFiles.count) .md files")
            let manifests = versionStore.savedManifests()

            // Process each file
            let entriesWithDates = mdFiles.compactMap { fileURL -> (entry: HumanEntry, date: Date, content: String)? in
                let filename = fileURL.lastPathComponent
                print("Processing: \(filename)")

                // Only accept canonical entry filenames: [UUID]-[yyyy-MM-dd-HH-mm-ss].md
                guard let parsed = parseCanonicalEntryFilename(filename) else {
                    print("Skipping non-canonical entry filename: \(filename)")
                    return nil
                }
                let uuid = parsed.uuid
                let fileDate = parsed.timestamp

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
                $0.previewText.isEmpty
            }

            // Check if we have only one entry and it's the welcome message
            let hasOnlyWelcomeEntry = loadedEntries.count == 1 && entriesWithDates.first?.content.contains("Welcome to Freewrite.") == true

            // Now assign to the state variable
            entries = loadedEntries
            logEntriesOrder("loadExistingEntries")

            // Never open directly into video on startup; create a fresh text entry instead.
            if let latestEntry = entries.first, latestEntry.entryType == .video {
                print("Latest entry is video, creating new text entry for startup")
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
        case .backspace, .versions, .recordVoiceNote: return currentVideoURL == nil
        default: return true
        }
    }

    @ViewBuilder
    private func bottomBarGroup(_ items: [BottomBarItem], leading: Bool = false) -> some View {
        let visible = items.filter(isBottomBarItemAvailable)
        ForEach(Array(visible.enumerated()), id: \.element) { index, item in
            if index > 0 || leading {
                Text("•")
                    .foregroundColor(.gray)
            }
            bottomBarItemView(item)
        }
    }

    @ViewBuilder
    private func bottomBarItemView(_ item: BottomBarItem) -> some View {
        switch item {
        case .versions:
            versionsButton(textColor: textColor, textHoverColor: textHoverColor)
        case .recordVoiceNote:
            voiceNoteButton(textColor: textColor, textHoverColor: textHoverColor)
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
                .onAppear {
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
                .onDisappear {
                    if let scrollWheelMonitor {
                        NSEvent.removeMonitor(scrollWheelMonitor)
                        self.scrollWheelMonitor = nil
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
                .popover(
                    isPresented: $showingVideoPermissionPopover,
                    attachmentAnchor: .point(UnitPoint(x: 0.5, y: 0.0)),
                    arrowEdge: .top
                ) {
                    VStack(spacing: 0) {
                        if let fallbackMessage = videoPermissionPopoverFallbackMessage {
                            Text(fallbackMessage)
                                .font(.system(size: 14))
                                .foregroundColor(popoverTextColor)
                                .lineLimit(nil)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                    }

                        ForEach(videoPermissionPopoverItems) { item in
                            if item.id != videoPermissionPopoverItems.first?.id || videoPermissionPopoverFallbackMessage != nil {
                                Divider()
                            }

                            Button(action: {
                                showingVideoPermissionPopover = false
                                openVideoPermissionSettings(item.settingsPane)
                            }) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.message)
                                        .font(.system(size: 14))
                                        .lineLimit(nil)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)

                                    Text(item.buttonLabel)
                                        .font(.system(size: 12))
                                        .opacity(0.85)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(popoverTextColor)
                            .onHover { hovering in
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                        }
                    }
                    .frame(minWidth: 300, idealWidth: 320, maxWidth: 360)
                    .background(colorScheme == .light ? Color.white : Color.black)
                }
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
            if entry.entryType == .video {
                return (entry, resolvedVideoFilename(for: entry).map(getVideoTranscriptURL(for:)))
            }
            return (entry, getDocumentsDirectory().appendingPathComponent(entry.filename))
        }
        let store = versionStore
        Task {
            let index = await Task.detached(priority: .userInitiated) {
                PaletteIndex(sources.flatMap { source in
                    let current = PaletteDocument(
                        id: source.entry.id,
                        date: source.entry.date,
                        isVideo: source.entry.entryType == .video,
                        body: source.url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
                    )
                    guard source.entry.entryType == .text, source.entry.versionCount > 1 else { return [current] }
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
                })
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
        case .command(let command):
            handle(command)
        case .settings:
            SettingsWindow.toggle(openSettings)
        }
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
        showingVideoPermissionPopover = false
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
                self.showingVideoPermissionPopover = true
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
        guard let entry = selectedTextEntry, let manifest = entryManifest else { return }
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
        showingVersionMenu = false
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
        guard let entry = selectedTextEntry, !voiceRecorder.isRecording else { return }
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
        do {
            let manifest = try versionStore.sealCurrent(entryFilename: entry.filename)
            applyManifest(manifest, toEntry: entry.id)
            placeholderText = placeholderOptions.randomElement() ?? "Begin writing"
            text = ""
            updatePreviewText(for: entry)
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
        showingMicrophonePermissionPopover = false
        isRequestingMicrophone = true
        Task {
            let granted = await VoiceNoteRecorder.requestMicrophoneAccess()
            isRequestingMicrophone = false
            guard granted else {
                showingMicrophonePermissionPopover = true
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
        if let selected = selectedTextEntry,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (entryManifest?.versions.count ?? 1) > 1 {
            saveEntry(entry: selected)
            target = selected
        } else {
            if let selected = selectedTextEntry {
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
        let origin = versionStore
        Task {
            do {
                let transcript = try await engine.transcribe(fileURL: attachment.audioURL)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // The transcript goes next to the recording wherever it is now: still in the old
                // folder ("Just Switch"), moved, or copied (then both copies get it).
                let current = versionStore
                let candidates = current.root == origin.root ? [origin] : [current, origin]
                let holders = candidates.filter { store in
                    FileManager.default.fileExists(atPath: store.url(forRelativePath: attachment.audioPath, entryFilename: entryFilename).path)
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
                if store.root == current.root && selectedEntryId == entryId && currentVideoURL == nil {
                    text = appending(transcript, to: text)  // autosaved like typing
                } else {
                    let url = store.entryFileURL(for: entryFilename)
                    let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    try appending(transcript, to: existing).write(to: url, atomically: true, encoding: .utf8)
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
    
    var popoverBackgroundColor: Color {
        return colorScheme == .light ? Color(NSColor.controlBackgroundColor) : Color(NSColor.darkGray)
    }

    var popoverTextColor: Color {
        return colorScheme == .light ? Color.primary : Color.white
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

                if let viewedVersion, !isViewingVideoEntry {
                    versionBanner(for: viewedVersion, textColor: textColor, textHoverColor: textHoverColor)
                }
                
                VStack {
                    Spacer()
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
                            bottomBarGroup(bottomBarLayout.left, leading: isViewingVideoEntry ? (transcriptionStatus != nil || selectedVideoHasTranscript) : textEntryStatusVisible)
                        }
                        .padding(8)
                        .cornerRadius(6)
                        .onHover { hovering in
                            isHoveringBottomNav = hovering
                        }

                        Spacer()

                        HStack(spacing: 8) {
                            bottomBarGroup(bottomBarLayout.right)
                        }
                        .padding(8)
                        .cornerRadius(6)
                        .onHover { hovering in
                            isHoveringBottomNav = hovering
                        }
                        // While a voice note records, the bar turns into its controls.
                        .opacity(voiceRecorder.isRecording ? 0 : 1)
                        .allowsHitTesting(!voiceRecorder.isRecording)
                        .overlay(alignment: .trailing) {
                            if voiceRecorder.isRecording {
                                voiceNoteRecordingBar(textColor: textColor, textHoverColor: textHoverColor)
                            }
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
                                                Text(entry.previewText.isEmpty && entry.hasVoiceNote ? "Voice Note" : entry.previewText)
                                                    .font(.system(size: 13))
                                                    .lineLimit(1)
                                                    .foregroundColor(.primary)

                                                Spacer()

                                                if hoveredEntryId != entry.id {
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
                                .accessibilityLabel("\(entry.previewText.isEmpty ? (entry.hasVoiceNote ? "Voice note" : "Empty entry") : entry.previewText), \(entry.date)\(entry.versionCount > 1 ? ", \(entry.versionCount) versions" : "")")
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
            showingSidebar = false  // Hide sidebar by default
            timeRemaining = sessionMinutes * 60
            loadExistingEntries()
        }
        .onDisappear {
            WritingWindow.openCount -= 1
        }
        .onChange(of: storage.rootURL) {
            // The entries folder changed in Settings; show what's in the new one.
            currentVideoURL = nil
            resetVersionState(for: nil)
            loadExistingEntries()
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
            // Save current entry when text changes
            if let currentId = selectedEntryId,
               let currentEntry = entries.first(where: { $0.id == currentId }),
               currentEntry.entryType == .text {
                saveEntry(entry: currentEntry)
            }
        }
        .onReceive(timer) { _ in
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
                showingVersionMenu.toggle()
            }) {
                HStack(spacing: 3) {
                    Text(displayedVersion?.id ?? manifest.current)
                        .font(.system(size: 13).monospacedDigit())
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                }
                .foregroundColor(isHoveringVersion ? textHoverColor : textColor)
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
            .popover(isPresented: $showingVersionMenu, attachmentAnchor: .point(UnitPoint(x: 0.5, y: 0)), arrowEdge: .top) {
                versionMenu(manifest)
            }
        }
    }

    /// Fixed start of the left side for text entries: the current version's voice note and
    /// transient status (transcribing, errors).
    private var textEntryStatusVisible: Bool {
        transcriptionStatus != nil || (viewedVersion == nil && entryManifest?.currentVersion.flatMap(audioURL(for:)) != nil)
    }

    @ViewBuilder
    private func textEntryStatus(textColor: Color, textHoverColor: Color) -> some View {
        if viewedVersion == nil, let current = entryManifest?.currentVersion, !audioURLs(for: current).isEmpty {
            playVoiceNotes(audioURLs(for: current), textColor: textColor, textHoverColor: textHoverColor)
        }
        if let transcriptionStatus {
            Text(transcriptionStatus)
                .font(.system(size: 13))
                .foregroundColor(textColor)
                .lineLimit(1)
        }
    }

    private func versionMenu(_ manifest: EntryManifest) -> some View {
        VStack(spacing: 0) {
            ForEach(manifest.versions.reversed()) { version in
                Button(action: {
                    showingVersionMenu = false
                    showVersion(version.id)
                }) {
                    HStack(spacing: 8) {
                        Text(version.id)
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                        Text(versionDetail(version, in: manifest))
                            .font(.system(size: 12))
                            .opacity(0.6)
                        Spacer(minLength: 12)
                        if version.id == displayedVersion?.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(popoverTextColor)
                .accessibilityIdentifier("versionRow-\(version.id)")
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                Divider()
            }
            Button(action: {
                showingVersionMenu = false
                createNewVersion()
            }) {
                HStack {
                    Text("New Version")
                        .font(.system(size: 13))
                    Spacer(minLength: 12)
                    Text(ShortcutStore.shortcut(for: .newVersion, in: shortcutsJSON)?.displayString ?? "")
                        .font(.system(size: 12))
                        .opacity(0.6)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(popoverTextColor)
            .accessibilityIdentifier("newVersionButton")
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
        .frame(width: 250)
        .background(popoverBackgroundColor)
    }

    /// Top of the editor while a sealed version is shown read-only.
    private func versionBanner(for version: EntryVersion, textColor: Color, textHoverColor: Color) -> some View {
        VStack {
            HStack(spacing: 8) {
                Text("Viewing \(version.id) · read-only")
                    .foregroundColor(textColor)
                if !audioURLs(for: version).isEmpty {
                    Text("•")
                        .foregroundColor(.gray)
                    playVoiceNotes(audioURLs(for: version), textColor: textColor, textHoverColor: textHoverColor)
                }
                Text("•")
                    .foregroundColor(.gray)
                Button("Back to current") {
                    showCurrentVersion()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("backToCurrentVersionButton")
                .foregroundColor(isHoveringBackToCurrent ? textHoverColor : textColor)
                .onHover { hovering in
                    isHoveringBackToCurrent = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
            .font(.system(size: 13))
            .padding(.top, 12)
            Spacer()
        }
    }

    /// One play button, or a menu of every voice note when a version has more than one.
    @ViewBuilder
    private func playVoiceNotes(_ urls: [URL], textColor: Color, textHoverColor: Color) -> some View {
        if urls.count == 1, let url = urls.first {
            playVoiceNoteButton(url: url, textColor: textColor, textHoverColor: textHoverColor)
        } else {
            let playing = urls.firstIndex { voicePlayer.url == $0 && voicePlayer.isPlaying }
            Menu {
                ForEach(Array(urls.enumerated()), id: \.element) { index, url in
                    Button(voicePlayer.url == url && voicePlayer.isPlaying ? "Pause voice note \(index + 1)" : "Play voice note \(index + 1)") {
                        voicePlayer.toggle(url)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: playing == nil ? "play.fill" : "pause.fill")
                        .font(.system(size: 10))
                    Text(playing.map { "Voice note \($0 + 1) of \(urls.count)" } ?? "\(urls.count) voice notes")
                        .font(.system(size: 13))
                }
                .foregroundColor(isHoveringPlayVoiceNote ? textHoverColor : textColor)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("playVoiceNotesMenu")
            .onHover { hovering in
                isHoveringPlayVoiceNote = hovering
                hoverCursor(hovering)
            }
        }
    }

    private func playVoiceNoteButton(url: URL, textColor: Color, textHoverColor: Color) -> some View {
        let isPlaying = voicePlayer.url == url && voicePlayer.isPlaying
        return Button(action: {
            voicePlayer.toggle(url)
        }) {
            HStack(spacing: 4) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10))
                Text(isPlaying ? "Pause voice note" : "Play voice note")
                    .font(.system(size: 13))
            }
            .foregroundColor(isHoveringPlayVoiceNote ? textHoverColor : textColor)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("playVoiceNoteButton")
        .onHover { hovering in
            isHoveringPlayVoiceNote = hovering
            hoverCursor(hovering)
        }
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
        .popover(
            isPresented: $showingMicrophonePermissionPopover,
            attachmentAnchor: .point(UnitPoint(x: 0.5, y: 0.0)),
            arrowEdge: .top
        ) {
            Button(action: {
                showingMicrophonePermissionPopover = false
                openVideoPermissionSettings("Privacy_Microphone")
            }) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Hey, we need microphone permission.")
                        .font(.system(size: 14))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Open Microphone Settings")
                        .font(.system(size: 12))
                        .opacity(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .foregroundColor(popoverTextColor)
            .frame(minWidth: 300, idealWidth: 320, maxWidth: 360)
            .background(colorScheme == .light ? Color.white : Color.black)
        }
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
                guard entry.entryType == .text else { return nil }
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
        // Delete the file from the filesystem
        let documentsDirectory = getDocumentsDirectory()
        let fileURL = documentsDirectory.appendingPathComponent(entry.filename)

        do {
            try fileManager.removeItem(at: fileURL)
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
        
        // Get entry content
        let documentsDirectory = getDocumentsDirectory()
        let fileURL = documentsDirectory.appendingPathComponent(entry.filename)
        
        do {
            // Read the content of the entry
            let entryContent = try String(contentsOf: fileURL, encoding: .utf8)
            
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
