import AppKit
import Combine
import Foundation
import SwiftUI

/// Long-running Python child process exposing the JSON-line RPC protocol from
/// `python_backend/server.py`. Maintains per-request handler closures so the
/// caller can stream progress/token events with strong typing.
@MainActor
final class PythonBridge: ObservableObject {
    static let shared = PythonBridge()

    enum Status: Equatable {
        case stopped
        case starting
        case ready
        case crashed(String)

        var label: String {
            switch self {
            case .stopped:        return "Python: stopped"
            case .starting:       return "Python: starting…"
            case .ready:          return "Python: ready"
            case .crashed(let m): return "Python: error — \(m)"
            }
        }

        var color: Color {
            switch self {
            case .stopped:  return .gray
            case .starting: return .yellow
            case .ready:    return .green
            case .crashed:  return .red
            }
        }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var lastError: String?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()
    private var handlers: [String: (BridgeEvent) -> Void] = [:]
    private let logHandle: FileHandle?

    @AppStorage("pythonPath") private var pythonPathOverride: String = ""

    private init() {
        self.logHandle = PythonBridge.openLog()
    }

    // MARK: Lifecycle

    func startIfNeeded() async {
        guard status == .stopped else { return }
        status = .starting
        do {
            try await ensureVenv()
            try spawnServer()
        } catch {
            status = .crashed("\(error)")
            lastError = "\(error)"
        }
    }

    func shutdown() {
        guard let process, process.isRunning else { return }
        _ = try? send(["op": "shutdown", "id": UUID().uuidString])
        process.waitUntilExit()
        cleanup()
    }

    // MARK: Public RPC entry points

    /// Generic streaming call. The handler is invoked with every event whose
    /// `id` matches the generated request id. The handler MUST be cleared by
    /// returning `true` from the `done`/`error` branch, or by calling
    /// `unregister` when cancelling.
    @discardableResult
    func call(op: String,
              payload: [String: Any] = [:],
              onEvent: @escaping (BridgeEvent) -> Void) throws -> String {
        let rid = UUID().uuidString
        handlers[rid] = onEvent
        var req = payload
        req["op"] = op
        req["id"] = rid
        try send(req)
        return rid
    }

    func unregister(_ id: String) { handlers.removeValue(forKey: id) }

    // MARK: Internal

    private func ensureVenv() async throws {
        let fm = FileManager.default
        let python = AppPaths.venvPython.path
        if fm.fileExists(atPath: python) { return }

        let basePython = pythonPathOverride.isEmpty
            ? PythonBridge.discoverHomebrewPython()
            : pythonPathOverride
        guard let basePython, fm.fileExists(atPath: basePython) else {
            throw BridgeError.pythonNotFound
        }

        let venv = AppPaths.venvDir
        try fm.createDirectory(at: venv.deletingLastPathComponent(), withIntermediateDirectories: true)

        try await runShell([basePython, "-m", "venv", venv.path])
        let pip = venv.appendingPathComponent("bin/pip").path
        try await runShell([pip, "install", "--upgrade", "pip"])
        let req = AppPaths.bundledBackendDir.appendingPathComponent("requirements.txt").path
        try await runShell([pip, "install", "-r", req])
    }

    private static func discoverHomebrewPython() -> String? {
        let candidates = [
            "/opt/homebrew/bin/python3.11",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3.11",
            "/usr/local/bin/python3",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func runShell(_ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: args[0])
            proc.arguments = Array(args.dropFirst())
            proc.terminationHandler = { p in
                if p.terminationStatus == 0 { cont.resume() }
                else { cont.resume(throwing: BridgeError.shellFailed(args.joined(separator: " "), p.terminationStatus)) }
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
        }
    }

    private func spawnServer() throws {
        let proc = Process()
        let backend = AppPaths.bundledBackendDir
        proc.executableURL = URL(fileURLWithPath: AppPaths.venvPython.path)
        proc.arguments = ["-u", backend.appendingPathComponent("server.py").path]
        proc.currentDirectoryURL = backend
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONPATH"] = backend.path
        proc.environment = env

        let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.ingest(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendLog("[py.stderr] \(s)") }
        }
        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                self?.appendLog("[bridge] python exited code=\(p.terminationStatus)")
                self?.status = .crashed("exit \(p.terminationStatus)")
                self?.cleanup()
            }
        }

