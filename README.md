# Freewrite

A distraction-free Mac app for freewriting, with video and voice journaling on the side.
Open it and start typing. The timer runs, the interface fades away and every keystroke is saved
as plain Markdown on your Mac.

This is a fork of [farzaa/freewrite](https://github.com/farzaa/freewrite) with a rebuilt editor,
versions, voice notes, transcription, local AI agents that comment on your writing, and a lot more settings.

## Features

- **Write without friction**: a new entry every day, autosave on every keystroke, no "New Document" dialog.
- **Focus timer** (15 minutes by default; scroll over it to adjust). The bar hides while it runs.
- **Backspace lock**: turn off Delete to keep moving forward instead of editing.
- **Markdown-styled editor**: headings, bold, italic, code, quotes, lists and links are styled as you type. The syntax stays visible and the file stays plain Markdown.
- **Versions**: seal the current page and start the next version blank or from any earlier one. The version menu shows them as a tree, and older versions stay readable.
- **Voice notes**: record audio for a version; it's transcribed and the text is added to the entry.
- **Video entries**: record from the camera, with a thumbnail and a transcript saved next to the movie.
- **Transcription on your Mac**: Apple's on-device speech recognition (pick the language), or [Hex](https://hex.kitlangton.com) running locally.
- **⌘K palette**: full-text search across entries, versions and video transcripts, plus every action.
- **Customizable bottom bar**: choose which controls show, on which side and in what order.
- **Keyboard shortcuts** for every action, editable in Settings.
- **Your folder**: keep entries in the app's container or any folder you choose (Documents, iCloud Drive…). Freewrite moves or copies them for you.
- **Agents that comment, never rewrite**: connect Claude Code, Codex, OpenCode, Claude Desktop, Cursor or any local MCP client. They read your entries, highlight passages, leave notes in the comment margin and post a reply. They can't change your text.
- **Prompts**: Friend and Mentor (Farza's original ChatGPT and Claude prompts) and Editor come built in. Write your own in Settings; agents get them as MCP prompts.
- **Comment margin**: notes sit beside the passage they're about, show which agent wrote them, and can be resolved, dismissed or have their highlight hidden.
- **Links into the app**: agents give you `freewrite://` or `http://127.0.0.1:29890/…` links that open an entry, a version or a quoted passage.
- **Settings as a file**: `settings.json` in your entries folder mirrors your settings both ways, so you or an agent can edit prompts, templates and fonts there.
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

## Connect an agent

1. Open **Settings › Agents** and click **Connect** next to your agent.
2. Copy the command or config it shows. For Claude Code that's
   `claude mcp add freewrite -s user -- /Applications/Freewrite.app/Contents/MacOS/freewrite mcp --client claude-code --token fw_…`.
3. Ask your agent to read your open entry, or use a prompt: in Claude Code, type `/mcp__freewrite__mentor`.

The agent talks to Freewrite over stdio. If Freewrite isn't running, it opens in the background.
The ✦ menu in the bottom bar lists your connected agents and when each one last called Freewrite.
**Disconnect** in Settings revokes an agent's token.

## Where your data lives

Everything is a regular file you can open without Freewrite:

```
Freewrite/
  settings.json                       your settings (edit it by hand or through an agent)
  [UUID]-[2026-02-20-08-01-04].md     the current text of an entry
  Entries/[UUID]-[…]/                 sealed versions, voice notes (.m4a) and their transcripts,
                                      notes (annotations.json), agent replies (reviews/)
                                      and an append-only history of every step (log.jsonl)
  Videos/[UUID]-[…]/                  the .mov, thumbnail.jpg and transcript.md of a video entry
```

By default this folder is `~/Library/Containers/app.humansongs.freewrite/Data/Documents/Freewrite/`.
Choose another one in **Settings › Storage**.

## Privacy

Freewrite has no account, no server and no analytics. Entries, recordings and transcripts stay on
your Mac. Freewrite has no AI built in. Agents only reach it while you have one connected, through a port that listens
on 127.0.0.1 only. They need a token, and they never see locked notes or video entries. What an agent
then sends to its own model is up to that agent. Transcription runs on-device with Apple's speech recognition (never Apple's servers: if your language
has no on-device model, Apple transcription is skipped) or through Hex's local API.
The camera, microphone and speech recognition are only requested when you first use a feature
that needs them; **Settings › Permissions** shows what's allowed.

## Credits

Freewrite was created by [Farza](https://github.com/farzaa) ([original project](https://github.com/farzaa/freewrite)).
This fork builds on that work.

## License

MIT. See [LICENSE](LICENSE).
