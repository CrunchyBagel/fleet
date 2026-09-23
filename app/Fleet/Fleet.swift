import AppKit
import Foundation

enum Prefs {
    static let terminal = "terminal"                 // Terminal.rawValue
    static let refreshInterval = "refreshInterval"   // seconds
    static let showAll = "showAllSessions"           // fleet ls --all
    static let fleetBinary = "fleetBinary"           // path; "" = default
    static let showXcode = "showXcode", showClaude = "showClaude", showGitHub = "showGitHub"
    static let showScreenSharing = "showScreenSharing", showFinder = "showFinder"
    static let notify = "notifyBlocked", notifySound = "notifySound", menuBar = "menuBar"
    static let defaultRefresh = 8
    /// Bool keys whose default is true: absent means on.
    static func on(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key) }
    static var refresh: TimeInterval { let n = UserDefaults.standard.integer(forKey: refreshInterval); return TimeInterval(n > 0 ? n : defaultRefresh) }
    static var showAllSessions: Bool { UserDefaults.standard.bool(forKey: showAll) }
}


/// The terminals fleet knows how to drive (FLEET_TERM values). The app offers
/// the ones installed on this Mac.
enum Terminal: String, CaseIterable, Identifiable {
    case ghostty, terminal, iterm
    var id: String { rawValue }
    var title: String {
        switch self { case .ghostty: return "Ghostty"; case .terminal: return "Terminal"; case .iterm: return "iTerm2" }
    }
    var bundleID: String {
        switch self {
        case .ghostty: return "com.mitchellh.ghostty"
        case .terminal: return "com.apple.Terminal"
        case .iterm: return "com.googlecode.iterm2"
        }
    }
    var installed: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
    static var available: [Terminal] { allCases.filter(\.installed) }
    /// The saved choice, or the first installed terminal (Ghostty first).
    static var preferred: Terminal {
        if let raw = UserDefaults.standard.string(forKey: Prefs.terminal), let t = Terminal(rawValue: raw), t.installed { return t }
        return available.first ?? .terminal
    }
}

// MARK: - Running the CLI

enum FleetError: LocalizedError {
    case failed(command: String, status: Int32, stderr: String)
    case timedOut(command: String, seconds: Int)
    var errorDescription: String? {
        switch self {
        case let .failed(command, status, stderr):
            return "\(command) exited \(status)\n\(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case let .timedOut(command, seconds):
            return "\(command) gave no answer in \(seconds)s and was stopped"
        }
    }
}

/// The one place the app talks to fleet. `fleet` is found at ~/bin/fleet
/// (what `fleet install` links) unless FLEET_BIN says otherwise.
struct FleetCLI {
    static let defaultBinary = NSHomeDirectory() + "/bin/fleet"
    /// $FLEET_BIN wins (a per-launch override, as the tests use), then the
    /// Settings field, then what `fleet install` links. Read once.
    static let binary: String = {
        if let env = ProcessInfo.processInfo.environment["FLEET_BIN"], !env.isEmpty { return env }
        if let set = UserDefaults.standard.string(forKey: Prefs.fleetBinary), !set.isEmpty { return (set as NSString).expandingTildeInPath }
        return defaultBinary
    }()

    /// Run `fleet <args>` and return stdout. Throws with stderr on failure,
    /// unless `tolerate`: then a non-zero exit still returns stdout + stderr
    /// (doctor and hosts push exit 1 to mean "something to fix", not "broke").
    @discardableResult
    static func run(_ args: [String], env: [String: String] = [:], tolerate: Bool = false, timeout: Int? = nil) async throws -> String {
        try await runStreaming(args, env: env, tolerate: tolerate, timeout: timeout, onLine: nil)
    }

