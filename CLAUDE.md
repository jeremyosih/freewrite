# Freewrite - Technical Documentation for AI Agents

> **⚠️ IMPORTANT FOR AI AGENTS**: This file (`AGENTS.md`) and `CLAUDE.md` are clones and must be kept in sync.
>
> Update both files when changes are **substantial** and meaningfully affect future agent understanding (for example: architecture, data flow, storage/permissions, threading behavior, user-facing workflows, or major bug fixes).
>
> For minor tweaks (small UI polish, copy edits, tiny refactors), updates are optional. Do **not** churn these docs on every small code change.
>
> If one file is updated, mirror the same change in the other file immediately.

## Product Vision & User Experience

### What is Freewrite?

Freewrite is a **distraction-free writing environment** for macOS designed around the concept of stream-of-consciousness writing and video journaling. The core philosophy is to remove barriers between thought and writing by creating a minimalist, opinionated interface that prioritizes the act of writing over formatting, organization, or editing.

### User Experience Philosophy

**Core Principles:**
1. **No Backspace (Optional)**: Users can disable the backspace key to encourage forward-thinking writing without self-editing
2. **Timed Sessions**: Built-in timer (default 15 minutes) creates focused writing sprints
3. **Auto-Everything**: Auto-save, auto-new-entry, auto-timestamp - the app manages logistics so users can focus on writing
4. **Local-First**: All data stays on the user's machine in plain markdown files they can access directly
5. **Minimal UI**: Most UI elements hide during timed sessions, leaving only the text

### Use Cases

**Primary Use Case - Stream of Consciousness Writing:**
- Users open the app and start writing immediately (no "New Document" dialog)
- The app creates a new entry automatically at the start of each day
- Writing is saved continuously with no manual save action
- Timer creates urgency and prevents over-editing
- Backspace disable forces forward momentum in thinking

**Secondary Use Case - Video Journaling:**
- Quick video capture for visual thoughts/ideas
- Video entries stored alongside text entries in chronological history
- One-click recording with built-in timer
- Local storage ensures privacy for personal video journals

**Hidden Power Feature - Long-Form Writing:**
- Despite minimalist interface, supports full markdown
- Entries can be exported as PDFs
- Font and size customization for comfort during long sessions
- Dark mode for night writing

## Overview

Freewrite is a native macOS writing application built with SwiftUI that allows users to write text entries and record video entries. All data is stored locally in `~/Documents/Freewrite/`.

## Architecture

### Technology Stack
- **Framework**: SwiftUI (macOS)
- **Minimum macOS Version**: 26.0
- **Language**: Swift 6 (language mode 6; `CameraManager` is `@unchecked Sendable` and hops queues manually)
- **Build System**: Xcode
- **Media**: AVFoundation for camera/video recording

### Project Structure

```
freewrite/
├── freewrite.xcodeproj/          # Xcode project file
├── freewrite/
│   ├── freewriteApp.swift        # App entry point
│   ├── ContentView.swift         # Main view (1400+ lines)
│   ├── VideoRecordingView.swift  # Video recording interface
│   ├── VideoPlayerView.swift     # Video playback interface
│   ├── SettingsView.swift        # Settings window (⌘,): pane enum + sidebar, General/Shortcuts panes, settings keys, shortcuts + menu commands
│   ├── SettingsPanes.swift       # Settings › Recording, Storage, Permissions, About
│   ├── AudioInput.swift          # Microphone choice (AVCaptureDevice ids) + AVAudioEngine capture for a chosen input / level meter
│   ├── Transcription.swift       # Transcription engines: Apple (live, on-device) or Hex local API client
│   ├── CommandPalette.swift      # ⌘K palette view + AppKit search field (keyboard handling)
│   ├── PaletteSearch.swift       # Pure palette model + matching (PaletteDocument/Item/Index/Search, unit-tested)
│   ├── BottomBar.swift           # Bottom bar layout model (item, side, order) + Settings › Bottom Bar pane
│   ├── BarMenu.swift             # Floating bar menus (no arrow): anchors, card, placement
│   ├── VoiceNotePlayerBar.swift  # Voice-note player in the bar: waveform scrubber, time, speed, stop
│   ├── Waveform.swift            # RMS buckets of a voice note (file or in-memory bytes)
│   ├── WritingEditor.swift       # TextKit 2 NSTextView editor: markdown styling, highlights + hover comments
│   ├── MarkdownStyling.swift     # Pure logic: markdown span ranges, EditorHighlight + range adjustment
│   ├── Storage.swift             # EntryStorage (entries folder + bookmark) and StorageTransfer (move/copy)
│   ├── Versions.swift            # EntryVersionStore: manual versions + voice notes under Entries/ (pure, tested)
│   ├── VoiceNotes.swift          # VoiceNoteRecorder (AVAudioRecorder → temp .m4a) and VoiceNotePlayer
│   ├── Annotations.swift         # Reviewer notes: Annotation model, annotations.json store, quote anchoring (pure, tested)
│   ├── Reviewers.swift           # ReviewerProfile (+ 3 defaults), stored in UserDefaults["reviewers"]
│   ├── Reviews.swift             # ReviewService: PiDurableKit harness, reviewer tools, Keychain credentials
│   ├── AgentsSettingsView.swift  # Settings › Agents: providers + reviewer list/inline editor; kind swatches + legend
│   ├── NoteLock.swift            # Locked notes: .fwlock format, recovery key, Secure Enclave vault, NoteLockSession
│   ├── PrivacySettingsView.swift # Settings › Privacy + recovery key sheets
│   └── freewrite.entitlements    # App permissions
├── Vendor/PiDurableKit/          # Vendored finnvoor/PiDurableKit (CC0), local Swift package; see VENDORED.md
├── CLAUDE.md                     # This file
└── AGENTS.md                     # Duplicate of this file
```

## Data Model

### Entry Types

```swift
enum EntryType {
    case text
    case video
}

struct HumanEntry: Identifiable {
    let id: UUID
    let date: String              // Display format: "MMM d" (e.g., "Feb 20")
    let filename: String          // Format: [UUID]-[YYYY-MM-DD-HH-mm-ss].md
    var previewText: String       // First 30 chars or "Video Entry"
    var entryType: EntryType      // .text or .video
    var videoFilename: String?    // Format: [UUID]-[YYYY-MM-DD-HH-mm-ss].mov
    var versionCount = 1          // from Entries/<base>/entry.json; drives the history "v3" badge
    var hasVoiceNote = false
}
```

### Versions (`Versions.swift`)

The top-level `[UUID]-[date].md` is **always the current, editable version** (autosave, preview, launch selection and ⌘K keep using it). Sealed versions and voice notes live in `Entries/[UUID]-[date]/`, created lazily:

```
Entries/[UUID]-[date]/
  entry.json             {"current":"v2","versions":[{"id":"v1","n":1,"createdAt":ISO8601,"source":"voice-note","audio":"audio/v1.m4a"},{"id":"v2",…,"source":"typed"}]}
  versions/v1.md         sealed, read-only snapshots
  audio/v1.m4a           voice note of v1 (a second note for the same version: v1-2.m4a, older path kept in "previousAudio")
  audio/v1.transcript.md raw transcript from the engine
```

- No `Entries/` folder = one implicit version v1 (createdAt from the filename). Fully backwards compatible.
- `EntryVersionStore(root:)` (`EntryStorage.shared.versionStore`) is the API, also meant for the AI reviewer: `manifest(for:)`, `versions(for:)`, `text(of:for:)` (current version is read from the top-level file), `entryDirectory(for:)` (put `annotations.json` here), `url(forRelativePath:entryFilename:)`, `sealCurrent(entryFilename:)`, `attachVoiceNote(from:to:)`, `saveTranscript(_:forAudio:entryFilename:)`, `deleteEntryDirectory(for:)`, `savedManifests()`.
- `sealCurrent` refuses empty text, then writes atomically in order: `versions/vN.md` → manifest (current = vN+1) → empty top-level file. An interruption can duplicate text into the new version, never lose it. A corrupt `entry.json` makes it throw instead of being overwritten.
- `Entries` is in `StorageTransfer.managedDirectoryNames`; `deleteEntry` removes `Entries/<base>/` too.

### File Storage

