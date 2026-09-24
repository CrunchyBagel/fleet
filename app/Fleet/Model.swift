import Foundation
import SwiftUI
import UserNotifications

/// What the sidebar is made of: a machine, or one of its active sessions.
/// Keyed by stable ids only: a session's record changes on every hook event,
/// and a selection that embedded the record would silently drop each time.
enum Item: Hashable, Identifiable {
    case overview
    case claudeSetup
    case host(String)
    case session(String)          // Session.id = "host/session"
    var id: String {
        switch self {
        case .overview: return "overview"
        case .claudeSetup: return "claude-setup"
        case .host(let h): return "host/\(h)"
        case .session(let s): return "session/\(s)"
        }
    }
}

/// One row of the machines table: answering hosts and the ones that are not, together.
struct MachineRow: Identifiable {
    let host: String
    let info: HostInfo?      // nil when not answering
    let down: String?        // the reason, when not answering
    let sessions: Int
    var id: String { host }
}

/// A move the owner picked from a Move menu, waiting on the confirmation.
struct PendingMove: Identifiable {
    let session: Session
    let target: String
    var id: String { session.id + "→" + target }
}

struct SidebarNode: Identifiable {
    let item: Item
    let children: [SidebarNode]?
    var id: Item { item }
}


/// The host a New-session sheet is for (sheet(item:) needs Identifiable).
struct NewSessionTarget: Identifiable { let host: String; var id: String { host } }

/// Everything the window shows, refreshed by polling the CLI. Polling is the
/// accepted design (CLAUDE.md decision 4); there is no daemon to push to us.
/// One instance for the window, the menu bar item and notification clicks.
@MainActor
final class FleetModel: ObservableObject {
    static let shared = FleetModel()

    @Published var sessions: [Session] = []          // `fleet ls --json`: sessions fleet started, every host
    @Published var hosts: HostsInfo = .init(hosts: [], down: [])
    @Published var projects: [String: [ProjectEntry]] = [:]   // per host, fetched when a New-session sheet opens
    @Published var models: [String: ModelsList] = [:]         // per host, same trigger; missing = still asking
    @Published var lastError: String?               // from polling; clears itself on the next good refresh
    @Published var actionError: String?             // from a button; stays until dismissed or the next action
    @Published var busy: [String: String] = [:]      // session id -> what fleet is doing for it right now
    @Published var hostBusy: [String: String] = [:]  // host -> what fleet is doing there (install)
    @Published var doctor: [String: [DoctorLine]] = [:]   // host -> last doctor report
    @Published var doctorText: [String: String] = [:]     // the same, as fleet printed it (Copy)
    @Published var doctorRunning: Set<String> = []
    @Published var refreshing = false
    @Published var lastRefresh: Date?
    @Published var loading: Set<String> = []          // hosts asked on the first load that have not answered yet
    // The Claude Setup screen: `fleet claude --json`, loaded on demand (it asks every Mac).
    @Published var claudeSetup: ClaudeSetup?
    @Published var claudeSetupAt: Date?
    @Published var claudeSetupError: String?           // the last load failed; the last good matrix stays
    @Published var claudeSetupLoading = false
    var claudeReloadPending = false                    // asked for while a load ran: load once more after it
    @Published var claudeShowRules = false             // permission rules expanded, kept while the app runs
    @Published var claudeConfirmRemove: ClaudeRemoval?  // the Remove… dialog is up for this
    @Published var claudeSelected: String?             // the row the inspector shows (ClaudeItem.id), kept across reloads
    @Published var claudeAction: String?               // what the last copy/remove printed
    @Published var claudeActionItem: String?           // the ClaudeItem.id that output belongs to
    @Published var claudeActionRunning = false

    // Window state that menus, the menu bar item and notifications also drive.
    /// $FLEET_SELECT ("host/session", a host, or "claude-setup") picks what a launch shows, for screenshots (docs/demo-fleet).
    @Published var selected: Item? = {
        guard let v = ProcessInfo.processInfo.environment["FLEET_SELECT"], !v.isEmpty else { return .overview }
        if v == "claude-setup" { return .claudeSetup }
        return v.contains("/") ? .session(v) : .host(v)
    }()
    @Published var newSessionOn: NewSessionTarget?
    @Published var confirmEnd: Session?             // the End-session dialog is up for this one
    @Published var moveTargets: [String: MoveTargets] = [:]   // session id -> fleet move --targets
    @Published var confirmMove: PendingMove?                 // the Move dialog is up for this
    var openMain: (() -> Void)?                     // set by the window; reopens it when closed