    /// Run `fleet <args>`, draining stdout and stderr as they arrive (a pipe
    /// left unread fills at 64KB and the child blocks forever), and hand each
    /// complete stdout line to `onLine` when given (fleet prints its steps:
    /// fetching, switching, opening...). Returns the whole output. With a
    /// `timeout` (seconds) the process is killed and the call throws once it
    /// passes: a poll that never returns must not stop every later poll.
    @discardableResult
    static func runStreaming(_ args: [String], env: [String: String] = [:], tolerate: Bool = false, timeout: Int? = nil,
                             onLine: (@Sendable (String) -> Void)?) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: binary)
            p.arguments = args
            var e = ProcessInfo.processInfo.environment
            e["FLEET_NO_SPINNER"] = "1"
            for (k, v) in env { e[k] = v }
            p.environment = e
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            let lock = NSLock()
            var outText = "", errText = "", pending = ""      // pending: a partial last line, kept for the next chunk
            var finished = false                               // the continuation is resumed exactly once: by exit or by the deadline
            func finish(_ result: Result<String, Error>) {
                lock.lock(); let first = !finished; finished = true; lock.unlock()
                guard first else { return }
                cont.resume(with: result)
            }
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) {
                    lock.lock(); let live = !finished; lock.unlock()
                    guard live, p.isRunning else { return }
                    // Resume first, then kill: a grandchild (ssh, tailscale) may hold the pipes
                    // open after fleet dies, and the termination handler's read-to-end would wait for it.
                    finish(.failure(FleetError.timedOut(command: "fleet " + args.joined(separator: " "), seconds: timeout)))
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    p.terminate()
                }
            }
            func take(_ text: String) {
                lock.lock(); outText += text; pending += text
                var lines: [String] = []
                while let nl = pending.firstIndex(of: "\n") {
                    let line = pending[..<nl].trimmingCharacters(in: .whitespaces)
                    pending = String(pending[pending.index(after: nl)...])
                    if !line.isEmpty { lines.append(line) }
                }
                lock.unlock()
                if let onLine { lines.forEach(onLine) }
            }
            out.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { take(String(decoding: d, as: UTF8.self)) }
            }
            err.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { lock.lock(); errText += String(decoding: d, as: UTF8.self); lock.unlock() }
            }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                lock.lock(); let late = finished; lock.unlock()
                if late { return }                             // the deadline already answered
                take(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
                lock.lock()
                errText += String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let rest = pending.trimmingCharacters(in: .whitespaces)
                let o = outText, s = errText
                lock.unlock()
                if !rest.isEmpty, let onLine { onLine(rest) }
                if proc.terminationStatus == 0 { finish(.success(o)) }
                else if tolerate { finish(.success(o + s)) }
                else { finish(.failure(FleetError.failed(command: "fleet " + args.joined(separator: " "), status: proc.terminationStatus, stderr: s))) }
            }
            do { try p.run() } catch {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                finish(.failure(error))
            }
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    // The queries the app needs. The polls carry a deadline well past fleet's
    // own (FLEET_CMD_TIMEOUT per host, 10s by default), for the day fleet
    // itself hangs on something it did not bound.
    static let pollTimeout = 60
    /// `fleet ls --json [--all] [host]`: every host, or one (the first load
    /// asks per host so the sidebar fills in as each answers).
    static func sessions(all: Bool, host: String? = nil) async throws -> [Session] {
        var args = ["ls", "--json"]; if all { args.append("--all") }; if let host { args.append(host) }
        return try await decode([Session].self, from: run(args, timeout: pollTimeout))
    }
    static func hosts(host: String? = nil) async throws -> HostsInfo {
        try await decode(HostsInfo.self, from: run(["hosts", "info"] + (host.map { [$0] } ?? []) + ["--json"], timeout: pollTimeout))
    }
    static func projects(on host: String) async throws -> ProjectsList {
        try await decode(ProjectsList.self, from: run(["projects", host, "--json"]))
    }
    /// `fleet models <host> --json`; a host running an older fleet has no
    /// such command, which counts as "unknown" (Automatic only), not an error.
    static func models(on host: String) async -> ModelsList {
        (try? await decode(ModelsList.self, from: run(["models", host, "--json"]))) ?? .unknown
    }

    // The actions. Attach goes through FLEET_TERM: fleet raises that terminal's
    // window for the session if one is open, else opens a new one.
    /// `fleet claude --json`: every Mac's Claude Code setup, merged. It asks
    /// every Mac, so it is loaded on demand, never on the poll.
    static func claudeSetup() async throws -> ClaudeSetup {
        try await decode(ClaudeSetup.self, from: run(["claude", "--json"], timeout: pollTimeout))
    }
    /// `fleet claude copy <kind> <name> --from <from> --to <to...>`, its
    /// `ok`/`FAIL` lines streamed. Arguments go as argv, so a permission
    /// rule's quotes and parentheses need no quoting.
    static func claudeCopy(kind: String, name: String, from: String, to: [String],
                           progress: @escaping @Sendable (String) -> Void) async throws {
        try await runStreaming(["claude", "copy", kind, name, "--from", from, "--to"] + to, onLine: progress)
    }
    /// `fleet claude rm -y <kind> <name> <host>` (the app has asked already).
    static func claudeRemove(kind: String, name: String, host: String,
                             progress: @escaping @Sendable (String) -> Void) async throws {
        try await runStreaming(["claude", "rm", "-y", kind, name, host], onLine: progress)
    }
    static func attach(host: String, session: String, terminal: Terminal) async throws {
        try await run(["attach", host, session], env: ["FLEET_TERM": terminal.rawValue])
    }
    static func open(host: String, session: String, progress: @escaping @Sendable (String) -> Void) async throws {
        try await runStreaming(["open", host, session], onLine: progress)
    }
    /// A fresh login shell on the host, in `dir` when given, in the chosen terminal.
    static func shell(host: String, dir: String? = nil, terminal: Terminal) async throws {
        try await run(["shell", host] + (dir.map { [$0] } ?? []), env: ["FLEET_TERM": terminal.rawValue])
    }
    /// End a session: fleet asks first unless -y; the app has already asked.
    /// fleet prints its steps (asking claude to exit, exited, ended).
    static func kill(host: String, session: String, progress: @escaping @Sendable (String) -> Void) async throws {
        try await runStreaming(["kill", "-y", host, session], onLine: progress)
    }
    /// `fleet doctor <host>`: the text report, exit 1 meaning "has FAILs".
    static func doctor(host: String) async throws -> String {
        try await run(["doctor", host], tolerate: true)
    }
    static func install(host: String, progress: @escaping @Sendable (String) -> Void) async throws {
        try await runStreaming(["install", host], onLine: progress)
    }
    /// The host list as `fleet hosts` prints it (one per line; the trailing
    /// "(path)" line says where it lives).
    static func hostList() async throws -> [String] {
        try await run(["hosts"]).split(separator: "\n").map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("(") }
    }
    /// `fleet hosts add [name]` (no name: every Mac on the tailnet) and `rm`;
    /// both push the list to every host and exit 1 if a push failed, so the
    /// output is returned either way.
    static func hostsAdd(_ name: String?) async throws -> String {
        try await run(["hosts", "add"] + (name.map { [$0] } ?? []), tolerate: true)
    }
    static func hostsRemove(_ name: String) async throws -> String {
        try await run(["hosts", "rm", name], tolerate: true)
    }
    /// Create (or reuse) a session without attaching; returns (host, session, dir).
    static func newSession(host: String, project: String, name: String?, model: String? = nil) async throws -> (String, String, String) {
        var args = ["new", host, project]; if let n = name, !n.isEmpty { args.append(n) }; args.append("--no-attach")
        if let m = model, !m.isEmpty { args += ["--model", m] }
        let parts = try await run(args).trimmingCharacters(in: .newlines).split(separator: "\t").map(String.init)
        guard parts.count == 3 else { throw FleetError.failed(command: "fleet new", status: 1, stderr: "unexpected output") }
        return (parts[0], parts[1], parts[2])
    }
}
