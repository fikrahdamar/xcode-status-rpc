//
//  DiscordIPC.swift
//  xcode-status-rpc
//

import Foundation

/// Minimal client for Discord's local IPC protocol (the same one the
/// official Rich Presence libraries use).
///
/// Transport: a Unix domain socket the Discord desktop client listens on,
/// named `discord-ipc-0` … `discord-ipc-9` inside the user's temp directory.
///
/// Wire format: every message is a frame of
///   [opcode: UInt32 little-endian][length: UInt32 little-endian][JSON payload]
///
/// Handshake: send opcode 0 with `{"v": 1, "client_id": "..."}`; Discord
/// replies with a DISPATCH frame (opcode 1) carrying a READY event on
/// success, or closes/answers with an error payload on failure.
final class DiscordIPC {

    /// Application ID from the Discord Developer Portal (General Information
    /// → Application ID). Identifies which Discord App this presence belongs
    /// to — its name is what shows up as "Playing …".
    static let clientID = "1523033186844672145"

    enum IPCError: Error, CustomStringConvertible {
        case discordNotRunning
        case connectionClosed
        case malformedFrame

        var description: String {
            switch self {
            case .discordNotRunning: "no Discord IPC socket found — is the Discord app running?"
            case .connectionClosed: "Discord closed the connection"
            case .malformedFrame: "received a frame that doesn't match the IPC wire format"
            }
        }
    }

    private enum Opcode: UInt32 {
        case handshake = 0
        case frame = 1
        case close = 2
        case ping = 3
        case pong = 4
    }

    private var socketFD: Int32 = -1

    var isConnected: Bool { socketFD >= 0 }

    // MARK: - Connect

    /// Tries every candidate socket path until one accepts the connection.
    func connect() throws {
        disconnect()

        for path in Self.candidateSocketPaths() {
            if let fd = Self.openUnixSocket(path: path) {
                socketFD = fd
                print("[DiscordIPC] connected to \(path)")
                return
            }
        }
        throw IPCError.discordNotRunning
    }

    func disconnect() {
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    deinit {
        disconnect()
    }

    /// Discord puts its socket in the user's temp dir on macOS. Index goes
    /// up when several clients run at once (Discord + Canary + PTB), so try
    /// 0 through 9 — never hardcode a single path.
    private static func candidateSocketPaths() -> [String] {
        var dirs: [String] = []
        if let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"] {
            dirs.append(tmpdir)
        }
        dirs.append("/tmp/")

        return dirs.flatMap { dir in
            (0...9).map { "\(dir)discord-ipc-\($0)" }
        }
    }

    private static func openUnixSocket(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // sun_path is a fixed-size C array (104 bytes on macOS); copy the
        // path bytes in, leaving room for the trailing NUL.
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < sunPathSize else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            dst.copyBytes(from: pathBytes)
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    // MARK: - Handshake

    /// Sends the opcode-0 handshake and returns Discord's reply payload
    /// (a READY event on success).
    @discardableResult
    func handshake() throws -> String {
        try sendFrame(opcode: .handshake, payload: ["v": 1, "client_id": Self.clientID])
        let (opcode, payload) = try readFrame()
        print("[DiscordIPC] handshake reply op=\(opcode) payload=\(payload)")
        return payload
    }

    // MARK: - Wire format

    private func sendFrame(opcode: Opcode, payload: [String: Any]) throws {
        let json = try JSONSerialization.data(withJSONObject: payload)

        var frame = Data()
        withUnsafeBytes(of: opcode.rawValue.littleEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(json)

        try frame.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var remaining = buffer.count
            var cursor = buffer.baseAddress!
            while remaining > 0 {
                let written = write(socketFD, cursor, remaining)
                guard written > 0 else { throw IPCError.connectionClosed }
                cursor += written
                remaining -= written
            }
        }
    }

    private func readFrame() throws -> (opcode: UInt32, payload: String) {
        let header = try readExactly(8)
        let opcode = header.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }.littleEndian
        let length = header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }.littleEndian

        // Presence payloads are small; anything huge means we lost framing.
        guard length < 1_000_000 else { throw IPCError.malformedFrame }

        let body = try readExactly(Int(length))
        guard let payload = String(data: body, encoding: .utf8) else {
            throw IPCError.malformedFrame
        }
        return (opcode, payload)
    }

    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(capacity: count)
        var buffer = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let n = read(socketFD, &buffer[received], count - received)
            guard n > 0 else { throw IPCError.connectionClosed }
            received += n
        }
        data.append(contentsOf: buffer)
        return data
    }
}