**Location**: the entries folder from `EntryStorage.shared.rootURL` (`Storage.swift`). Paths below say `~/Documents/Freewrite/` for brevity.
- Default: `Documents/Freewrite/` inside the sandbox container, i.e. `~/Library/Containers/app.humansongs.freewrite/Data/Documents/Freewrite/` (not the user's real `~/Documents`).
- Custom: any folder picked in Settings › Storage (e.g. real `~/Documents/Freewrite` or iCloud Drive), kept as a security-scoped bookmark (`UserDefaults["storageFolderBookmark"]`). On launch the bookmark is resolved (refreshed if stale) and `startAccessingSecurityScopedResource()` is held for the app's lifetime; access to the old folder stops when switching. If it can't be resolved or the folder is gone, the bookmark is cleared, the default folder is used and `ContentView` shows a one-time alert.
- Never build paths from `.documentDirectory` directly: `ContentView.getDocumentsDirectory()` / `getVideosDirectory()` read `EntryStorage`, and anything resolved before an `await` must be re-resolved afterwards because the folder can change at runtime. Exception: the Hex transcript is tied to the recording: it's written next to the `.mov` where it was saved and, after a move/copy, next to its counterpart in the current folder (`saveHexTranscript`); write failures are logged. `ContentView` reloads entries on `.onChange(of: storage.rootURL)`.
- Switching folders asks **Move / Copy / Just Switch / Cancel** (skipped when the current folder has no entries). `StorageTransfer` handles top-level canonical `[UUID]-[yyyy-MM-dd-HH-mm-ss].md`/legacy `.mov` files (`StorageTransfer.parseEntryFilename`, shared with the entry loader) plus the managed subfolders (`managedDirectoryNames`, currently `Videos/`; add new Freewrite-owned subfolders there). It never overwrites an existing destination file (skipped + reported), copies via hidden `.partial` temp names, runs a first pass off the main actor and a final pass on it (picking up saves made meanwhile), and deletes originals only if every copy succeeded; on any failure nothing is deleted and the folder doesn't change. Files that vanished from the source after the first pass are removed from the destination (`dropVanished`), and deleting entries is blocked while `isTransferring`. After a move only folders holding nothing but `.DS_Store` are removed. Unrelated files in the folder (README.md, holiday.mov, hidden files) are left alone.
- Never build paths from `.documentDirectory` directly: `ContentView.getDocumentsDirectory()` / `getVideosDirectory()` read `EntryStorage`, and anything resolved before an `await` (e.g. the Hex transcript path) must be re-resolved afterwards because the folder can change at runtime. `ContentView` reloads entries on `.onChange(of: storage.rootURL)`.
- Switching folders asks **Move / Copy / Just Switch / Cancel** (skipped when the current folder has no entries). `StorageTransfer` handles top-level `.md`/legacy `.mov` files plus the managed subfolders (`managedDirectoryNames`, currently `Videos/` and `Entries/`; add new Freewrite-owned subfolders there). It never overwrites an existing destination file (skipped + reported), copies via hidden `.partial` temp names, runs a first pass off the main actor and a final pass on it (picking up saves made meanwhile), and deletes originals only if every copy succeeded; on any failure nothing is deleted and the folder doesn't change. Unrelated files in the folder are left alone.

**Text Entries**:
- Format: Markdown (.md)
- Naming: `[UUID]-[YYYY-MM-DD-HH-mm-ss].md`
- Content: Plain UTF-8 text
- Example: `[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04].md`

**Video Entries**:
- Format: QuickTime Movie (.mov)
- Naming: `[UUID]-[YYYY-MM-DD-HH-mm-ss].mov`
- Metadata: Corresponding `.md` file with "Video Entry" text in `~/Documents/Freewrite/`
- Storage layout: `~/Documents/Freewrite/Videos/[UUID]-[YYYY-MM-DD-HH-mm-ss]/`
- Directory contents:
  - `[UUID]-[YYYY-MM-DD-HH-mm-ss].mov`
  - `thumbnail.jpg`
  - `transcript.md` (optional; speech transcript for that recording)
- Example directory: `~/Documents/Freewrite/Videos/[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04]/`

## Key Components

### ContentView.swift

The main view containing all UI and business logic.

#### State Variables (Selection)

```swift
@State private var entries: [HumanEntry] = []           // All loaded entries
@State private var text: String = ""                    // Current text editor content
@State private var selectedEntryId: UUID? = nil         // Currently selected entry
@State private var showingVideoRecording = false        // Video recording overlay visibility
@State private var currentVideoURL: URL? = nil          // Video playback URL
@State private var showingSidebar = false               // History sidebar visibility
@State private var colorScheme: ColorScheme = .light    // Light/dark theme
@State private var fontSize: CGFloat = 18               // Text size (16-26px)
@State private var selectedFont: String = "Lato-Regular"// Current font
@State private var timerIsRunning = false               // Timer state
@State private var timeRemaining: Int = 900             // Timer (seconds)
@State private var backspaceDisabled = false            // Backspace lock
```

#### Core Functions

**Entry Management**:
- `loadExistingEntries()` - Loads all .md and .mov files from documents directory
- `createNewEntry()` - Creates new text entry
- `saveEntry(entry:)` - Saves text to .md file
- `loadEntry(entry:)` - Loads text or video for display
- `deleteEntry(entry:)` - Deletes entry and associated files
- `saveVideoEntry(from:)` - Saves recorded video and creates metadata

**Important**: When modifying the `entries` array from async contexts, wrap in `DispatchQueue.main.async` to prevent collection mutation crashes.

### VideoRecordingView.swift

Handles camera access and video recording.

#### CameraManager Class

```swift
class CameraManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var recordingTime: Int = 0
    @Published var permissionGranted = false

    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureMovieFileOutput?
    private var previewLayer: AVCaptureVideoPreviewLayer?
}
```

**Key Methods**:
- `setupCamera()` - Configures AVCaptureSession with video/audio inputs
- `startRecording(to:)` - Begins recording to temporary file
- `stopRecording()` - Stops recording and triggers completion handler
- `cleanup()` - Releases camera resources

**Critical**: Always use `beginConfiguration()` and `commitConfiguration()` when modifying AVCaptureSession to prevent crashes.
**UI Pattern**: The recorder is rendered as an immersive edge-to-edge overlay with a transparent bottom nav and a floating circular record control.

### VideoPlayerView.swift

Simple AVKit-based video player for playback.

```swift
struct VideoPlayerView: View {
    let videoURL: URL
    @State private var player: AVPlayer?
}
```

## UI Layout

### Main Interface

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│                    Text Editor Area                     │
│              (or Video Player if video)                 │
│                                                         │
├─────────────────────────────────────────────────────────┤
│  Bottom Nav Bar:                                        │
│        [15:00] • [🎥] • [Backspace] • [Fullscreen] •     │
│        [New Entry] • [🕐] • [⚙︎]   (customizable)        │
└─────────────────────────────────────────────────────────┘
```

### Sidebar (History)

```
┌──────────────┐
│   History    │
├──────────────┤
│ 📹 Video...  │ ← Video entry with thumbnail
│ Feb 20       │
├──────────────┤
│ This is a... │ ← Text entry with preview
│ Feb 19       │
├──────────────┤
│ Another ...  │
│ Feb 18       │
└──────────────┘
```

## Navigation Bar Items

### Bottom Bar (customizable, `BottomBar.swift`)
- Items: Versions (`vN ⌃` menu: list/switch versions, New Version; default left), Timer, Record Video, Record Voice Note (🎙; while recording the bar becomes `● 3:42 ▁▃▅ Stop • Discard`), Review (✦: Review with… menu, spinner while a review runs), Backspace Toggle, Fullscreen, New Entry, History, Lock (`lock.open`/`lock.fill`, toggles the selected note's lock), Settings. Each is Left, Right or Hidden, in a user-defined order (Settings › Bottom Bar, drag to reorder, live preview). Stored as JSON in `UserDefaults["bottomBarLayout"]`; `BottomBarLayout.decode` drops unknown/duplicate items and inserts items missing from a stored layout at their default side, before the earliest stored item that follows them in `BottomBarItem.allCases` (Review before Backspace/History/Settings, Lock before Settings; never after the gear). Tests: `freewriteTests/BarLayoutTests.swift`.
- `ContentView.bottomBarItemView(_:)` renders each item; `bottomBarGroup` adds the `•` separators. Versions, Voice Note, Review, Backspace and Lock are writing-only (hidden on video entries); Versions and Voice Note are also hidden while a locked note is closed, Review on any locked note.
- **Overflow, never clipping**: the bar is a `ViewThatFits` over `bottomBarRow(overflow:)` with 0…n items moved into a "…" floating menu, in `ContentView.overflowOrder` (Fullscreen first … History last; Versions and Settings never move). "…" sits just before the gear. The left group has `layoutPriority(2)`, the right `1`, so the status and separators aren't squeezed while the spacer keeps room. The timer's scroll-wheel monitor is installed once per window (`installTimerScrollMonitor`) because the timer view comes and goes.
- **Floating menus (`BarMenu.swift`)**: every bar menu (versions, Review with…, voice notes, camera/microphone permissions, "…") is a `BarMenuCard` (12pt corners, theme background + hairline border + soft shadow, 32pt rows, hover/keyboard highlight), never a `.popover`. Controls publish `.barMenuAnchor(_:)`; `ContentView.barMenuOverlay` reads them via `overlayPreferenceValue` and `BarMenuPlacement` puts the card 8pt above its anchor, kept inside the window (falls back to "…" then the bar's right side when the control isn't shown). Content is data (`BarMenuContent` → sections → `BarMenuAction`) built in `barMenuContent(_:)`. One menu at a time (`openBarMenu`); fade + 6pt rise over 0.15 s (opacity only with Reduce Motion). Esc, a click outside, choosing a row, switching entry/video, the palette or recording close it; ↑/↓/↩ move/choose (local key monitor while open, swallowing other non-⌘ keys).
- Fixed status slot at the start of the left side, next to the version button: for text entries `Viewing v1 · read-only • Back to current` while a sealed version is shown (no banner over the text), the displayed version's voice note (`Play voice note`, or `N voice notes ⌃` opening a menu to choose one; while loaded the player `VoiceNotePlayerBar`, with `1/2 ⌃` when there are several), then transient status (`Transcribing…`, reviews, errors; truncated at 280pt). Video entries show `Copy Transcript` / transcription status.
- **Voice-note player** (`VoiceNotePlayerBar.swift`, `VoiceNotePlayer` in `VoiceNotes.swift`, `Waveform.swift`): play/pause, a 40-bar waveform that is also the scrubber (drag/click to seek; played part darker; bars at the playhead pulse with the live meter unless Reduce Motion), elapsed / total, speed 1×/1.5×/2× (`enableRate`, kept across notes), × to stop. Levels are computed once per note off the main thread (`Waveform.levels(of:)`: RMS per bucket on a −50…0 dB scale, normalised). For an open locked note `toggleVoiceNote` passes the decrypted bytes: playback uses `AVAudioPlayer(data:)` and the waveform `Waveform.levels(of: Data)` (ExtAudioFile over in-memory callbacks), nothing is written to disk. The player stops when the version/entry changes or locked notes close (`resetVersionState`).
- Hidden items stay reachable from the menu bar, ⌘K and shortcuts. The gear and ⌘, toggle the Settings window (`SettingsWindow.toggle`).
- The Chat (ChatGPT/Claude) feature was removed.

### Settings Window & Shortcuts (`SettingsView.swift`)
- `Settings { SettingsView() }` scene in `freewriteApp.swift`, 760×560, styled like Hex's settings with native components: a sidebar `List` of monochrome SF Symbols (no coloured tiles or tints) in sections — **General** (no header), **Settings**: Recording, Storage, Permissions, Privacy, Agents, Bottom Bar, Shortcuts, **Freewrite**: About — with the app version (`AppVersion.display`) pinned at the bottom of the sidebar, and a large left-aligned page title at the top of the detail area (no toolbar title). Last pane in `UserDefaults["settingsPane"]`.
- Adding a pane = a case in `SettingsPane` (title, `systemImage`, `group`) + its view in `SettingsView.pane(_:)`.
- Rows are compact: title + small secondary subtitle on the left (`LabeledContent`/`Picker` with two `Text`s in the label inside `Form.grouped`), the control on the right. Panes that aren't a `Form` (Agents) use `SettingsCard` / `SettingsCardRow` / `SettingsSectionHeader` from `SettingsView.swift`, which look the same.
- Privacy: locked-note count, open/locked + Lock Now, timeout, recovery key rows (Show…, Create…, Unlock… for notes from another Mac), then what locking protects (`PrivacySettingsView.swift`).
- Agents: providers card (Anthropic key, ChatGPT sign-in / OpenAI key) and the "reviews send this entry's text" note on top; below, two columns like Hex's Modes: the reviewer list (colour dot, model, kind swatches; +/−, ⋯ → Restore Default Reviewers) and the selected reviewer's editor inline (name, colour, instructions, model, thinking, scope, auto-run, allowed kinds + default kind). Edits save as you type; no sheet.
- General: font, size + preview, then a trailing row **Random Font** / **Reset to Default** (Lato 18; random must not sit on the Font row), theme, timer length.
- Recording: Microphone (System default + `AudioInputDevices.available()`, stored as `microphoneID`), live Input level (`AudioInputCapture`, only when mic access is already granted — Settings never prompts), then Transcription engine; Apple → Language (Automatic + `SFSpeechRecognizer.supportedLocales()`, `AppleSpeechLanguage`), Hex → status, model, language.
- Storage: folder size (computed off-main) + Show in Finder, then Location (the path, home shown as ~, as the subtitle) + Use Default / Choose….
- Permissions: Microphone, Camera, Speech Recognition (`AppPermission`) with live status (Allowed / Not allowed + Open System Settings / Not asked + Allow…), re-checked when a window becomes key or the app becomes active.
- About: icon, version (`CFBundleShortVersionString` + build), links, **Show welcome entry** (`AppCommand.showWelcomeEntry` → new entry with `default.md`).
- Every app action is an `AppCommand`. `FreewriteCommands` builds the menu items with the user's shortcuts and posts `AppCommand.notification`; `ContentView.handle(_:)` performs the action.
- Shortcuts are stored as JSON overrides in `UserDefaults["shortcuts"]` (missing key = default, `null` = unassigned). Recording requires ⌘, ⌃ or ⌥ so plain typing never triggers a command.

### Command Palette (⌘K, `CommandPalette.swift`, `PaletteSearch.swift`)
- `AppCommand.commandPalette` toggles an overlay in `ContentView`. On open, every entry's text (or its video `transcript.md`) plus sealed versions are read off the main thread and folded once (case/diacritics) into a `PaletteIndex`. Each opening gets a `paletteLoadID` so a slower read from an earlier opening is dropped. The palette doesn't open while the video recorder is up.
- Search: `PaletteSearch.run` (`@concurrent`, off the main actor) runs from `.task(id: query + index id)`, so each keystroke cancels the previous search. Empty query: 8 most recent entries, then all actions. With a query: up to 4 actions (title substring first, then word-start matches like "nv" → New Version), then entries where every term matches, title hits first, capped at 50; snippets only for shown rows. Keep it pure: `freewriteTests/PaletteSearchTests.swift`.
- Keyboard: the field is an `NSTextField` (`PaletteSearchField`), not a SwiftUI `TextField`; its delegate's `doCommandBy` handles `moveUp:`/`moveDown:` (wrap), ⌘↑/⌘↓ (first/last), `insertNewline:` (open), ⌘↩ (arrives as `noop:`, detected from `NSApp.currentEvent`: on a sealed version opens the entry's current version, otherwise same as ↩) and `cancelOperation:` (close). Marked text (IME) is left alone. It takes first responder when added to the window; `canTakeFocus: !showingCommandPalette` on the editor gives focus back on close.
- Hover gate: rows use `.onContinuousHover`, but the pointer location is pinned on open, on each keyboard move and on each results change; hover only moves the highlight once the real pointer (`NSEvent.mouseLocation`) moved, so rows scrolling under a resting pointer never steal it.
- UI: accent-tinted highlight, no dimming (a clear full-window hit area closes on click outside), list height fits the rows up to 380pt (`onGeometryChange`). VoiceOver: keyboard moves post an announcement with the highlighted title; rows have `.isSelected` and a default action.
- Review actions: `PaletteIndex.reviewActions` (`PaletteReviewActions`, captured on open from the version on screen) adds **Review with <reviewer>** per profile (hidden while a review runs and for locked notes; a row whose version is no longer on screen refuses with a status), **Clear Review (n notes)** when that version has notes, and **Reviewers & Models…** (Settings › Agents).
- Selecting an entry goes through `selectEntry(id:version:)` (same save-then-load path as history rows). The backspace blocker ignores the palette and the Settings window.

### Accessibility
Bottom-bar controls, the editor and history rows carry `accessibilityLabel`s (where the visible text isn't enough) and stable `accessibilityIdentifier`s (`timerButton`, `recordVideoButton`, `historyButton`, `settingsButton`, `newEntryButton`, `editor`, `historyRow-<uuid>`, `commandPaletteSearch`, …) for VoiceOver and UI automation.

## Versions & Voice Notes Flow

**New Version** (`AppCommand.newVersion`, ⇧⌘N, version menu, ⌘K): only for a text entry with non-empty text. `ContentView.createNewVersion()` saves the editor to disk first (aborts if that fails), calls `sealCurrent`, then clears `text` to an empty page for vN+1.

**Viewing a sealed version**: version menu, or a ⌘K hit on a sealed version (`PaletteDocument.version`). `viewedVersion`/`viewedVersionText` are shown via `WritingEditor(text: .constant(…), isEditable: false)` with `Viewing v1 · read-only • Back to current` and that version's voice notes in the bottom bar's status slot (nothing is drawn over the text). `text` (the current version) is never touched, so autosave can't write a sealed version into the top-level file. Selecting/creating another entry or switching folders resets to the current version (`resetVersionState`).

**Voice note** (`AppCommand.recordVoiceNote`, ⇧⌘V, mic icon):
1. Microphone permission is requested if needed; if denied a popover (same style as the camera's) links to System Settings.
2. `VoiceNoteRecorder` records AAC mono 44.1 kHz to a temp `.m4a`, no time limit. Discard deletes it. With the system default microphone it uses `AVAudioRecorder`; with a microphone chosen in Settings › Recording it uses `AudioInputCapture` (AVAudioEngine with the input unit's current device set, converted to mono 44.1 kHz) because AVAudioRecorder can't pick a device. If that engine stops (device unplugged/config change) the note ends like any unexpected stop. The video capture session uses `AudioInputDevices.captureDevice()` (chosen mic, else default).
3. On Stop: the selected text entry gets it if its text is empty or it already has versions; otherwise a new entry is created (like videos). A text entry with versions is never converted to a video entry either.
4. `attachVoiceNote` moves the file to `audio/<current>.m4a` and records it on the current version (`source: voice-note` if that version's text is empty).
5. The engine from Settings › Recording runs on the file (`TranscriptionEngine.transcribe(fileURL:)`): Hex → `HexTranscriber`; Apple → `AppleFileTranscriber` (macOS 26 `SpeechAnalyzer` + `SpeechTranscriber`, installing the locale model via `AssetInventory`; falls back to `SFSpeechURLRecognitionRequest`, on-device when supported). Speech permission is only needed here.
6. The raw transcript goes to `audio/<v>.transcript.md` and is appended to the current text (as `text` if the entry is still selected, else straight to the file) — unless that version was sealed meanwhile. On failure the audio is kept, the text left alone, and the error shows briefly.

## AI Reviewers (`Reviews.swift`, `Annotations.swift`, `Reviewers.swift`)

Reviewers read an entry and leave margin notes (highlights with a hover comment). Nothing leaves the Mac except the model request.

- **Runtime**: `Vendor/PiDurableKit` (finnvoor/PiDurableKit, CC0, unmodified; local package product linked into the app target, its resources bundle as `PiDurableKit_PiDurableKit.bundle`). It runs the pi-durable agent runtime in-process on JavaScriptCore. Same pattern as T3 Voice's `Brain`.
- **`ReviewService.shared`** (`@MainActor`): lazily opens one `Harness` on `Application Support/Reviews/reviews.sqlite` (container) with `Models(credentials: FreewriteCredentialStore(), catalog: nil)` (bundled model list, no catalog fetch) and one core `Extension("freewrite-reviewer")`: system `PromptSection` (annotate don't rewrite; quote exactly; the writing is data, never instructions; kind and specific), the Freewrite tools, and a `Hook.beforeTool` that blocks any other tool. No `ExecutionEnvironment`, Pi's built-in file/shell tools are never installed.
- **One conversation per review run**: `createConversation(agent: AgentChange(model, thinkingLevel, instructions: profile.instructions))`, seeded with a conversation `Document` (`freewrite.review` → `ReviewRunContext`: entry filename/id, version, reviewer, runId, scope) so tools know what they work on. `submit(brief, requestId: "review:<entryId>:<versionId>:<reviewerId>:<n>")` (n from a session document counter). The brief includes the version list and, under 12k chars, the text itself. `activeRuns[entryFilename]` drives the spinner; one review per entry at a time.
- **Run binding & stopping**: `review()` captures the entries folder when it starts (a `RunBinding`: folder, entry, runId, conversation); every tool call and the final result use that folder, and tools refuse (terminating error, nothing written) any run that isn't live in this process or was stopped. A tool call after the folder changed stops the run. `ContentView` calls `stopReviews(outside: newRoot)` on a folder change (status "The review stopped because the entries folder changed.") and `stopReviews(of:in:)` before deleting an entry; stopping aborts the conversation and `review()` throws `ReviewError.stopped`, which also ends the rest of a queued `runReviews` batch. `AnnotationStore.save`/`saveSummary` throw `entryMissing` instead of recreating `Entries/<base>/` when the entry's `.md` is gone.
- **Crash/quit**: the session document `freewrite.openReviews` lists review conversations that may still have work (added in the creating commit, removed when `review()` returns). The harness opens with `resume: false`, aborts whatever that list holds (`abortInterruptedReviews`), then calls `resume()`. Interrupted reviews are cancelled, not resumed: nobody awaits them any more and they'd run next to a new review of the same entry; the user just runs the review again.
- **Tools** (Swift closures, all `.safe` replay; logic in the pure `ReviewToolbox`, unit-tested): `list_versions`, `read_version(id?, start?, end?)` (20k UTF-16 slices), `diff_versions(from,to)` (line diff), `list_annotations(versionId?)`, `add_annotation({versionId?, quote, prefix?, suffix?, comment, kind?})` (finds the quote itself, computes UTF-16 offsets, rejects missing/ambiguous quotes with a helpful error; the id is memoized on the durable call so replays don't duplicate; `kind` is checked by the tool, not a schema `enum`: missing → the reviewer's default kind, unknown or not allowed for this reviewer → saved as the default kind and the result tells the model; on `update_annotation` a bad kind is ignored), `update_annotation` / `remove_annotation` (own reviewer only), `finish_review(summary)` (writes `reviews/<timestamp>-<reviewer>.md`, ends the run). Mutating tools emit `annotationsChanged` so the window reloads live.
- **Annotations**: `Entries/<base>/annotations.json`, a plain array: `{id, entryId, versionId, reviewerId, runId, anchor: {quote, prefix, suffix, start, end}, comment, kind, status: active|orphaned|dismissed, createdAt}`. Offsets are UTF-16. `AnnotationStore.update` is read-modify-write and never overwrites an unreadable file. Sealed versions never change, so their offsets stay valid. For the current version, `AnnotationAnchoring.reanchor` runs on load (offsets still match the quote → keep; else search the quote, picking by prefix/suffix context then distance; else `orphaned`, revived if the quote returns), and `followEdit` runs on every `text` change (single-edit diff → `EditorHighlight.adjust` → re-check), saved debounced (1 s) by merging by id. The pending positions (`pendingAnchors`, with the store/folder they were typed in) are flushed synchronously by `flushAnnotationAnchors()` before New Version seals, before any reload (entry/version/folder switch, a review's change), on window close and on quit; never just cancel them. Dismissed notes are kept so reviewers don't repeat them. `Entries/` already moves with `StorageTransfer` and is deleted with the entry.
- **UI**: `AppCommand.reviewEntry` ("Review with…", ⇧⌘E, Write menu, ⌘K) and the bottom-bar ✦ open a popover (on the item, or on the bar's right side if the item is hidden): reviewers, the latest summary for the version, Clear Review (deletes that version's notes), Reviewers & Models…. It reviews the displayed version (current — saved first — or a sealed one being viewed). `ContentView.editorHighlights` passes the displayed version's active notes to `WritingEditor` (colour per kind, popover title "Kind · Reviewer" with a kind-coloured dot, then the comment; the Review popover shows a kind legend with counts for the version); right-click a highlight → Dismiss Note (`onDismissHighlight`). Results/errors show in the bottom-bar status; profiles with "Run automatically on New Version" review the just-sealed version after ⇧⌘N.
- **Profiles** (`ReviewerProfile`, JSON in `UserDefaults["reviewers"]`, missing = defaults Mirror / Editor / Coach): name, instructions, model (`provider/modelId`, empty = Automatic: Anthropic `claude-sonnet-5-5`, else OpenAI `gpt-5.5`, whichever is configured first), thinking level, colour (the reviewer's dot only; highlights are coloured by kind), scope (one version / all versions), auto-run, `kinds` (allowed kinds; missing = per-id defaults: Editor grammar/clarity/structure, Mirror insight/question, Coach question/praise, custom all) and `defaultKind`.
- **Kinds** (`AnnotationKind` in `Annotations.swift`): `grammar`, `clarity`, `structure`, `insight`, `question`, `praise`, each with a `guidance` line used in the tool schema, the brief (which lists only the reviewer's allowed kinds and its default) and Settings. Colours in `Reviewers.swift` (`nsColor`: system red/blue/purple/yellow/teal/green; `highlightColor` is a dynamic light/dark tint; grammar also gets a red squiggle). `Annotation.kind` stays the stored string; `resolvedKind` maps older words (`observation` → insight, `suggestion` → clarity, …) and unknown ones to `insight`. Tests: `freewriteTests/AnnotationKindTests.swift`.
- **Credentials**: `FreewriteCredentialStore` (`CredentialStore`, service `<bundle id>.models`): generic passwords in the data-protection keychain; on errSecMissingEntitlement (-34018, builds without a team) writes fall back to the login keychain. Reads don't fail that way (the data-protection keychain just says "not found"), so reads, listing and sign-out always check both keychains; never read only one (that bug hid every sign-in and key in ad-hoc builds; `freewriteTests/CredentialStoreTests.swift`). Keys never touch UserDefaults, disk or the DB. Anthropic: API key from the Claude Console only; `saveAPIKey` refuses subscription tokens (`sk-ant-oat…` from `claude setup-token`), which Anthropic only allows in Claude Code and its own apps. OpenAI: "Sign in with ChatGPT" (`Models.login(to: .openAI, interaction: .webAuthenticationSession())`, loopback redirect → needs `network.server`) or an API key (same provider, one credential at a time). Apple on-device models aren't offered (PiDurableKit's provider needs macOS 27 and an 8K context).
- **Tests**: `freewriteTests/AnnotationTests.swift` (anchoring, JSON shape, toolbox) and `ReviewServiceTests.swift` (end-to-end with PiDurableKit's `FauxProvider`, in-memory credentials). Don't run `xcodebuild test` (it launches the unsandboxed app); run them headless in a scratch SwiftPM package that symlinks the app sources (`Versions`, `Annotations`, `Reviewers`, `Reviews`, `MarkdownStyling`, `Storage` + a `SettingsKey` shim) into a target named `freewrite` and depends on `Vendor/PiDurableKit`.
## Locked Notes (`NoteLock.swift`)

A text entry can be locked: encrypted at rest, opened with Touch ID, an Apple Watch or the Mac password (`.deviceOwnerAuthentication`). There is no whole-app lock. Video entries can't be locked yet (menu item disabled, status message).

**Files.** `[UUID]-[date].md` → `[UUID]-[date].fwlock` (same base, so dates/sorting/`Entries/<base>/` still work). Every file in `Entries/<base>/` except `entry.json` becomes `<name>.fwlock` (`versions/v1.md.fwlock`, `audio/v1.m4a.fwlock`, `audio/v1.transcript.md.fwlock`, `annotations.json.fwlock`). `entry.json` stays plain: only version ids, dates, source and audio paths, no text (needed for the version menu/badge before opening). `HumanEntry.filename` stays the logical `.md` name; `HumanEntry.isLocked` marks it.
Format: `"FWLK" | version 1 | algorithm 1 (AES-GCM-256) | key id (16) | recovery wrap (76) | salt (32) | nonce (12) | ciphertext | tag (16)`. File key = HKDF-SHA256(content key, salt); the whole header is the AAD. Single-shot (notes and voice notes fit in memory; a chunked v2 would be needed for videos).

**Keys.** A random 256-bit content key per keyring entry. The keyring (content keys + their recovery secrets) is sealed to a Secure Enclave P-256 key (`[.privateKeyUsage, .userPresence]`, `WhenUnlockedThisDeviceOnly`; never `.biometryCurrentSet`, which destroys the key when a fingerprint is added) via ephemeral ECDH → HKDF → AES-GCM, stored with the SE key's opaque blob in `Application Support/Freewrite/vault.json` in the container (device-bound; sealing needs no prompt, opening needs the user). Each content key is also wrapped with a **recovery key** (160 random bits, shown as 8 groups of Crockford base32; HKDF, no password KDF needed) and that wrap is copied into every `.fwlock` header, so a locked file + the recovery key is all another Mac needs (no vault file has to travel with the entries folder). Keychain items with access control don't work in this ad-hoc/no-profile setup (-34018) and `keychain-access-groups` gets the app killed at launch: don't add it.

**Session (`NoteLockSession.shared`, `@MainActor @Observable`).** `unlock()` evaluates `LAContext` (reuse 10 s), opens the keyring with the SE key and keeps `cipher` in memory; all locked notes are then open. `lock()` drops the keys. Closes after `noteLockTimeoutMinutes` without key/mouse/scroll events in Freewrite (15 s timer; a recording voice note counts as activity), and on sleep / screens sleep / session resign / `com.apple.screenIsLocked`. `EntryStorage.versionStore` carries `cipher`; `EntryVersionStore` routes reads/writes of a locked entry through it (`readData`/`writeData`/`currentText`/`saveCurrentText`/`data(atRelativePath:)`, and `sealCurrent`, `attachVoiceNote`, `saveTranscript`), throwing `NoteLockError.locked` without keys. Injectable `NoteDeviceKeyProvider` (`SecureEnclaveKeyProvider` in the app, `SoftwareKeyProvider` in tests).

**Flows (ContentView).**
- Lock (`AppCommand.toggleNoteLock` ⌃⌘L, history row context menu, bottom-bar Lock): first time on this Mac → `RecoveryKeySheet(.setUp)` (Copy / Save to File… / "I saved it" before Lock Note) → `createVault` (no prompt). Later locks prompt once if closed. `EntryVersionStore.lock` encrypts each file, re-reads and verifies it, top-level file last, then deletes the plain files; any failure removes the encrypted copies. Blocked while transferring, recording, or a transcript is pending.
- Unlock Note… (same command on a locked note): confirm alert, prompt, then `EntryVersionStore.unlock`: reconcile leftovers (below), decrypt + write + verify every plain file (never overwriting a different plain file: `.plainCopyConflict`), then delete the top-level `.fwlock`. That one deletion is the switch: before it readers use the encrypted files (all still there), after it the plain ones (all written). Any failure up to it removes the plain copies written so far and the note stays locked; the UI flips to unlocked only on success. Nested `.fwlock` files are deleted last; ones that can't be are returned (stale, unread) and reported. All writes/deletes go through `EntryVersionStore.lockFileOperations` (`NoteLockFileOperations`; tests inject failures).
- Selecting a locked note while closed shows "This note is locked" + Unlock (prompt) in place of the editor; nothing is read. Open: decrypted to memory only (`openLockedNoteId`); autosave (`saveEntry`) writes only that note, encrypted, skipping unchanged text. On close, `text` is cleared after `openLockedNoteId` so nothing saves. A note locked on another Mac shows a hint to use the recovery key.
- History: lock icon + "Locked note" + date, no preview/badges. ⌘K: listed as "Locked note" (searchable by that and the date), never indexed; picking one prompts. Launch never selects a locked note (like videos). Sealed versions are viewed decrypted; voice notes play from memory (`AVAudioPlayer(data:)`). A voice note recorded into an open locked note is stored encrypted; its temp `.m4a` is kept only until transcription ends. PDF export only while open. `deleteEntry` removes the `.fwlock` (+ any leftover `.md`).
- Crash safety: if both `.md` and `.fwlock` exist, the loader lists the locked one (`hasNewerPlainCopy` when the `.md` is newer; the placeholder says its changes come back). `reconcileLeftoverPlainFiles` (on open and before unlocking): plain copies identical to the decrypted content are deleted; a newer, different top-level `.md` becomes the current text (the text it replaces is sealed as a version first, so nothing is lost); plain files in `Entries/<base>/` with no `.fwlock` are encrypted; anything else is left alone and reported.
- `StorageTransfer.isEntryFilename` accepts `.fwlock`; `Entries/` already moves nested `.fwlock` files.

**Settings › Privacy.** Locked-note count, open/locked + Lock Now, timeout picker, Show Recovery Key… (always prompts), Create New Recovery Key… (`NoteLockSession.replaceRecoveryKey(in:)`: gives **every** keyring key, including ones recovered from other Macs, the new recovery key; stages each locked file of the folder resealed as a hidden `.<name>.<uuid>.rekey` copy and verifies it (any failure: copies removed, nothing changed), then saves the vault, then renames the copies into place. From the vault save on the new key is shown even if some renames fail; `notUpdated` notes (and ones locked with a key this Mac lacks) still open with the old key and are named in the message. Older copies elsewhere still open with the old key), Unlock with Recovery Key… (`importKeys`: unwraps every wrap from the folder's `.fwlock` headers; adds new keys to the keyring; if vault.json is unreadable or its device key can't be used — e.g. restored from another Mac, `.deviceKeyUnusable` — it is copied to `vault-unusable-<date>.json` and a new vault with a fresh device key is built from the recovered keys), and the honest footnote. The recovery-key sheet is dismissed (and the key dropped) whenever locked notes close (`NoteLockSession.lockCount`, bumped by every `lock()`: idle, sleep, screen lock, Lock Now), when the pane disappears and when the Settings window closes.

**Caveats (also in the UI).** Plaintext from before locking can survive in Time Machine, iCloud Drive versions, other folders and free disk blocks (recommend FileVault); decrypted text is in memory while open; dates and version counts stay visible. Touch ID/Watch/password prompts can only be verified by hand.

## Video Recording Flow

1. User clicks video camera icon (🎥)
2. Camera icon switches to a small spinner while preflight runs
3. App requests/validates **all required permissions**: camera + microphone + speech recognition
4. If any permission is missing, recorder is **not** presented; a compact popover above the camera icon explains what is missing and links to System Settings
5. Once camera session is fully ready (plus a short presentation delay), `VideoRecordingView` is rendered via `.overlay` on top of `ContentView` with animations disabled for open/close (plain swap, no transition)
6. Camera preview fills the entire window content area edge-to-edge
7. Transparent bottom nav appears over video with: `Close`, recording status, recording control text (`Start Recording` / `Stop Recording`), and timer
8. User clicks "Start Recording"
   - Recording begins to temp file
   - Timer starts counting up
   - Button changes to "Stop Recording"
9. User clicks "Stop Recording"
   - Recording stops
   - Speech transcript is finalized (spacing + sentence endings/capitalization)
   - `onRecordingComplete` closure called with temp URL + finalized transcript
10. `saveVideoEntry(from:transcript:)` called
   - Creates per-entry video directory in `~/Documents/Freewrite/Videos/[UUID]-[date]/`
   - Video copied from temp to `~/Documents/Freewrite/Videos/[UUID]-[date]/[UUID]-[date].mov`
   - Thumbnail generated once and saved to `~/Documents/Freewrite/Videos/[UUID]-[date]/thumbnail.jpg`
   - Transcript saved to `~/Documents/Freewrite/Videos/[UUID]-[date]/transcript.md` when available
   - Metadata file created: `[UUID]-[date].md` with "Video Entry"
   - Entry added to `entries` array (on main thread), selected immediately, and loaded into the main view
   - Playback starts automatically with audio enabled
   - Overlay dismissed
11. If user clicks `Close` while recording, the temp recording is discarded and no entry is created; recorder dismisses first, then camera cleanup runs on disappear

## Video Playback Flow

1. User clicks video entry in sidebar
2. `loadEntry(entry:)` checks `entry.entryType`
3. If `.video`:
   - Sets `currentVideoURL` to video file path
   - Clears `text`
4. Main view checks `if let videoURL = currentVideoURL`
5. Shows `VideoPlayerView(videoURL:)` instead of `WritingEditor`
6. Video auto-plays muted with standard AVKit controls

## Entry Loading Logic

On app launch (`onAppear`):

1. `loadExistingEntries()` called
2. Reads all files from `~/Documents/Freewrite/`
3. Filters for canonical `.md` entries and derives expected `.mov` name from each `.md`
4. For each `.md` file:
   - Extracts UUID and date from filename via regex
   - Checks for corresponding `.mov` in this order:
     - `~/Documents/Freewrite/Videos/[entry-base]/[entry].mov` (current layout)
     - `~/Documents/Freewrite/Videos/[entry].mov` (legacy flat layout)
     - `~/Documents/Freewrite/[entry].mov` (oldest legacy layout)
   - Creates `HumanEntry` with appropriate type
5. Sorts entries by date (newest first)
6. Applies launch selection rules in order:
   - If newest entry is a video entry: create a new text entry and select it (never open directly into video on app launch)
   - Else if no entries: create welcome entry
   - Else if no empty entry exists for today (and app is not in the single-welcome-entry state): create a new empty entry
   - Else select the most recent empty entry from today (or the welcome entry if it's the only entry)

## Auto-Save Behavior

Text is auto-saved on every change:

```swift
.onChange(of: text) { _ in
    if let currentId = selectedEntryId,
       let currentEntry = entries.first(where: { $0.id == currentId }) {
        saveEntry(entry: currentEntry)
    }
}
```

## Permissions

Required entitlements in `freewrite.entitlements`:

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
<key>com.apple.security.files.bookmarks.app-scope</key>  <!-- persist the custom entries folder -->
<true/>
<key>com.apple.security.device.camera</key>
<true/>
<key>com.apple.security.device.audio-input</key>
<true/>
<key>com.apple.security.personal-information.speech-recognition</key>
<true/>
<key>com.apple.security.network.client</key>   <!-- Hex local API, model providers -->
<true/>
<key>com.apple.security.network.server</key>   <!-- loopback redirect of the ChatGPT sign-in -->
<true/>
```

The microphone is also used for voice notes; speech recognition is needed for Apple transcription of videos (live) and voice notes (from file), not for Hex.

Privacy usage descriptions (in Xcode project build settings):

```
INFOPLIST_KEY_NSCameraUsageDescription = "Freewrite needs camera access to record video entries."
INFOPLIST_KEY_NSMicrophoneUsageDescription = "Freewrite needs microphone access to record audio with your video entries."
INFOPLIST_KEY_NSSpeechRecognitionUsageDescription = "Freewrite uses speech recognition to transcribe your video entries."
```

## Technical Nuances & Implementation Details

### Threading Model

The app uses a **hybrid threading approach**:

1. **Main Thread**: All UI updates and `@State` mutations
2. **Global Queue**: File I/O operations (reading/writing markdown files)
3. **AVFoundation Queue**: Camera setup and video capture

**Critical Threading Issue**:
SwiftUI's `ForEach` creates an enumerator over the `entries` array. If you modify this array (insert, remove, replace) while the enumerator is active, you get `NSGenericException: Collection was mutated while being enumerated`.

**Solution Pattern**:
```swift
// When in async context (camera completion handler, DispatchQueue callback):
DispatchQueue.main.async {
    self.entries.insert(newEntry, at: 0)  // Safe
}

// When in loadExistingEntries:
let loadedEntries = mdFiles.compactMap { ... }  // Work on local copy
entries = loadedEntries  // Assign once to @State
// Now safe to check entries.contains, entries.first, etc.
```

### File System Architecture

**Why UUID + Timestamp Naming?**

The filename format `[UUID]-[YYYY-MM-DD-HH-mm-ss].md` serves multiple purposes:

1. **UUID**: Ensures global uniqueness even if multiple devices sync to same folder
2. **Timestamp**: Human-readable sorting in Finder without opening files
3. **Brackets**: Makes regex extraction reliable: `\\[(.*?)\\]` and `\\[(\\d{4}-\\d{2}-\\d{2}-\\d{2}-\\d{2}-\\d{2})\\]`

**File Loading Algorithm**:

```swift
// 1. Get all files
let fileURLs = try fileManager.contentsOfDirectory(at: documentsDirectory, ...)
let mdFiles = fileURLs.filter { $0.pathExtension == "md" }

// 2. Parse each .md file
let entriesWithDates = mdFiles.compactMap { fileURL -> (entry, date, content)? in
    // Extract UUID from filename using regex
    let uuidMatch = filename.range(of: "\\[(.*?)\\]", options: .regularExpression)
    let uuid = UUID(uuidString: String(filename[uuidMatch].dropFirst().dropLast()))

    // Extract timestamp
    let dateMatch = filename.range(of: "\\[(\\d{4}-\\d{2}-\\d{2}-\\d{2}-\\d{2}-\\d{2})\\]", ...)
    let dateString = String(filename[dateMatch].dropFirst().dropLast())

    // Parse date for sorting
    dateFormatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
    let fileDate = dateFormatter.date(from: dateString)

    // Check for corresponding video
    let videoFilename = filename.replacingOccurrences(of: ".md", with: ".mov")
    let hasVideo = hasVideoAsset(for: videoFilename) // checks current + legacy locations

    // Read content for preview
    let content = try String(contentsOf: fileURL, encoding: .utf8)
    let preview = content.replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
    let truncated = preview.isEmpty ? "" : String(preview.prefix(30)) + "..."

    return (entry: HumanEntry(...), date: fileDate, content: content)
}

// 3. Sort by actual date (not display date)
entries = entriesWithDates
    .sorted { $0.date > $1.date }  // Newest first
    .map { $0.entry }
```

**Why separate .md and .mov files instead of embedding?**

- User can open .md files in any text editor
- Video files can be played in QuickTime independently
- Easier to backup/sync text separately from large video files
- Transparent file format for user ownership
- Per-entry video directories keep each recording's media + thumbnail together

### Auto-Save State Machine

The app implements **continuous auto-save** with debouncing:

```swift
.onChange(of: text) { _ in
    if let currentId = selectedEntryId,
       let currentEntry = entries.first(where: { $0.id == currentId }) {
        saveEntry(entry: currentEntry)
    }
}
```

**State Transitions**:
1. User types character → `text` state updates
2. `.onChange` fires immediately
3. `saveEntry()` writes to disk synchronously (fast on SSD)
4. No loading spinner needed (happens in <10ms)

**Edge Case**: What if user switches entries before save completes?

```swift
Button(action: {
    if selectedEntryId != entry.id {
        // Save current entry BEFORE switching
        if let currentId = selectedEntryId,
           let currentEntry = entries.first(where: { $0.id == currentId }) {
            saveEntry(entry: currentEntry)
        }

        selectedEntryId = entry.id
        loadEntry(entry: entry)
    }
})
```

This ensures no data loss on rapid entry switching.

### Timer Implementation Details

The timer is **not a countdown** - it's a visual focus tool:

```swift
@State private var timeRemaining: Int = 900  // 15 minutes default
@State private var timerIsRunning = false

let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

.onReceive(timer) { _ in
    if timerIsRunning && timeRemaining > 0 {
        timeRemaining -= 1
    } else if timeRemaining == 0 {
        timerIsRunning = false
        // Show bottom nav again when timer expires
        bottomNavOpacity = 1.0
    }
}
```

**UI Behavior During Timer**:
- When timer starts: Bottom nav fades out after 1 second
- While running: Nav only appears on hover
- When timer ends: Nav fades back in

This creates **immersion** - the UI disappears, leaving only text and timer.

**Timer Adjustment**:
- Scroll wheel over timer: Adjust in 5-minute increments
- Click: Start/pause
- Double-click: Reset to 15 minutes

```swift
NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
    if isHoveringTimer {
        let scrollBuffer = event.deltaY * 0.25
        if abs(scrollBuffer) >= 0.1 {
            let currentMinutes = timeRemaining / 60
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, ...)
            let direction = -scrollBuffer > 0 ? 5 : -5
            let newMinutes = currentMinutes + direction
            let roundedMinutes = (newMinutes / 5) * 5
            timeRemaining = roundedMinutes * 60
        }
    }
    return event
}
```

### Backspace Disable Mechanism

**Implementation**:
```swift
@State private var backspaceDisabled = false

NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    if backspaceDisabled && (event.keyCode == 51 || event.keyCode == 117) {
        return nil  // Swallow the event
    }
    return event
}
```

**macOS Key Codes**:
- 51: Delete/Backspace key
- 117: Forward delete (fn+delete)

**Why this matters**: Forces users to write without editing, embracing imperfection and maintaining flow state.

### Video Recording Architecture

**AVFoundation Setup Sequence**:

```swift
// 1. Create session
captureSession = AVCaptureSession()

// 2. Get devices
let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
let audioDevice = AVCaptureDevice.default(for: .audio)

// 3. Create inputs
let videoInput = try AVCaptureDeviceInput(device: videoDevice)
let audioInput = try AVCaptureDeviceInput(device: audioDevice)

// 4. CRITICAL: Begin configuration
captureSession?.beginConfiguration()

// 5. Configure session
captureSession?.sessionPreset = .high
captureSession?.addInput(videoInput)
captureSession?.addInput(audioInput)

// 6. Add output
videoOutput = AVCaptureMovieFileOutput()
captureSession?.addOutput(videoOutput!)
audioDataOutput = AVCaptureAudioDataOutput()
audioDataOutput?.setSampleBufferDelegate(self, queue: speechQueue)
captureSession?.addOutput(audioDataOutput!)

// 7. CRITICAL: Commit configuration
captureSession?.commitConfiguration()

// 8. Start running on background thread
DispatchQueue.global(qos: .userInitiated).async {
    self.captureSession?.startRunning()
}
```

**Startup/Teardown Safety Rule**:
- Trigger camera setup from a single lifecycle path (avoid duplicate `checkPermissions()` calls for the same view presentation).
- Call `startRunning()` only once per configured session startup path.
- Guard setup with a dedicated in-flight flag (e.g. `isSettingUpSession`) so repeated permission callbacks/onAppear events cannot run parallel setup work.
- Attach/bind `AVCaptureVideoPreviewLayer` only after `startRunning()` completes to avoid concurrent session mutations during startup.
- During teardown, prefer `stopRunning()` + releasing references over removing inputs/outputs while the session may still be transitioning states.

**Why `beginConfiguration()` / `commitConfiguration()`?**

AVCaptureSession maintains internal arrays of inputs/outputs. When you call `addInput()` or `addOutput()`, it mutates these arrays. If the session is actively running or if another thread is enumerating these arrays (for validation, etc.), you get collection mutation crash.

`beginConfiguration()` tells the session: "I'm about to make multiple changes, don't validate or enumerate until I'm done."

`commitConfiguration()` tells the session: "I'm done, now validate everything and update internal state."

**Recording Flow**:

```swift
// Start recording
videoOutput.startRecording(to: tempURL, recordingDelegate: self)

// Delegate callback when done
func fileOutput(_ output: AVCaptureFileOutput,
                didFinishRecordingTo outputFileURL: URL,
                from connections: [AVCaptureConnection],
                error: Error?) {
    DispatchQueue.main.async {
        self.onRecordingComplete?(outputFileURL)
    }
}
```

**Temporary File Strategy**:
- Record to temp directory: `FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")`
- On completion: Copy to permanent location
- Why? If recording fails, temp file is auto-cleaned by OS

### Speech Transcription (Speech Framework)

Speech transcription in `VideoRecordingView` is implemented with Apple's `Speech` framework and runs in the background during recording:

1. Request speech auth with `SFSpeechRecognizer.requestAuthorization`.
2. Keep camera/video recording on `AVCaptureMovieFileOutput`.
3. Add `AVCaptureAudioDataOutput` to the same capture session and stream sample buffers to speech recognition.
4. Feed sample buffers into `SFSpeechAudioBufferRecognitionRequest` (`appendAudioSampleBuffer`).
5. Build partial + committed transcript text while recording (no live caption overlay rendered).
6. Finalize transcript on stop and persist it as `transcript.md` in that entry's video directory.

Key details:
- Camera, microphone, and speech recognition permissions are all required before opening the recorder.
- If any permission is denied, the app keeps the user in the writing view and shows a compact camera-icon popover with the missing permission(s).
- Transcription is started on recording start and stopped on recording stop.
- Final transcript formatting is applied at stop to improve readability before saving/copying.
- Video playback nav exposes `Copy Transcript` for saved video entries with a transcript file.
- App sandbox requires `com.apple.security.personal-information.speech-recognition` entitlement plus `NSSpeechRecognitionUsageDescription`.

### Transcription Engines (`Transcription.swift`)

Settings › Recording picks the engine (`UserDefaults["transcriptionEngine"]`); Apple uses the language in `appleTranscriptionLanguage` (`AppleSpeechLanguage.locale`, empty = the Mac's locale) for both live video and file transcription:
- **Apple (default)**: the live `SFSpeechRecognizer` pipeline above, on-device when supported. Speech permission is required to record.
- **Hex**: after the recording is saved, `HexTranscriber` decodes the audio to 16 kHz mono, cuts it into ~30 s pieces at quiet points, and POSTs WAV to the running Hex app's local API v2 (`/transcriptions?model=&language=`). Discovery file: `~/Library/Application Support/hex/local-api.json` (or legacy `voice-control/`), holding port + bearer token (never logged). Speech permission is optional; if already granted, Apple's live transcript is saved first and replaced when Hex finishes. Failures show briefly in the video bottom bar.
- Sandbox: Hex needs `com.apple.security.network.client` plus a read-only home-relative temporary exception for Hex's Application Support folders (fine for direct distribution; the Mac App Store would reject the temporary exception).

### Video Thumbnail Generation Nuances

```swift
func generateVideoThumbnail(from url: URL) -> NSImage? {
    let asset = AVAsset(url: url)
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true  // CRITICAL

    let cgImage = try imageGenerator.copyCGImage(at: CMTime(seconds: 0, preferredTimescale: 1), ...)
    return NSImage(cgImage: cgImage, size: NSSize(...))
}
```

**`appliesPreferredTrackTransform = true`**:

Videos recorded on front-facing camera are often rotated 90°. The video file contains a transform matrix that says "rotate this video when playing." Without `appliesPreferredTrackTransform`, the thumbnail would be sideways.

**Performance Note**: Thumbnails are generated once when a recording is saved and persisted as `thumbnail.jpg` in each entry's video directory. Sidebar rows load precomputed image files instead of extracting frames from `.mov` during render. For older entries without thumbnails, the app lazily generates once and saves for subsequent loads.

### Writing Editor (`WritingEditor.swift`, `MarkdownStyling.swift`)

The text editor is `WritingEditor`, an `NSViewRepresentable` wrapping a TextKit 2 `NSTextView` (`WritingTextView`) in a scroll view without scrollers. ContentView passes `text` (binding), the resolved font (`WritingEditor.font(named:size:)`: PostScript name → family → system font), `lineHeight` as line spacing, the theme text colour, `focusKey: selectedEntryId` and `canTakeFocus: !showingCommandPalette`.

- **Binding**: `textDidChange` pushes the string to `text` (autosave is still `.onChange(of: text)`). `updateNSView` only replaces the view's string when `text` differs from the last value it saw or `focusKey` (the entry) changes, even if the text is identical; that load resets the caret to the start, scrolls to top and clears the editor's own `UndoManager` (via `undoManager(for:)`). Ordinary SwiftUI updates never touch the selection.
- **Markdown styling** (syntax stays visible, markers dimmed): `MarkdownStyler.spans(in:range:)` returns UTF-16 `MarkdownSpan`s (headings, bold, italic, code, quote, list markers, strikethrough, links, `.syntax`) using line-local regexes. Inline patterns run on a copy of the lines with code spans and backslash escapes (`\*`, `\\`, …) blanked to U+0001, so escaped punctuation is never styled and emphasis can wrap code; the code span is applied after emphasis so its font wins only inside it. `MarkdownRenderer` turns them into attributes. Styling happens in `textStorage(_:didProcessEditing:...)` for `.editedCharacters` only and covers just the paragraph(s) of the edit; a full restyle runs on load and when font/size/theme change. Only attributes change, so the saved `.md` is byte-identical to what was typed, and attribute edits are not undoable. Lato Bold/Italic/BoldItalic are registered at launch for this; fonts without a face get synthesized bold/oblique.
- **Highlights**: `EditorHighlight(id:range:color:comment:title:titleColor:underlineColor:)` (UTF-16 range) via the `highlights:` parameter (produced from reviewer notes). Drawn as TextKit 2 rendering attributes (`.backgroundColor` on `NSTextLayoutManager`), so they never touch the storage or undo. TextKit 2 ignores underline rendering attributes, so `underlineColor` squiggles are drawn by `UnderlineOverlayView`, a non-clickable subview kept above the text fragment views that asks for the highlight segments on every redraw. Out-of-range highlights are ignored. Edits move them with `EditorHighlight.adjust(_:for:changeInLength:)` (pure, unit-tested). Hovering a highlight (tracking area → `characterIndexForInsertion` → segment rect) shows a themed `NSPopover` with the comment; it closes on exit, edit or scroll.
- **No Writing Tools**: `writingToolsBehavior = .none` (owner doesn't want Apple Intelligence on selections); keep it off.
- **Focus**: first responder when attached to the window, when `focusKey` changes, and when the palette closes.
- Accessibility label/identifier (`Entry text` / `editor`) are set on the `NSTextView`. The top 40pt padding is outside the editor so the hidden-title-bar area stays draggable; do not make it ignore the top safe area.

### Entry Creation Logic

**Complex Decision Tree**:

```swift
if entries.isEmpty {
    // First time user → create welcome entry
    createNewEntry()
} else if !hasEmptyEntryToday && !hasOnlyWelcomeEntry {
    // No empty entry for today → create new entry
    createNewEntry()
} else {
    // Select most recent empty entry from today
    if let todayEntry = entries.first(where: { isFromTodayAndEmpty }) {
        selectedEntryId = todayEntry.id
        loadEntry(entry: todayEntry)
    } else if hasOnlyWelcomeEntry {
        // Only have welcome entry → select it
        selectedEntryId = entries[0].id
        loadEntry(entry: entries[0])
    }
}
```

**Date Comparison Complexity**:

Display dates are "MMM d" (e.g., "Feb 20") without year. To check "is this from today?":

```swift
let dateFormatter = DateFormatter()
dateFormatter.dateFormat = "MMM d"
if let entryDate = dateFormatter.date(from: entry.date) {
    // entryDate is now "Feb 20" in year 1 (default year)
    // Need to add current year to compare
    var components = calendar.dateComponents([.year, .month, .day], from: entryDate)
    components.year = calendar.component(.year, from: Date())

    if let entryDateWithYear = calendar.date(from: components) {
        let entryDayStart = calendar.startOfDay(for: entryDateWithYear)
        let todayStart = calendar.startOfDay(for: Date())
        return calendar.isDate(entryDayStart, inSameDayAs: todayStart)
    }
}
```

This handles edge cases like February 29th on non-leap years.

### Font System

**Available Fonts**:
```swift
let standardFonts = ["Lato-Regular", "Arial", ".AppleSystemUIFont", "Times New Roman"]
let availableFonts = NSFontManager.shared.availableFontFamilies
```

**Random Font Button**:
- Picks random font from `availableFonts` (excludes standardFonts)
- Shows current random font in button: "Random [FontName]"
- Clicking again picks new random font

**Font Rendering**:
```swift
.font(.custom(selectedFont, size: fontSize))
```

`.custom()` falls back to system font if font not found, so app is resilient to missing fonts.

### Line Spacing Calculation

```swift
var lineHeight: CGFloat {
    let font = NSFont(name: selectedFont, size: fontSize) ?? .systemFont(ofSize: fontSize)
    let defaultLineHeight = getLineHeight(font: font)
    return (fontSize * 1.5) - defaultLineHeight
}

func getLineHeight(font: NSFont) -> CGFloat {
    let layoutManager = NSLayoutManager()
    return layoutManager.defaultLineHeight(for: font)
}
```

**Formula**: Target line height is 1.5× font size. Subtract natural line height to get spacing to add.

Example: 18px font → target 27px line height → natural 21px → add 6px spacing

This creates **generous vertical rhythm** for readability during long writing sessions.


### PDF Export Implementation

```swift
func exportEntryAsPDF(entry: HumanEntry) {
    let savePanel = NSSavePanel()
    savePanel.title = extractTitleFromContent(content, date: entry.date)
    savePanel.allowedContentTypes = [.pdf]

    if savePanel.runModal() == .OK {
        let pdfData = createPDF(from: content)
        try pdfData.write(to: savePanel.url!)
    }
}
```

**Title Extraction**:
- Takes first 4 words of content
- Removes punctuation
- Falls back to "Entry [date]" if content empty

### Theme System

```swift
@State private var colorScheme: ColorScheme = .light

// Apply to entire window
.preferredColorScheme(colorScheme)

// Persisted to UserDefaults
UserDefaults.standard.set(colorScheme == .light ? "light" : "dark", forKey: "colorScheme")
```

**Colors**:
- Light mode text: `Color(red: 0.20, green: 0.20, blue: 0.20)` (dark gray, not black, easier on eyes)
- Dark mode text: `Color(red: 0.9, green: 0.9, blue: 0.9)` (off-white, not pure white)

## Common Pitfalls

### Collection Mutation Crashes

**Problem**: Modifying `entries` array while SwiftUI is enumerating it.

**Solution**:
```swift
// BAD
entries.insert(newEntry, at: 0)

// GOOD (from async context)
DispatchQueue.main.async {
    self.entries.insert(newEntry, at: 0)
}
```

### AVCaptureSession Crashes

**Problem**: Session internals can crash with `Collection ... was mutated while being enumerated` when session startup/teardown overlaps (for example duplicate setup/start calls or mutating inputs/outputs during active transitions).

**Solution**:
```swift
captureSession?.beginConfiguration()
// Add/remove inputs and outputs here
captureSession?.sessionPreset = .high
captureSession?.addInput(videoInput)
captureSession?.commitConfiguration()
```

Also:
```swift
// Avoid duplicate startup paths for the same presentation
// and avoid repeated startRunning() calls on the same setup cycle.

if session.isRunning {
    session.stopRunning()
}
// Release session/output references without input/output removal churn.
```

### File Path Issues

Always derive paths from the current entries folder (it can change at runtime):
```swift
let fileURL = getDocumentsDirectory().appendingPathComponent(filename)  // EntryStorage.shared.rootURL
```

## Build Configuration

**Scheme**: freewrite
**Configuration**: Debug or Release
**Build Command**:
```bash
xcodebuild -project freewrite.xcodeproj -scheme freewrite -configuration Debug build
```

**Clean Build**:
```bash
xcodebuild -project freewrite.xcodeproj -scheme freewrite -configuration Debug clean build
```

## Testing Video Feature

1. Build and run app
2. Grant camera/microphone permissions when prompted
3. Click video camera icon in bottom nav
4. Click "Start Recording" (turns red)
5. Record for a few seconds
6. Click "Stop Recording"
7. Recorder overlay closes, new video entry is selected, and video opens immediately playing muted
8. Click video entry to play it

## Video Thumbnail Generation

```swift
func generateVideoThumbnail(from url: URL) -> NSImage? {
    let asset = AVAsset(url: url)
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true

    let cgImage = try imageGenerator.copyCGImage(at: CMTime(seconds: 0, preferredTimescale: 1), actualTime: nil)
    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
}
```

Generated at save time and stored in the per-entry video directory; sidebar loads this cached image file.

## Feature Flags / Settings

Stored in `UserDefaults` (keys in `SettingsKey`, read via `@AppStorage`):
- `colorScheme`: "light" or "dark"
- `fontName`, `fontSize`: writing font family/PostScript name and size
- `sessionMinutes`: timer length (default 15)
- `shortcuts`: JSON map of `AppCommand` → shortcut overrides
- `transcriptionEngine`: `apple` or `hex` (videos and voice notes)
- `appleTranscriptionLanguage`: locale id for Apple transcription (empty = automatic)
- `microphoneID`: `AVCaptureDevice.uniqueID` / Core Audio UID of the recording input (empty = system default)
- `reviewers`: JSON array of `ReviewerProfile` (missing = Mirror/Editor/Coach defaults)
- `settingsPane`: last Settings pane
- `noteLockTimeoutMinutes`: locked notes close after this many minutes without using Freewrite (1/5/15, default 5; 0 = only when the Mac sleeps)
- `storageFolderBookmark`: security-scoped bookmark of the custom entries folder (missing = default container folder); edited in Settings › Storage (path, Choose Folder…, Show in Finder, Use Default)

Session-only (not persisted): backspace state

## Future Development Notes

### Adding New Entry Types

1. Add case to `EntryType` enum
2. Update `HumanEntry` with relevant properties
3. Modify `loadExistingEntries()` to detect new file type
4. Update `loadEntry()` to handle new type
5. Add UI in main view for new entry type
6. Update `deleteEntry()` to clean up new file types

### Adding New Navigation Items

Add to bottom nav in ContentView.swift around line 500-950:

```swift
Text("•")
    .foregroundColor(.gray)

Button(action: {
    // Your action
}) {
    Image(systemName: "icon.name") // or Text("Label")
        .foregroundColor(isHovering ? textHoverColor : textColor)
}
.buttonStyle(.plain)
.onHover { hovering in
    isHovering = hovering
    isHoveringBottomNav = hovering
    if hovering {
        NSCursor.pointingHand.push()
    } else {
        NSCursor.pop()
    }
}
```

## Debugging

Enable console output in Xcode to see:
- File loading: "Processing: [filename]"
- Entry creation: "Successfully created video entry"
- Errors: "Error saving video entry: ..."

Check `~/Documents/Freewrite/` in Finder to verify files are being created.

## Code Organization

- **Lines 1-130**: Imports, models, state variables
- **Lines 130-430**: Computed properties and helpers
- **Lines 430-1200**: Main view body and UI
- **Lines 1200-1400**: Helper functions (save, load, delete, etc.)

## Key SwiftUI Patterns Used

- `@State` for local view state
- `@StateObject` for CameraManager
- `.overlay { if showingVideoRecording { ... } }` for immersive video recording
- `.onChange(of:)` for auto-save
- `.onAppear` for initialization
- `ForEach(entries)` with `Identifiable` for list rendering
- Conditional views: `if currentVideoURL != nil { VideoPlayerView } else { WritingEditor }`

## Summary

Freewrite is a straightforward macOS writing app with video recording capabilities. All data is local, no backend required. The main complexity is in:

1. Proper file management and UUID-based naming
2. Thread-safe array mutations for entries
3. AVFoundation camera setup with proper configuration blocks
4. Conditional rendering between text and video content

When making changes, always:
- Test with actual video recording
- Check for collection mutation crashes
- Verify files are created in correct location
- Ensure privacy permissions are properly configured
