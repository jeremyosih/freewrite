//
//  AgentServer.swift
//  freewrite
//
//  The agent server: listens on 127.0.0.1:29890 (loopback only), like Paper's. Two kinds of
//  connection:
//  - `freewrite mcp` relays (AgentRelay.swift): a hello line with the client's token, then MCP
//    JSON-RPC, one message per line, answered by `AgentTools`.
//  - `GET /e/…` from a clicked http link: opens that place in the app and answers a tiny page.
//  Everything runs on the main queue: tools read small files and the traffic is one person's.
//

import AppKit
import Foundation
import Network
import Security

// MARK: - Clients

/// Agents you can connect, each with its own token (so notes and logs say who did what, and one
/// can be disconnected without the others).
enum AgentClient: String, CaseIterable, Identifiable, Codable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case openCode = "opencode"
    case claudeDesktop = "claude-desktop"
    case cursor
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .openCode: return "OpenCode"
        case .claudeDesktop: return "Claude Desktop"
        case .cursor: return "Cursor"
        case .other: return "Other agent"
        }
    }

    /// Black-and-white mark in Assets.xcassets/ClientLogos (template images, from the canmy.ai client
    /// logo sheet); nil for "other", which shows a plain symbol rather than a guessed logo.
    var logoAssetName: String? {
        self == .other ? nil : "ClientLogos/\(rawValue)"
    }

    /// The client whose name a byline ends with ("Mentor · Claude Code" → Claude Code).
    static func named(in byline: String) -> AgentClient? {
        allCases.first { $0 != .other && byline.hasSuffix($0.title) }
    }
}

struct AgentClientRecord: Codable, Equatable, Sendable {
    var token: String
    var lastSeen: Date?
}

/// Tokens per client, in `UserDefaults["agentClients"]`. A client without a record isn't connected.
enum AgentClientStore {
    static let key = "agentClients"

    static func load(_ defaults: UserDefaults = .standard) -> [AgentClient: AgentClientRecord] {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode([String: AgentClientRecord].self, from: data) else { return [:] }
        var records: [AgentClient: AgentClientRecord] = [:]
        for (raw, record) in stored {
            if let client = AgentClient(rawValue: raw) { records[client] = record }
        }
        return records
    }

    static func save(_ records: [AgentClient: AgentClientRecord], _ defaults: UserDefaults = .standard) {
        let stored = Dictionary(uniqueKeysWithValues: records.map { ($0.key.rawValue, $0.value) })
        defaults.set(try? JSONEncoder().encode(stored), forKey: key)
    }

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "fw_" + bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Server

@MainActor
@Observable
final class AgentServer {
    static let shared = AgentServer()
    /// Fixed, like Paper's 29979, so relays and links always know where to go.
    nonisolated static let port: UInt16 = 29890

    private(set) var records: [AgentClient: AgentClientRecord] = AgentClientStore.load()
    private(set) var isListening = false
    /// Why the server isn't listening (port taken, …), for Settings › Agents.
    private(set) var problem: String?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [ObjectIdentifier: AgentConnection] = [:]
    @ObservationIgnored let sessions = AgentSessions()

    var hasClients: Bool { !records.isEmpty }

    // MARK: Lifecycle

    /// Listens while at least one client is connected (agent access is off until you connect one).
    func update() {
        if hasClients { start() } else { stop() }
    }

