//
//  AgentLinks.swift
//  freewrite
//
//  Links into the app, for agents to hand out and for you to click:
//    freewrite://e/<entry-uuid>[/<version>][/n/<note-id>][?q=<quote>&p=<prefix>&s=<suffix>]
//  and the same path on the agent server, `http://127.0.0.1:29890/e/…`, which terminals and chat
//  apps always make clickable. Links only navigate: none of them changes or sends anything.
//

import AppKit
import Combine
import Foundation

struct FreewriteLink: Equatable, Sendable {
    var entryId: UUID
    /// "v2"; nil = the entry's current version.
    var versionId: String?
    /// A note (or review summary) to activate in the comment margin.
    var noteId: String?
    /// A passage to scroll to and flash, located like a text fragment.
    var quote: String?
    var prefix: String?
    var suffix: String?

    static let scheme = "freewrite"

    /// Accepts `freewrite://e/…`, `http://127.0.0.1:<port>/e/…` or a bare path `/e/…`.
    init?(url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var parts: [String]
        if url.scheme == Self.scheme {
            // freewrite://e/<uuid>/…: "e" is the host.
            parts = [url.host ?? ""] + url.pathComponents.filter { $0 != "/" }
        } else {
            parts = url.pathComponents.filter { $0 != "/" }
        }
        guard parts.count >= 2, parts[0] == "e", let id = UUID(uuidString: parts[1]) else { return nil }
        entryId = id
        parts.removeFirst(2)
        if let first = parts.first, first.hasPrefix("v"), Int(first.dropFirst()) != nil {
            versionId = first
            parts.removeFirst()
        }
        if parts.count >= 2, parts[0] == "n" {
            noteId = parts[1]
        }
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        quote = value("q")
        prefix = value("p")
        suffix = value("s")
    }

    init(entryId: UUID, versionId: String? = nil, noteId: String? = nil, quote: String? = nil, prefix: String? = nil, suffix: String? = nil) {
        self.entryId = entryId
        self.versionId = versionId
        self.noteId = noteId
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
    }

    /// "/e/<uuid>/v2/n/<id>?q=…", shared by both link forms.
    var path: String {
        var path = "/e/\(entryId.uuidString)"
        if let versionId { path += "/\(versionId)" }
        if let noteId { path += "/n/\(Self.escapePath(noteId))" }
        var query: [URLQueryItem] = []
        if let quote { query.append(URLQueryItem(name: "q", value: quote)) }
        if let prefix { query.append(URLQueryItem(name: "p", value: prefix)) }
        if let suffix { query.append(URLQueryItem(name: "s", value: suffix)) }
        if !query.isEmpty {
            var components = URLComponents()
            components.queryItems = query
            // `+` and `&` inside a quote must not read as separators.
            let encoded = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
            path += "?" + encoded
        }
        return path
    }

    /// freewrite://e/… (opens the app directly).
    var appURL: String { "\(Self.scheme):/" + path }
    /// http://127.0.0.1:29890/e/… (clickable everywhere; the agent server opens it in the app).
    var webURL: String { "http://127.0.0.1:\(AgentServer.port)" + path }

    /// Both forms, for tool results.
    var description: String { "\(webURL)  (or \(appURL))" }

    private static func escapePath(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }

    /// Where `quote` sits in `text` (UTF-16), preferring the occurrence with the given context.
    static func range(of quote: String, prefix: String?, suffix: String?, in text: String) -> NSRange? {
        let string = text as NSString
        var candidates: [NSRange] = []
        var search = NSRange(location: 0, length: string.length)
        while true {
            let found = string.range(of: quote, options: [], range: search)
            guard found.location != NSNotFound else { break }
            candidates.append(found)
            let next = found.location + max(found.length, 1)
            guard next < string.length else { break }
            search = NSRange(location: next, length: string.length - next)
        }
        if candidates.isEmpty {
            let found = string.range(of: quote, options: [.caseInsensitive, .diacriticInsensitive])
            return found.location == NSNotFound ? nil : found
        }
        func score(_ range: NSRange) -> Int {
            var score = 0
            if let prefix, !prefix.isEmpty {
                let start = max(range.location - (prefix as NSString).length, 0)
                if string.substring(with: NSRange(location: start, length: range.location - start)).hasSuffix(prefix) { score += 1 }
            }
            if let suffix, !suffix.isEmpty {
                let length = min((suffix as NSString).length, string.length - NSMaxRange(range))
                if string.substring(with: NSRange(location: NSMaxRange(range), length: length)).hasPrefix(suffix) { score += 1 }
            }
            return score
        }
        return candidates.max { score($0) < score($1) }
    }
}

/// Hands clicked links to the writing window.
@MainActor
final class AgentLinks {
    static let shared = AgentLinks()

    /// The writing window navigates to each link it gets.
    let requests = PassthroughSubject<FreewriteLink, Never>()

    /// Brings Freewrite forward and asks the writing window to show `link`.
    func open(_ link: FreewriteLink) {
        NSApp.activate()
        requests.send(link)
    }
}
