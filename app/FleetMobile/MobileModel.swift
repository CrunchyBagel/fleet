import Foundation
import SwiftUI

/// Everything the phone shows. Polls every host itself (the phone is a
/// control machine: it holds a key every Mac accepts, and the Macs need no
/// keys to each other), so `status --json` and `hosts --info-local` run on
/// each host directly and the results are merged here.
@MainActor
final class MobileModel: ObservableObject {
    @AppStorage("username") var username = ""
    @AppStorage("hostsJSON") private var hostsJSON = "[]"
    @Published var sessions: [Session] = []
    @Published var infos: [String: HostInfo] = [:]
    @Published var down: [String: String] = [:]
    @Published var projects: [String: [ProjectEntry]] = [:]
    @Published var lastRefresh: Date?
    @Published var error: String?
    @Published var busy: String?

    private var runner: SSHRunner?
    private var runnerUser = ""

    var hosts: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(hostsJSON.utf8))) ?? [] }
        set { hostsJSON = String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8), as: UTF8.self); objectWillChange.send() }
    }
    var setupComplete: Bool { !username.isEmpty && !hosts.isEmpty && KeyStore.hasKey }

    func ssh() -> SSHRunner {
        if let r = runner, runnerUser == username { return r }
        let r = SSHRunner(username: username); runner = r; runnerUser = username
        return r
    }

    func sessions(on host: String) -> [Session] { sessions.filter { $0.host == host }.sorted { ($0.project, $0.name) < ($1.project, $1.name) } }
    func session(id: String) -> Session? { sessions.first { $0.id == id } }
    var usage: UsageLimits? { UsageLimits.freshest(in: sessions) }

    /// Hosts with a request in flight. Each host is asked on its own and its
    /// section updates as soon as it answers, so one slow or unreachable Mac
    /// never holds up the others.
    @Published private(set) var inFlight: Set<String> = []
    var refreshing: Bool { !inFlight.isEmpty }
    /// Asked but not answered yet (first load): the section shows a spinner.
    func loading(_ host: String) -> Bool { inFlight.contains(host) && infos[host] == nil && down[host] == nil }

    /// Ask every host at once; returns when all have answered. A host still
    /// busy from the last round is left to finish.
    func refresh() async {
        guard setupComplete else { return }
        let list = hosts
        sessions.removeAll { !list.contains($0.host) }
        await withTaskGroup(of: Void.self) { g in
            for h in list { g.addTask { await self.refresh(host: h) } }
        }
    }

    /// One host: `status --json` (and `hosts --info-local` until it has
    /// answered once, it only changes with the hardware), applied as it lands.
    func refresh(host h: String) async {
        guard setupComplete, !inFlight.contains(h) else { return }
        inFlight.insert(h); defer { inFlight.remove(h) }
        let r = ssh()
        do {
            async let status = r.fleet(on: h, ["status", "--json"], timeout: .seconds(15))
            if infos[h] == nil {
                let out = try await r.fleet(on: h, ["hosts", "--info-local"], timeout: .seconds(12))
                infos[h] = try JSONDecoder().decode(HostInfo.self, from: Data(out.utf8))
            }
            let s = try JSONDecoder().decode([Session].self, from: Data(try await status.utf8)).filter(\.managed)
            sessions = sessions.filter { $0.host != h } + s
            down[h] = nil
            lastRefresh = Date()
        } catch {
            sessions.removeAll { $0.host == h }
            down[h] = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func loadProjects(on host: String) async {
        do {
            let out = try await ssh().fleet(on: host, ["projects", "--json"])
            projects[host] = try JSONDecoder().decode(ProjectsList.self, from: Data(out.utf8)).projects
        } catch { self.error = "projects on \(host): \(error.localizedDescription)" }
    }

    /// `fleet new --local` there; the session name follows the CLI's rule.
    func newSession(on host: String, project: String, name: String?) async -> String? {
        busy = "Starting \(project) on \(host)…"; defer { busy = nil }
        do {
            var args = ["new", "--local", project]; if let n = name, !n.isEmpty { args.append(n) }
            _ = try await ssh().fleet(on: host, args, timeout: .seconds(40))
            await refresh(host: host)
            return Session.sessionName(project: project, task: name?.isEmpty == false ? name! : "main")
        } catch { self.error = "new: \(error.localizedDescription)"; return nil }
    }

    func endSession(_ s: Session) async {
        busy = "Ending \(s.title): asking the agent to exit…"; defer { busy = nil }
        do { _ = try await ssh().fleet(on: s.host, ["kill", "--local", s.session], timeout: .seconds(30)); await refresh(host: s.host) }
        catch { self.error = "end: \(error.localizedDescription)" }
    }

    /// Onboarding: learn the host list from one Mac (`fleet hosts`).
    func discoverHosts(from entry: String) async throws -> [String] {
        let out = try await ssh().fleet(on: entry, ["hosts"])
        let names = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("(") }
        return names.isEmpty ? [entry] : names
    }

    /// Settings: ask the Macs already known, answering ones first, for the
    /// current list; the first that answers wins. Returns it and who said so.
    func refreshHosts() async throws -> ([String], String) {
        let order = hosts.filter { down[$0] == nil } + hosts.filter { down[$0] != nil }
        var last: Error = SSHRunner.RemoteError(host: "hosts", message: "none to ask")
        for h in order {
            do { return (try await discoverHosts(from: h), h) } catch { last = error }
        }
        throw last
    }

    func resetConnections() { Task { await runner?.disconnectAll() } }
}

extension Session {
    /// `session_name` in the CLI: "<project>-<task>" with . and : as _.
    static func sessionName(project: String, task: String) -> String {
        (project + "-" + task).replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: ":", with: "_")
    }
}

extension UsageLimits {
    /// One account across the fleet: the freshest snapshot with limits wins.
    static func freshest(in sessions: [Session]) -> UsageLimits? {
        guard let s = sessions.filter({ $0.hasStats && (($0.limit5h ?? -1) >= 0 || ($0.limit7d ?? -1) >= 0) })
                .max(by: { ($0.statsTs ?? 0) < ($1.statsTs ?? 0) }) else { return nil }
        func date(_ t: Int?) -> Date? { (t ?? 0) > 0 ? Date(timeIntervalSince1970: TimeInterval(t!)) : nil }
        return UsageLimits(fiveHour: (s.limit5h ?? -1) >= 0 ? s.limit5h : nil, fiveHourResets: date(s.limit5hReset),
                           sevenDay: (s.limit7d ?? -1) >= 0 ? s.limit7d : nil, sevenDayResets: date(s.limit7dReset),
                           at: Date(timeIntervalSince1970: TimeInterval(s.statsTs ?? 0)))
    }
}