    private func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            problem = "Couldn't listen on port \(Self.port): \(error.localizedDescription)"
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        isListening = false
        for connection in connections.values { connection.close() }
        connections = [:]
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            isListening = true
            problem = nil
        case .failed(let error):
            isListening = false
            problem = "Port \(Self.port) is in use or blocked (\(error.localizedDescription)). Quit other copies of Freewrite and try again."
            listener?.cancel()
            listener = nil
        case .cancelled:
            isListening = false
        default:
            break
        }
    }

    private func accept(_ nw: NWConnection) {
        let connection = AgentConnection(nw, server: self)
        connections[ObjectIdentifier(connection)] = connection
        connection.start()
    }

    func forget(_ connection: AgentConnection) {
        connections[ObjectIdentifier(connection)] = nil
    }

    // MARK: Clients

    /// Creates (or keeps) the client's token and starts listening.
    @discardableResult
    func connect(_ client: AgentClient) -> AgentClientRecord {
        if let record = records[client] { return record }
        let record = AgentClientRecord(token: AgentClientStore.newToken())
        records[client] = record
        AgentClientStore.save(records)
        update()
        return record
    }

    func rotateToken(_ client: AgentClient) {
        records[client] = AgentClientRecord(token: AgentClientStore.newToken())
        AgentClientStore.save(records)
    }

    func disconnect(_ client: AgentClient) {
        records[client] = nil
        AgentClientStore.save(records)
        update()
    }

    /// The client a hello's token belongs to, if any; marks it seen.
    func authenticate(token: String) -> AgentClient? {
        guard let client = records.first(where: { $0.value.token == token })?.key else { return nil }
        records[client]?.lastSeen = Date()
        AgentClientStore.save(records)
        return client
    }

    func touch(_ client: AgentClient) {
        // At most one write a minute: "last call 2 min ago" doesn't need more.
        if let seen = records[client]?.lastSeen, Date().timeIntervalSince(seen) < 60 { return }
        records[client]?.lastSeen = Date()
        AgentClientStore.save(records)
    }

    // MARK: MCP

    /// Answers one JSON-RPC message (nil for notifications).
    func handle(_ message: JSONValue, client: AgentClient?) -> JSONValue? {
        let id = message["id"]
        guard let method = message["method"]?.string else { return nil }
        // Notifications (no id) need no answer.
        guard let id, id != .null else { return nil }
        guard let client else {
            return Self.error(id: id, code: -32001, "This Freewrite connection isn't valid any more. Reconnect the agent in Freewrite › Settings › Agents.")
        }
        touch(client)
        let tools = AgentTools(catalog: AgentCatalog(root: EntryStorage.shared.rootURL), focus: AgentFocus.shared,
                               client: client, sessions: sessions)
        let params = message["params"] ?? .object([:])
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.string
            let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]
            return Self.result(id: id, .object([
                "protocolVersion": .string(requested.flatMap { supported.contains($0) ? $0 : nil } ?? supported[0]),
                "capabilities": .object(["tools": .object([:]), "prompts": .object([:])]),
                "serverInfo": .object(["name": .string("freewrite"), "version": .string(AppVersion.short)]),
                "instructions": .string(AgentTools.instructions),
            ]))
        case "ping":
            return Self.result(id: id, .object([:]))
        case "tools/list":
            return Self.result(id: id, .object(["tools": .array(AgentTools.definitions)]))
        case "tools/call":
            let name = params["name"]?.string ?? ""
            do {
                let text = try tools.call(name, params["arguments"] ?? .object([:]))
                return Self.result(id: id, Self.content(text, isError: false))
            } catch {
                return Self.result(id: id, Self.content(error.localizedDescription, isError: true))
            }
        case "prompts/list":
            let prompts = AgentTools.prompts().map { prompt -> JSONValue in
                .object([
                    "name": .string(prompt.name),
                    "title": .string(prompt.prompt.name),
                    "description": .string("\(prompt.prompt.name), with the entry open in Freewrite (or the one you name)."),
                    "arguments": .array([.object([
                        "name": .string("entry"),
                        "description": .string("Entry id or link (default: the entry open in Freewrite)"),
                        "required": .bool(false),
                    ])]),
                ])
            }
            return Self.result(id: id, .object(["prompts": .array(prompts)]))
        case "prompts/get":
            let name = params["name"]?.string ?? ""
            do {
                let text = try tools.promptText(name: name, entryArgument: params["arguments"]?["entry"]?.string)
                return Self.result(id: id, .object([
                    "messages": .array([.object([
                        "role": .string("user"),
                        "content": .object(["type": .string("text"), "text": .string(text)]),
                    ])]),
                ]))
            } catch {
                return Self.error(id: id, code: -32602, error.localizedDescription)
            }
        default:
            return Self.error(id: id, code: -32601, "Freewrite doesn't support \(method).")
        }
    }

    private static func content(_ text: String, isError: Bool) -> JSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(isError),
        ])
    }

    private static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    static func error(id: JSONValue, code: Int, _ message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }

    // MARK: Links

    /// `GET /e/…`: opens the place in the app. Anything else is a 404.
    func httpResponse(method: String, path: String) -> (status: String, body: String) {
        guard method == "GET" || method == "HEAD" else { return ("405 Method Not Allowed", "Only links.") }
        guard let url = URL(string: "http://127.0.0.1" + path), let link = FreewriteLink(url: url) else {
            return ("404 Not Found", Self.page("Freewrite", "That isn't a Freewrite link."))
        }
        AgentLinks.shared.open(link)
        return ("200 OK", Self.page("Opened in Freewrite", "You can close this tab."))
    }

    private static func page(_ title: String, _ message: String) -> String {
        """
        <!doctype html><meta charset="utf-8"><title>\(title)</title>
        <body style="font: 15px -apple-system, sans-serif; margin: 20vh auto; max-width: 28em; text-align: center; color: #333">
        <p><b>\(title)</b></p><p>\(message)</p><script>setTimeout(() => window.close(), 400)</script></body>
        """
    }
}

