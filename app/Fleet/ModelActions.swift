import AppKit
import Foundation

/// What the buttons, menus and Settings do. Every action is a fleet
/// command; errors surface in the window, never silently.
extension FleetModel {
    func loadProjects(on host: String) {
        Task {
            do { projects[host] = try await FleetCLI.projects(on: host).projects }
            catch { lastError = "projects on \(host): \(error.localizedDescription)" }
        }
    }
    /// The models the host's Claude Code offers and its default, for the
    /// New-session sheet's picker. Never an error: unknown means Automatic only.
    func loadModels(on host: String) {
        Task { models[host] = await FleetCLI.models(on: host) }
    }

    // Actions surface errors in the window rather than failing silently.
    func perform(_ what: String, _ op: @escaping () async throws -> Void) {
        actionError = nil
        Task {
            do { try await op(); refresh() }
            catch { actionError = "\(what): \(error.localizedDescription)" }
        }
    }
    /// Screen Sharing to a machine: over its LAN address when that answers,
    /// else the tailnet name, and High Performance only when both ends are
    /// wired (`ScreenSharing.plan`). The probe takes at most a moment.
    func screenShare(_ host: String) {
        let remote = info(for: host), me = selfHost.flatMap { info(for: $0) }
        Task {
            let target = await ScreenSharing.plan(host: host, remote: remote, me: me)
            if let u = ScreenSharing.url(target) { NSWorkspace.shared.open(u) }
        }
    }
    func attach(_ s: Session) {
        let t = Terminal.preferred
        perform("attach") { try await FleetCLI.attach(host: s.host, session: s.session, terminal: t) }
    }
    func open(_ s: Session) {
        let id = s.id
        actionError = nil
        busy[id] = "Pulling \(s.branch) from origin…"
        Task {
            do {
                try await FleetCLI.open(host: s.host, session: s.session) { line in
                    Task { @MainActor in self.busy[id] = line }
                }
            } catch { actionError = "open: \(error.localizedDescription)" }
            busy[id] = nil
            refresh()
        }
    }
    /// Start a session (`fleet new --no-attach`, then attach when asked),
    /// telling `status` what stage it is at; throws so the sheet can show why.
    func newSession(host: String, project: String, name: String?, model: String? = nil, thenAttach: Bool,
                    status: @escaping (String) -> Void) async throws {
        let t = Terminal.preferred
        status("Starting \(project) on \(host): creating the tmux session and launching Claude Code…")
        let (h, sess, _) = try await FleetCLI.newSession(host: host, project: project, name: name, model: model)
        if thenAttach {
            status("Opening \(sess) in \(t.title)…")
            try await FleetCLI.attach(host: h, session: sess, terminal: t)
        }
        refresh()
    }
    /// After the confirmation dialog: ask the agent to /exit, then close the
    /// tmux session. The steps show in the session's busy row until it is gone.
    func endSession(_ s: Session) {
        let id = s.id
        actionError = nil
        busy[id] = "Ending \(s.title): asking the agent to exit…"
        Task {
            do {
                try await FleetCLI.kill(host: s.host, session: s.session) { line in
                    Task { @MainActor in self.busy[id] = line }
                }
                if selected == .session(id) { selected = .host(s.host) }
            } catch { actionError = "end \(s.title): \(error.localizedDescription)" }
            busy[id] = nil
            refresh()
        }
    }
    /// Which Macs can take a session; the Move menus show the answer.
    func loadMoveTargets(_ s: Session) {
        let id = s.id
        Task {
            do { moveTargets[id] = try await FleetCLI.moveTargets(host: s.host, session: s.session) }
            catch { moveTargets[id] = nil; actionError = "move targets for \(s.title): \(Self.reason(error))" }
        }
    }
    /// After the confirmation: fleet asks the agent for its handoff note,
    /// starts the session on the target with it, then ends this one. The
    /// steps show in the busy row; the new session is selected and attached.
    func moveSession(_ s: Session, to target: String) {
        let id = s.id, t = Terminal.preferred
        actionError = nil
        busy[id] = "Asking the agent for a handoff note…"
        Task {
            do {
                let (h, sess, _) = try await FleetCLI.move(host: s.host, session: s.session, to: target) { line in
                    Task { @MainActor in self.busy[id] = line }
                }
                busy[id] = nil
                moveTargets[id] = nil
                selected = .session("\(h)/\(sess)")
                refresh()
                try await FleetCLI.attach(host: h, session: sess, terminal: t)
            } catch { actionError = "move \(s.title) to \(target): \(Self.reason(error))" }
            busy[id] = nil
            refresh()
        }
    }
    func shell(on host: String, dir: String? = nil) {
        let t = Terminal.preferred
        perform("shell on \(host)") { try await FleetCLI.shell(host: host, dir: dir, terminal: t) }
    }
    func runDoctor(on host: String) {
        guard !doctorRunning.contains(host) else { return }
        doctorRunning.insert(host)
        Task {
            do {
                let out = try await FleetCLI.doctor(host: host)
                doctorText[host] = out
                doctor[host] = DoctorLine.parse(out)
            }
            catch { actionError = "doctor \(host): \(error.localizedDescription)" }
            doctorRunning.remove(host)
        }
    }
    /// `fleet install <host>`: pull fleet there, push the host list, seed
    /// what is missing. Streams its lines; doctor runs again afterwards.
    func updateFleet(on host: String) {
        guard hostBusy[host] == nil else { return }
        actionError = nil
        hostBusy[host] = "Updating Fleet on \(host)…"
        Task {
            do {
                try await FleetCLI.install(host: host) { line in
                    Task { @MainActor in self.hostBusy[host] = line }
                }
            } catch { actionError = "update \(host): \(error.localizedDescription)" }
            hostBusy[host] = nil
            runDoctor(on: host)
            refresh()
        }
    }

