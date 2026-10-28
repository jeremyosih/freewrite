//
//  EntryLog.swift
//  freewrite
//
//  Every step taken on an entry, append-only: `Entries/<base>/log.jsonl`, one JSON object per
//  line, never rewritten. Who did it (you or an agent, and who the agent wrote as), what, on
//  which version (and, for a new version, which one it started from), so the history lines up
//  with the version tree. The text itself isn't copied in: versions already keep it.
//

import Foundation

struct EntryEvent: Codable, Equatable, Sendable {
    enum Op: String, Codable, Sendable {
        case versionCreate = "version.create"
        case noteAdd = "note.add"
        case noteUpdate = "note.update"
        case noteRemove = "note.remove"
        case noteResolve = "note.resolve"
        case noteReopen = "note.reopen"
        case noteDismiss = "note.dismiss"
        case notesClear = "notes.clear"
        case replyPost = "reply.post"
    }

    var at: Date
    /// "user", or the agent's id ("claude-code").
    var actor: String
    /// Who an agent wrote as ("Mentor").
    var author: String? = nil
    var op: Op
    /// The version the step happened on (for version.create: the new one).
    var version: String?
    /// version.create: the version it started from (nil = blank); also the one sealed.
    var from: String? = nil
    var sealed: String? = nil
    /// The note it's about.
    var note: String? = nil
    /// A short human line: the note's label and quote, a resolve reason, how many were cleared.
    var detail: String? = nil

    static let user = "user"
}

extension EntryVersionStore {
    static let logFilename = "log.jsonl"

    func logURL(for entryFilename: String) -> URL {
        entryDirectory(for: entryFilename).appendingPathComponent(Self.logFilename)
    }

    /// Appends one event. Logging never fails the step it records: errors are printed.
    func appendLog(_ event: EntryEvent, for entryFilename: String) {
        let url = logURL(for: entryFilename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            var line = try encoder.encode(event)
            line.append(UInt8(ascii: "\n"))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
        } catch {
            print("Log: couldn't append to \(entryFilename): \(error)")
        }
    }

    /// The entry's events, oldest first. Unreadable lines are skipped.
    func log(for entryFilename: String) -> [EntryEvent] {
        guard let data = try? Data(contentsOf: logURL(for: entryFilename)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(EntryEvent.self, from: Data($0)) }
    }
}

extension EntryEvent {
    /// One line for agents and people: "2026-10-28 16:40 · claude-code as Mentor · note.add an_1 on v2: tension "…"".
    var summary: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var who = actor
        if let author { who += " as \(author)" }
        var what = op.rawValue
        if let note { what += " \(note)" }
        if let version { what += " on \(version)" }
        if op == .versionCreate {
            what += from.map { " from \($0)" } ?? " (blank)"
        }
        if let detail, !detail.isEmpty { what += ": \(detail)" }
        return "\(formatter.string(from: at)) · \(who) · \(what)"
    }
}
