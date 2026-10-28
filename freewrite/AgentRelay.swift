//
//  AgentRelay.swift
//  freewrite
//
//  `Freewrite.app/Contents/MacOS/freewrite mcp --client <id> --token <token>`: the MCP stdio
//  relay agents spawn (Paper's `paper mcp` shape). It never touches the entries folder: it opens
//  Freewrite in the background if needed, connects to the agent server on 127.0.0.1, sends a hello
//  line with the token, then copies stdin → server and server → stdout until either side closes.
//

import AppKit
import Darwin
import Foundation

enum AgentRelay {
    /// True when the process was started as the relay rather than the app.
    static var isRequested: Bool {
        CommandLine.arguments.dropFirst().first == "mcp"
    }

    static func run() -> Never {
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let token = value("--token") ?? ProcessInfo.processInfo.environment["FREEWRITE_TOKEN"] ?? ""
        let client = value("--client") ?? "other"

        guard let socket = connectToApp() else {
            fail("Freewrite isn't running and couldn't be opened. Open Freewrite and try again.")
        }
        let hello = try? JSONEncoder().encode(["freewrite": "hello", "client": client, "token": token])
        guard let hello, write(socket, hello + Data("\n".utf8)) else { fail("Couldn't reach Freewrite.") }

        // stdin → app on its own thread; app → stdout here.
        let input = Thread {
            let stdin = FileHandle.standardInput
            while true {
                let data = stdin.availableData
                if data.isEmpty || !write(socket, data) { break }
            }
            // The agent closed its side: we're done.
            Darwin.shutdown(socket, SHUT_WR)
            exit(0)
        }
        input.start()

        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = Darwin.read(socket, &buffer, buffer.count)
            if count <= 0 { break }
            FileHandle.standardOutput.write(Data(buffer[0..<count]))
        }
        // Freewrite quit or closed the connection.
        exit(0)
    }

    /// A connected socket to the agent server, opening Freewrite (in the background) when it
    /// isn't listening yet.
    private static func connectToApp() -> Int32? {
        if let socket = connect() { return socket }
        launchApp()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            if let socket = connect() { return socket }
        }
        return nil
    }

    private static func connect() -> Int32? {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = AgentServer.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    /// Opens this copy of Freewrite without bringing it forward.
    private static func launchApp() {
        // Contents/MacOS/freewrite → the .app bundle.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, _ in }
    }

    private static func write(_ socket: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(socket, pointer, remaining)
                if written <= 0 { return false }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
            return true
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("freewrite: " + message + "\n").utf8))
        exit(1)
    }
}
