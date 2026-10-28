//
//  AgentsSettingsView.swift
//  freewrite
//
//  Settings › Agents: connect local agents (Claude Code, Codex, OpenCode, …) to Freewrite.
//  Each client gets a one-line command or config snippet with its own token; the row turns green
//  the moment that agent makes its first call. Agents read; they can't change your writing.
//

import AppKit
import SwiftUI

/// A client's logo, tinted like text (template image), or a terminal symbol for "other".
struct AgentClientLogo: View {
    let client: AgentClient
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let name = client.logoAssetName {
                Image(name)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "terminal")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The connected agents and when each last called Freewrite (the ✦ menu). Times refresh while open.
struct ConnectedAgentsList: View {
    private let server = AgentServer.shared

    var body: some View {
        let clients = AgentClient.allCases.filter { server.records[$0] != nil }
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 7) {
                if clients.isEmpty {
                    Text("No agents connected. Connect one in Settings › Agents.")
                        .font(.system(size: 12))
                        .opacity(0.55)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(clients) { client in
                    HStack(spacing: 8) {
                        AgentClientLogo(client: client, size: 14)
                            .opacity(0.85)
                        Text(client.title)
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(lastCall(client, now: context.date))
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .opacity(0.5)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func lastCall(_ client: AgentClient, now: Date) -> String {
        guard let seen = server.records[client]?.lastSeen else { return "no calls yet" }
        if now.timeIntervalSince(seen) < 60 { return "just now" }
        return seen.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

struct AgentsSettingsView: View {
    private let server = AgentServer.shared
    @State private var connecting: AgentClient?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SettingsFootnote("Let AI agents on this Mac read your entries and point you to passages with links. They start from the entry open in Freewrite. They can't change your writing, and locked notes are never shared.")
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)

                if let problem = server.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4)
                }
                if let warning = Self.locationWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4)
                }

                SettingsCard {
                    ForEach(AgentClient.allCases) { client in
                        row(client)
                    }
                }

                SettingsFootnote("Agents only work while Freewrite is open; if it's closed, connecting opens it in the background. Agents can see every entry that isn't locked.")
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .sheet(item: $connecting) { client in
            ConnectSheet(client: client) { connecting = nil }
        }
    }

    private func row(_ client: AgentClient) -> some View {
        SettingsCardRow {
            HStack(spacing: 8) {
                AgentClientLogo(client: client, size: 16)
                    .foregroundStyle(.primary)
                Text(client.title)
            }
            status(client)
                .padding(.leading, 24)
        } control: {
            if server.records[client] != nil {
                HStack(spacing: 6) {
                    Button("Setup…") { connecting = client }
                    Menu {
                        Button("New Token") {
                            server.rotateToken(client)
                            connecting = client
                        }
                        Button("Disconnect", role: .destructive) { server.disconnect(client) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("More for \(client.title)")
                }
            } else {
                Button("Connect") {
                    server.connect(client)
                    connecting = client
                }
                .accessibilityIdentifier("connect-\(client.rawValue)")
            }
        }
    }

    @ViewBuilder
    private func status(_ client: AgentClient) -> some View {
        if let record = server.records[client] {
            if let seen = record.lastSeen {
                Label("Connected · last call \(seen.formatted(.relative(presentation: .named)))", systemImage: "circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                    .imageScale(.small)
            } else {
                Label("Waiting for its first call", systemImage: "circle.dotted")
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        } else {
            Text("Not connected")
        }
    }

    /// Commands point at this copy of the app; a copy run from Downloads or a disk image moves.
    static var locationWarning: String? {
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") || path.contains("/Downloads/") {
            return "Move Freewrite to your Applications folder first: agents run it from where it is now."
        }
        return nil
    }
}

// MARK: - Connect sheet

private struct ConnectSheet: View {
    let client: AgentClient
    let onDone: () -> Void
    private let server = AgentServer.shared
    @State private var copied = false

    private var token: String { server.records[client]?.token ?? "" }
    private var executable: String { Bundle.main.executablePath ?? "/Applications/Freewrite.app/Contents/MacOS/freewrite" }
    private var arguments: [String] { ["mcp", "--client", client.rawValue, "--token", token] }

    private var instructions: (String, String) {
        let shellCommand = ([executable] + arguments).map(Self.shellQuoted).joined(separator: " ")
        switch client {
        case .claudeCode:
            return ("Run this in Terminal:", "claude mcp add freewrite -s user -- \(shellCommand)")
        case .codex:
            return ("Run this in Terminal:", "codex mcp add freewrite -- \(shellCommand)")
        case .openCode:
            return ("Add this to opencode.json (\"mcp\" section):", Self.json([
                "freewrite": ["type": "local", "command": [executable] + arguments, "enabled": true],
            ]))
        case .claudeDesktop:
            return ("Add this to claude_desktop_config.json (\"mcpServers\"), then restart Claude:", Self.json([
                "freewrite": ["command": executable, "args": arguments],
            ]))
        case .cursor:
            return ("Add this to ~/.cursor/mcp.json (\"mcpServers\"):", Self.json([
                "freewrite": ["command": executable, "args": arguments],
            ]))
        case .other:
            return ("A stdio MCP server. Command and arguments:", Self.json([
                "freewrite": ["command": executable, "args": arguments],
            ]))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AgentClientLogo(client: client, size: 22)
                Text("Connect \(client.title)")
                    .font(.title3.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("1. " + instructions.0)
                Text(instructions.1)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsCardBackground()
                HStack {
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(instructions.1, forType: .string)
                        copied = true
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    Text("It includes a token only for \(client.title). Keep it to yourself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("2. Ask \(client.title) something about your writing:")
                Text("“What's the entry open in Freewrite about? Link me to the strongest sentence.”")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                if let seen = server.records[client]?.lastSeen {
                    Label("Connected · last call \(seen.formatted(.relative(presentation: .named)))", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Waiting for \(client.title)…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private static func shellQuoted(_ value: String) -> String {
        guard value.contains(where: { " '\"$`\\!*?&;()<>|".contains($0) }) else { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
