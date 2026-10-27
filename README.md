# Freewrite

A distraction-free Mac app for freewriting, with video and voice journaling on the side.
Open it and start typing. The timer runs, the interface fades away and every keystroke is saved
as plain Markdown on your Mac.

This is a fork of [farzaa/freewrite](https://github.com/farzaa/freewrite) with a rebuilt editor,
versions, voice notes, transcription and a lot more settings.

## Features

- **Write without friction**: a new entry every day, autosave on every keystroke, no "New Document" dialog.
- **Focus timer** (15 minutes by default; scroll over it to adjust). The bar hides while it runs.
- **Backspace lock**: turn off Delete to keep moving forward instead of editing.
- **Markdown-styled editor**: headings, bold, italic, code, quotes, lists and links are styled as you type. The syntax stays visible and the file stays plain Markdown.
- **Versions**: seal the current page as v1 and start fresh on v2. Older versions stay readable.
- **Voice notes**: record audio for a version; it's transcribed and the text is added to the entry.
- **Video entries**: record from the camera, with a thumbnail and a transcript saved next to the movie.
- **Transcription on your Mac**: Apple's on-device speech recognition (pick the language), or [Hex](https://hex.kitlangton.com) running locally.
- **⌘K palette**: full-text search across entries, versions and video transcripts, plus every action.
- **Customizable bottom bar**: choose which controls show, on which side and in what order.
- **Keyboard shortcuts** for every action, editable in Settings.
- **Your folder**: keep entries in the app's container or any folder you choose (Documents, iCloud Drive…). Freewrite moves or copies them for you.
- Fonts, text size, light and dark themes, a microphone picker and a permissions overview in Settings (⌘,).

## Requirements

- macOS 26 or later
- Xcode 26 or later to build

## Build

```bash
git clone https://github.com/jeremyosih/freewrite.git
cd freewrite
xcodebuild -project freewrite.xcodeproj -scheme freewrite -configuration Debug build
```

Or open `freewrite.xcodeproj` in Xcode and press Run.

## Where your data lives

Everything is a regular file you can open without Freewrite:

```
Freewrite/
  [UUID]-[2026-02-20-08-01-04].md     the current text of an entry
  Entries/[UUID]-[…]/                 sealed versions, voice notes (.m4a) and their transcripts
  Videos/[UUID]-[…]/                  the .mov, thumbnail.jpg and transcript.md of a video entry
```

By default this folder is `~/Library/Containers/app.humansongs.freewrite/Data/Documents/Freewrite/`.
Choose another one in **Settings › Storage**.

## Privacy

Freewrite has no account, no server and no analytics. Entries, recordings and transcripts stay on
your Mac. Transcription runs on-device with Apple's speech recognition or through Hex's local API.
The camera, microphone and speech recognition are only requested when you first use a feature
that needs them; **Settings › Permissions** shows what's allowed.

## Credits

Freewrite was created by [Farza](https://github.com/farzaa) ([original project](https://github.com/farzaa/freewrite)).
This fork builds on that work.

## License

MIT. See [LICENSE](LICENSE).