    // Hosts tab: the list on this Mac, edits pushed to every host by the CLI.
    func loadHosts() {
        Task {
            do { hostList = try await FleetCLI.hostList() }
            catch { hostsOutput = error.localizedDescription }
        }
    }
    func addHost(_ name: String?) {
        Task {
            do { hostsOutput = try await FleetCLI.hostsAdd(name) } catch { hostsOutput = error.localizedDescription }
            loadHosts(); refresh()
        }
    }
    func removeHost(_ name: String) {
        Task {
            do { hostsOutput = try await FleetCLI.hostsRemove(name) } catch { hostsOutput = error.localizedDescription }
            loadHosts(); refresh()
        }
    }

    /// `fleet claude --json`. One load at a time, so an older answer never
    /// lands after a newer one; a load asked for meanwhile (after a copy, ⌘R)
    /// runs once the current one is done, so the screen never keeps showing
    /// what was there before an action.
    func loadClaudeSetup() {
        guard !claudeSetupLoading else { claudeReloadPending = true; return }
        claudeSetupLoading = true
        claudeReloadPending = false
        Task {
            do {
                claudeSetup = try await FleetCLI.claudeSetup()
                claudeSetupAt = Date(); claudeSetupError = nil
            } catch { claudeSetupError = Self.reason(error) }
            claudeSetupLoading = false
            if claudeReloadPending { loadClaudeSetup() }
        }
    }
    /// fleet's own last word on a failure (its last stderr line), else the error.
    static func reason(_ error: Error) -> String {
        if case let FleetError.failed(_, _, err) = error,
           let last = err.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { !$0.isEmpty }) {
            return last
        }
        return error.localizedDescription
    }

    func claudeCopy(_ item: ClaudeItem, from: String, to: [String]) {
        claudeRun("claude copy", item) { p in try await FleetCLI.claudeCopy(kind: item.kind, name: item.name, from: from, to: to, progress: p) }
    }
    /// Make an MCP server run the same way everywhere by the plugin that
    /// provides it: install the plugin on every Mac without it (from a Mac
    /// that has it), then remove the standalone entries, so no Mac runs two.
    func claudeUsePlugin(_ item: ClaudeItem, hosts: [String]) {
        guard let plugin = item.providingPlugin, let from = hosts.first(where: { item.cell($0)?.plugin != nil }) else { return }
        let lacking = hosts.filter { item.cell($0)?.plugin == nil }
        let standalone = hosts.filter { item.cell($0) != nil && item.cell($0)?.plugin == nil }
        claudeRun("claude copy", item) { p in
            if !lacking.isEmpty { try await FleetCLI.claudeCopy(kind: "plugin", name: plugin, from: from, to: lacking, progress: p) }
            for h in standalone { try await FleetCLI.claudeRemove(kind: "mcp", name: item.name, host: h, progress: p) }
        }
    }
    func claudeRemove(_ item: ClaudeItem, from host: String) {
        claudeRun("claude rm", item) { p in try await FleetCLI.claudeRemove(kind: item.kind, name: item.name, host: host, progress: p) }
    }
    /// One copy or remove at a time. Its lines stream into the status line;
    /// a failure also goes to the banner, as the FAIL line when there is one,
    /// else fleet's own message (stderr); the matrix reloads either way.
    private func claudeRun(_ what: String, _ item: ClaudeItem, _ op: @escaping (@escaping @Sendable (String) -> Void) async throws -> Void) {
        guard !claudeActionRunning else { return }
        actionError = nil
        claudeActionRunning = true
        claudeAction = ""
        claudeActionItem = item.id
        Task {
            do {
                try await op { line in
                    Task { @MainActor in
                        let soFar = self.claudeAction ?? ""
                        self.claudeAction = soFar.isEmpty ? line : soFar + "\n" + line
                    }
                }
            } catch {
                await Task.yield()                          // let the last streamed lines land first
                let lines = (claudeAction ?? "").split(separator: "\n").map(String.init)
                let why = lines.last { $0.hasPrefix("FAIL") } ?? Self.reason(error)
                actionError = "\(what): \(why)"
            }
            claudeActionRunning = false
            loadClaudeSetup()
        }
    }
}