    // Hosts tab of Settings.
    @Published var hostList: [String] = []
    @Published var hostsOutput = ""

    private var timer: Timer?
    private var started = false                     // start() runs once; the window's onAppear fires on every reopen
    private var applied = (refresh: Prefs.refresh, all: Prefs.showAllSessions)   // what the timer and last fetch used
    private var lastStates: [String: String]?       // session id -> state at the previous refresh; nil before the first

    /// Sidebar tree: machines (answering ones first, in `fleet hosts info`
    /// order, then the ones not answering), each with its active sessions in
    /// a fixed project order. Not "needs you first": rows that jump about as
    /// states change are hard to follow; the dot, the badge and the waiting
    /// time already say what needs you. (ContentView flattens this into rows.)
    var tree: [SidebarNode] {
        var nodes: [SidebarNode] = []
        for h in hosts.hosts {
            let kids = sessions.filter { $0.host == h.host }
                .sorted { ($0.project, $0.name) < ($1.project, $1.name) }
                .map { SidebarNode(item: .session($0.id), children: nil) }
            nodes.append(SidebarNode(item: .host(h.host), children: kids))
        }
        for d in hosts.down { nodes.append(SidebarNode(item: .host(d.host), children: nil)) }
        // First load: every host from the list is there at once, in list
        // order, with a spinner until its answer arrives and fills the row in.
        let known = Set(hosts.hosts.map(\.host) + hosts.down.map(\.host))
        for h in hostList where loading.contains(h) && !known.contains(h) { nodes.append(SidebarNode(item: .host(h), children: nil)) }
        return nodes
    }
    /// The tree narrowed to a search: sessions whose project, name, branch or
    /// tmux session mention it, under their machine; a machine whose own
    /// name matches keeps every session.
    func tree(matching query: String) -> [SidebarNode] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return tree }
        return tree.compactMap { node in
            guard case .host(let h) = node.item else { return nil }
            if h.localizedCaseInsensitiveContains(q) { return node }
            let kids = (node.children ?? []).filter { k in
                guard case .session(let id) = k.item, let s = session(id: id) else { return false }
                return [s.project, s.name, s.branch, s.session].contains { $0.localizedCaseInsensitiveContains(q) }
            }
            return kids.isEmpty ? nil : SidebarNode(item: node.item, children: kids)
        }
    }
    var machines: [MachineRow] {
        hosts.hosts.map { MachineRow(host: $0.host, info: $0, down: nil, sessions: sessions(on: $0.host).count) }
        + hosts.down.map { MachineRow(host: $0.host, info: nil, down: $0.reason, sessions: 0) }
    }
    func session(id: String) -> Session? { sessions.first { $0.id == id } }
    func info(for host: String) -> HostInfo? { hosts.hosts.first { $0.host == host } }
    func isSelf(_ host: String) -> Bool { info(for: host)?.isSelf == true }
    var selfHost: String? { hosts.hosts.first { $0.isSelf == true }?.host }
    func downReason(for host: String) -> String? { hosts.down.first { $0.host == host }?.reason }
    func sessions(on host: String) -> [Session] { sessions.filter { $0.host == host } }
    var needsYou: Int { blocked.count }
    var usage: UsageLimits? {
        guard let s = sessions.filter({ $0.hasStats && (($0.limit5h ?? -1) >= 0 || ($0.limit7d ?? -1) >= 0) })
                .max(by: { ($0.statsTs ?? 0) < ($1.statsTs ?? 0) }) else { return nil }
        func date(_ t: Int?) -> Date? { (t ?? 0) > 0 ? Date(timeIntervalSince1970: TimeInterval(t!)) : nil }
        return UsageLimits(fiveHour: (s.limit5h ?? -1) >= 0 ? s.limit5h : nil, fiveHourResets: date(s.limit5hReset),
                           sevenDay: (s.limit7d ?? -1) >= 0 ? s.limit7d : nil, sevenDayResets: date(s.limit7dReset),
                           at: Date(timeIntervalSince1970: TimeInterval(s.statsTs ?? 0)))
    }
    var blocked: [Session] { sessions.filter { $0.state == "blocked" }.sorted { ($0.shownTime ?? .distantPast) < ($1.shownTime ?? .distantPast) } }

    /// The session the selection points at, and the machine it (or the
    /// selection) is on: what ⌘↩ and ⌘N act on.
    var selectedSession: Session? {
        if case .session(let id) = selected { return session(id: id) }
        return nil
    }
    var selectedHost: String? {
        switch selected {
        case .host(let h): return h
        case .session: return selectedSession?.host
        default: return selfHost
        }
    }

    /// Show an item: select it, bring the window (back) up.
    func reveal(_ item: Item) {
        selected = item
        openMain?()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// ⌘R and the toolbar button: poll now, and ask for the Claude setups
    /// again when that screen is up (it is not on the poll).
    func refreshNow() {
        refresh()
        if selected == .claudeSetup { loadClaudeSetup() }
    }

    /// Poll at the Settings interval (decision 4: polling, no daemon), and
    /// follow Settings changes: a new interval re-arms the timer, a change to
    /// which sessions are listed refetches at once.
    func start() {
        guard !started else { refresh(); return }
        started = true
        refresh()
        arm()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if Prefs.refresh != self.applied.refresh { self.arm() }
                if Prefs.showAllSessions != self.applied.all { self.refresh() }
            }
        }
    }

    private func arm() {
        applied.refresh = Prefs.refresh
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: applied.refresh, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            do {
                let all = Prefs.showAllSessions
                if lastRefresh == nil {
                    try await firstLoad(all: all)
                    loadClaudeSetup()
                } else {
                    async let s = FleetCLI.sessions(all: all)
                    async let h = FleetCLI.hosts()
                    let (ss, hh) = try await (s, h)
                    sessions = ss; hosts = hh
                }
                lastError = nil; lastRefresh = Date()
                applied.all = all
                noteNewlyBlocked()
                NSApp.dockTile.badgeLabel = needsYou > 0 ? "\(needsYou)" : nil
            } catch {
                lastError = error.localizedDescription
            }
            refreshing = false
        }
    }

    /// The first load asks each host on its own (`ls --json <host>` and
    /// `hosts info <host> --json`) and merges every answer as it lands, so the
    /// sidebar shows all the machines at once and fills them in one by one
    /// instead of staying blank until the slowest has answered. Later polls
    /// are the two fan-out calls. The host list comes first: it is local and
    /// instant, and it is what the placeholders are made from.
    private func firstLoad(all: Bool) async throws {
        hostList = try await FleetCLI.hostList()
        loading = Set(hostList)
        defer { loading = [] }
        guard !hostList.isEmpty else { hosts = .init(hosts: [], down: []); return }
        var firstError: Error?
        await withTaskGroup(of: (String, Result<([Session], HostsInfo), Error>).self) { group in
            for h in hostList {
                group.addTask {
                    do {
                        async let s = FleetCLI.sessions(all: all, host: h)
                        async let i = FleetCLI.hosts(host: h)
                        return (h, .success(try await (s, i)))
                    } catch { return (h, .failure(error)) }
                }
            }
            for await (h, result) in group {
                switch result {
                case .success(let (ss, hi)):
                    sessions = sessions.filter { $0.host != h } + ss
                    hosts = HostsInfo(hosts: hosts.hosts.filter { $0.host != h } + hi.hosts,
                                      down: hosts.down.filter { $0.host != h } + hi.down)
                case .failure(let e):
                    if firstError == nil { firstError = e }
                }
                loading.remove(h)
            }
        }
        // Into the order `hosts info` would give: desktops before laptops,
        // then by chip, then by load. One move now rather than on the next poll.
        hosts = HostsInfo(hosts: hosts.hosts.sorted { a, b in
            (a.laptop ? 1 : 0, -(a.score ?? 0), a.sessions) < (b.laptop ? 1 : 0, -(b.score ?? 0), b.sessions)
        }, down: hosts.down)
        if let firstError { throw firstError }
    }

    /// A session that has just gone from anything else to "needs you" gets a
    /// notification (clicking it selects the session). Nothing on the first
    /// refresh: there is no "before" to compare with, and a launch would
    /// otherwise announce every session already waiting.
    private func noteNewlyBlocked() {
        let now = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.state) })
        defer { lastStates = now }
        guard let before = lastStates, Prefs.on(Prefs.notify), Bundle.main.bundleIdentifier != nil else { return }
        for s in sessions where s.state == "blocked" && before[s.id] != nil && before[s.id] != "blocked" {
            let c = UNMutableNotificationContent()
            c.title = "\(s.title) needs you"
            c.body = (s.note?.isEmpty == false ? s.note! + " · " : "") + "on \(s.host) · \(s.branch)"
            if Prefs.on(Prefs.notifySound) { c.sound = .default }
            c.userInfo = ["session": s.id]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: s.id, content: c, trigger: nil))
        }
    }
}