// MARK: - One connection

@MainActor
final class AgentConnection {
    private let nw: NWConnection
    private weak var server: AgentServer?
    private var buffer = Data()
    private var mode: Mode = .unknown
    private var client: AgentClient?

    private enum Mode { case unknown, relay, http }

    init(_ nw: NWConnection, server: AgentServer) {
        self.nw = nw
        self.server = server
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.finish()
                default: break
                }
            }
        }
        nw.start(queue: .main)
        receive()
    }

    func close() {
        nw.cancel()
    }

    private func finish() {
        server?.forget(self)
    }

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.process()
                }
                if isComplete || error != nil {
                    self.nw.cancel()
                } else {
                    self.receive()
                }
            }
        }
    }

    private func process() {
        if mode == .unknown {
            guard buffer.count >= 4 else { return }
            let head = String(decoding: buffer.prefix(5), as: UTF8.self)
            mode = head.hasPrefix("GET ") || head.hasPrefix("HEAD") || head.hasPrefix("POST") ? .http : .relay
        }
        switch mode {
        case .http: processHTTP()
        case .relay: processLines()
        case .unknown: break
        }
    }

    // MARK: Relay

    private func processLines() {
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") }) else { continue }
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line)) else {
                send(AgentServer.error(id: .null, code: -32700, "Couldn't parse that message."))
                continue
            }
            // The relay's first line: {"freewrite": "hello", "client": "…", "token": "…"}.
            if message["freewrite"]?.string == "hello" {
                client = server?.authenticate(token: message["token"]?.string ?? "")
                continue
            }
            if let reply = server?.handle(message, client: client) {
                send(reply)
            }
        }
    }

    private func send(_ message: JSONValue) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(UInt8(ascii: "\n"))
        nw.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: HTTP links

    private func processHTTP() {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 16_384 { nw.cancel() }
            return
        }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        buffer.removeAll()
        let requestLine = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let path = parts.count > 1 ? String(parts[1]) : "/"
        let (status, body) = server?.httpResponse(method: method, path: path) ?? ("503 Service Unavailable", "")
        let bodyData = Data(body.utf8)
        var response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var data = Data(response.utf8)
        if method != "HEAD" { data.append(bodyData) }
        nw.send(content: data, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.nw.cancel() }
        })
    }
}