        try proc.run()
        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.status = .ready
        appendLog("[bridge] python pid=\(proc.processIdentifier) started")
    }

    private func cleanup() {
        stdinPipe = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
        handlers.removeAll()
    }

    private func send(_ payload: [String: Any]) throws {
        guard let stdin = stdinPipe else { throw BridgeError.notRunning }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        try stdin.fileHandleForWriting.write(contentsOf: data)
        try stdin.fileHandleForWriting.write(contentsOf: Data([0x0A]))
    }

    private func ingest(_ chunk: Data) {
        stdoutBuffer.append(chunk)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[..<nl]
            stdoutBuffer.removeSubrange(...nl)
            guard !lineData.isEmpty else { continue }
            handle(line: lineData)
        }
    }

    private func handle(line: Data) {
        do {
            let event = try JSONDecoder().decode(BridgeEvent.self, from: line)
            if event.id == "_ready" { status = .ready; return }
            if let handler = handlers[event.id] {
                handler(event)
                if case .done = event.kind { handlers.removeValue(forKey: event.id) }
                if case .error = event.kind { handlers.removeValue(forKey: event.id) }
            } else {
                appendLog("[bridge] unrouted event id=\(event.id) kind=\(event.kind)")
            }
        } catch {
            appendLog("[bridge] decode failed: \(error) — \(String(data: line, encoding: .utf8) ?? "")")
        }
    }

    // MARK: Logging

    private static func openLog() -> FileHandle? {
        let url = AppPaths.bridgeLog
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
        return handle
    }

    private func appendLog(_ s: String) {
        let line = "[\(ISO8601DateFormatter().string(from: .now))] \(s)\n"
        if let data = line.data(using: .utf8) {
            try? logHandle?.write(contentsOf: data)
        }
    }
}

enum BridgeError: LocalizedError {
    case pythonNotFound
    case notRunning
    case shellFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            return "Could not find python3.11. Install via `brew install python@3.11` or set a path in Settings."
        case .notRunning:
            return "Python backend isn't running."
        case .shellFailed(let cmd, let code):
            return "Shell command failed (\(code)): \(cmd)"
        }
    }
}

// MARK: Decoded event

struct BridgeEvent: Decodable {
    let id: String
    let kind: Kind

    enum Kind: Decodable {
        case ready
        case progress(pct: Double, stage: String, message: String)
        case log(level: String, message: String)
        case token(text: String, tps: Double)
        case firstToken(ms: Double)
        case stats(payload: [String: AnyDecodable])
        case done(result: [String: AnyDecodable])
        case error(message: String, traceback: String?)
        case unknown(name: String)
    }

    private enum CodingKeys: String, CodingKey {
        case id, event, pct, stage, message, level, text, tps, ms, result, traceback
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        let name = try c.decode(String.self, forKey: .event)
        switch name {
        case "ready":
            self.kind = .ready
        case "progress":
            self.kind = .progress(
                pct: (try? c.decode(Double.self, forKey: .pct)) ?? 0,
                stage: (try? c.decode(String.self, forKey: .stage)) ?? "",
                message: (try? c.decode(String.self, forKey: .message)) ?? ""
            )
        case "log":
            self.kind = .log(
                level: (try? c.decode(String.self, forKey: .level)) ?? "info",
                message: (try? c.decode(String.self, forKey: .message)) ?? ""
            )
        case "token":
            self.kind = .token(
                text: (try? c.decode(String.self, forKey: .text)) ?? "",
                tps: (try? c.decode(Double.self, forKey: .tps)) ?? 0
            )
        case "first_token":
            self.kind = .firstToken(ms: (try? c.decode(Double.self, forKey: .ms)) ?? 0)
        case "done":
            let payload = (try? c.decode([String: AnyDecodable].self, forKey: .result)) ?? [:]
            self.kind = .done(result: payload)
        case "error":
            self.kind = .error(
                message: (try? c.decode(String.self, forKey: .message)) ?? "unknown",
                traceback: try? c.decode(String.self, forKey: .traceback)
            )
        default:
            self.kind = .unknown(name: name)
        }
    }
}

/// Type-erasing JSON wrapper, used for `result` payloads whose shape is op-specific.
struct AnyDecodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            value = NSNull()
        } else if let v = try? c.decode(Bool.self) {
            value = v
        } else if let v = try? c.decode(Int.self) {
            value = v
        } else if let v = try? c.decode(Double.self) {
            value = v
        } else if let v = try? c.decode(String.self) {
            value = v
        } else if let v = try? c.decode([AnyDecodable].self) {
            value = v.map(\.value)
        } else if let v = try? c.decode([String: AnyDecodable].self) {
            value = v.mapValues(\.value)
        } else {
            value = NSNull()
        }
    }
}

extension Dictionary where Key == String, Value == AnyDecodable {
    func string(_ key: String) -> String? { self[key]?.value as? String }
    func int(_ key: String) -> Int? {
        if let i = self[key]?.value as? Int { return i }
        if let d = self[key]?.value as? Double { return Int(d) }
        return nil
    }
    func double(_ key: String) -> Double? {
        if let d = self[key]?.value as? Double { return d }
        if let i = self[key]?.value as? Int { return Double(i) }
        return nil
    }
    func array(_ key: String) -> [Any]? { self[key]?.value as? [Any] }
    func dict(_ key: String) -> [String: Any]? { self[key]?.value as? [String: Any] }
}
