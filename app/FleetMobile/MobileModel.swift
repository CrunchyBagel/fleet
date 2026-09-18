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
    @Published var refreshing = false
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

    /// Ask every host at once; a host that fails contributes its reason.
    func refresh() async {
        guard !refreshing, setupComplete else { return }
        refreshing = true; defer { refreshing = false }
        let r = ssh()
        let list = hosts
        var newSessions: [Session] = [], newInfos: [String: HostInfo] = [:], newDown: [String: String] = [:]
        await withTaskGroup(of: (String, Result<(HostInfo, [Session]), Error>).self) { g in
            for h in list {
                g.addTask {
                    do {
                        async let info = r.fleet(on: h, ["hosts", "--info-local"], timeout: .seconds(12))
                        async let status = r.fleet(on: h, ["status", "--json"], timeout: .seconds(15))
                        let i = try JSONDecoder().decode(HostInfo.self, from: Data(try await info.utf8))
                        let s = try JSONDecoder().decode([Session].self, from: Data(try await status.utf8)).filter(\.managed)
                        return (h, .success((i, s)))
                    } catch { return (h, .failure(error)) }
                }
            }
            for await (h, result) in g {
                switch result {
                case .success(let (i, s)): newInfos[h] = i; newSessions += s
                case .failure(let e): newDown[h] = (e as? LocalizedError)?.errorDescription ?? "\(e)"
                }
            }
        }
        sessions = newSessions; infos = newInfos; down = newDown; lastRefresh = Date()
        error = nil
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
            await refresh()
            return Session.sessionName(project: project, task: name?.isEmpty == false ? name! : "main")
        } catch { self.error = "new: \(error.localizedDescription)"; return nil }
    }

    func endSession(_ s: Session) async {
        busy = "Ending \(s.title): asking the agent to exit…"; defer { busy = nil }
        do { _ = try await ssh().fleet(on: s.host, ["kill", "--local", s.session], timeout: .seconds(30)); await refresh() }
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
