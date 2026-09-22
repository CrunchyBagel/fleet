import Foundation
import SwiftUI

// Records mirroring the CLI's JSON (see CLAUDE.md "Record schema"), shared by
// the Mac app (which runs the CLI locally) and the iOS app (which runs it over
// ssh). Nothing platform-specific belongs here.

struct Session: Codable, Identifiable, Hashable {
    let host: String
    let project: String
    let name: String
    let path: String
    let branch: String
    let upstream: String
    let state: String
    let subject: String
    let session: String
    let dirty: Bool
    let ts: Int
    let ahead: Int
    let behind: Int
    let managed: Bool
    let activity: Int
    let worktree: Bool
    let attachedFrom: [String]
    let remote: String?
    let claudeSession: String?
    // From the hook payloads (older remotes lack them): what the agent is
    // working on, asking for, and said when it finished.
    let prompt: String?
    let note: String?
    let said: String?
    // From the status line snapshot: model, context use, cost, account limits.
    let model: String?
    let contextPct: Int?        // -1 = unknown
    let costUsd: Double?
    let limit5h: Int?           // -1 = unknown
    let limit5hReset: Int?
    let limit7d: Int?
    let limit7dReset: Int?
    let statsTs: Int?           // 0 = no snapshot yet

    var id: String { "\(host)/\(session)" }

    enum CodingKeys: String, CodingKey {
        case host, project, name, path, branch, upstream, state, subject, session, dirty, ts, ahead, behind, managed, activity, worktree, remote
        case attachedFrom = "attached_from"
        case claudeSession = "claude_session"
        case prompt, note, said, model
        case contextPct = "context_pct"
        case costUsd = "cost_usd"
        case limit5h = "limit_5h"
        case limit5hReset = "limit_5h_reset"
        case limit7d = "limit_7d"
        case limit7dReset = "limit_7d_reset"
        case statsTs = "stats_ts"
    }

    /// One line on what the agent is up to: what it is asking for when it
    /// needs you, else what it was told to do.
    var doing: String? {
        if state == "blocked", let n = note, !n.isEmpty { return n }
        if let p = prompt, !p.isEmpty { return p }
        return nil
    }
    var hasStats: Bool { (statsTs ?? 0) > 0 }
    var contextPercent: Int? { hasStats && (contextPct ?? -1) >= 0 ? contextPct : nil }

    /// Deep link into the Claude desktop app for this session. The app's
    /// claude:// scheme mirrors claude.ai paths, so this is the web URL
    /// claude.ai/code/<remote control id> through the app instead of a browser.
    var claudeURL: URL? {
        // A Remote Control id (session_…) or a local UUID; nothing else belongs in a URL.
        guard let id = claudeSession, !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        return URL(string: "claude://claude.ai/code/\(id)")
    }

    /// https://github.com/Owner/Repo for a GitHub origin (ssh or https), else nil.
    var githubURL: URL? {
        guard var r = remote, !r.isEmpty else { return nil }
        if r.hasSuffix(".git") { r.removeLast(4) }
        if let range = r.range(of: "git@github.com:") { return URL(string: "https://github.com/" + r[range.upperBound...]) }
        if r.hasPrefix("https://github.com/") || r.hasPrefix("http://github.com/") { return URL(string: r) }
        if r.hasPrefix("ssh://git@github.com/") { return URL(string: "https://github.com/" + r.dropFirst("ssh://git@github.com/".count)) }
        return nil
    }

    /// What `fleet ls` shows in the time column: last activity if any, else last commit.
    var shownTime: Date? {
        let t = activity > 0 ? activity : ts
        return t > 0 ? Date(timeIntervalSince1970: TimeInterval(t)) : nil
    }
}

struct HostInfo: Codable, Identifiable, Hashable {
    let host: String
    let model: String            // identifier, e.g. Mac15,8
    let modelName: String?       // "MacBook Pro", "Mac mini"...; missing from older remotes
    let chip: String
    let cores: Int
    let pcores: Int?
    let ecores: Int?
    let memGB: Int
    let laptop: Bool
    let sessions: Int
    let score: Int?              // only the fan-out (hosts info) ranks; --info-local has none
    let isSelf: Bool?
    // How to reach it on its own network (missing from older remotes): the
    // Bonjour name, the IPv4 of its default-route interface, and whether that
    // interface is "ethernet" or "wifi" ("" when unknown or a VPN).
    let lanName: String?
    let lanIp: String?
    let lanLink: String?

    var id: String { host }
    /// The family name: what the host reports, else read off an older-style
    /// identifier (Macmini9,1, MacBookPro18,3); "" for Mac15,8-style ones.
    var family: String {
        if let n = modelName, !n.isEmpty { return n }
        for (prefix, name) in [("MacBookPro", "MacBook Pro"), ("MacBookAir", "MacBook Air"), ("MacBook", "MacBook"),
                               ("Macmini", "Mac mini"), ("MacPro", "Mac Pro"), ("iMac", "iMac")] where model.hasPrefix(prefix) {
            return name
        }
        return ""
    }
    /// What to call it: the family when known, else the identifier.
    var modelTitle: String { family.isEmpty ? model : family }
    /// The SF Symbol for this kind of Mac; laptop/desktop when the family is unknown.
    var symbol: String {
        switch family {
        case "Mac mini": return "macmini"
        case "Mac Studio": return "macstudio"
        case "Mac Pro": return "macpro.gen3"
        case "iMac": return "desktopcomputer"
        case let n where n.hasPrefix("MacBook"): return "macbook"
        default: return laptop ? "laptopcomputer" : "desktopcomputer"
        }
    }

    enum CodingKeys: String, CodingKey {
        case host, model, chip, cores, pcores, ecores, laptop, sessions, score
        case modelName = "model_name"
        case memGB = "mem_gb"
        case isSelf = "self"
        case lanName = "lan_name"
        case lanIp = "lan_ip"
        case lanLink = "lan_link"
    }
}

/// One line of `fleet doctor`: "  ok    …", "  FAIL  …" with an optional
/// "        fix: …" beneath, or a dim "  · …" note. Parsed from the text the
/// CLI prints (no colours off a tty); doctor_remote reads it the same way.
struct DoctorLine: Identifiable, Hashable {
    let id: Int
    let ok: Bool
    let text: String
    var fix: String?
    static func parse(_ out: String) -> [DoctorLine] {
        var lines: [DoctorLine] = []
        for raw in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("ok ") { lines.append(DoctorLine(id: lines.count, ok: true, text: t.dropFirst(3).trimmingCharacters(in: .whitespaces))) }
            else if t.hasPrefix("FAIL ") { lines.append(DoctorLine(id: lines.count, ok: false, text: t.dropFirst(5).trimmingCharacters(in: .whitespaces))) }
            else if t.hasPrefix("fix: "), !lines.isEmpty { lines[lines.count - 1].fix = String(t.dropFirst(5)) }
            else if t.hasPrefix("· ") { lines.append(DoctorLine(id: lines.count, ok: true, text: String(t.dropFirst(2)))) }
        }
        return lines
    }
}

/// UserDefaults keys behind the Settings window. Bool keys default to true
/// (`@AppStorage` declarations carry the defaults; the model reads them here).

struct HostDown: Codable, Hashable { let host: String; let reason: String }
struct HostsInfo: Codable { let hosts: [HostInfo]; let down: [HostDown] }

struct ProjectEntry: Codable, Hashable { let project: String; let layout: String; let claude: Bool; let path: String; let remote: String }
struct ProjectsList: Codable { let host: String; let projects: [ProjectEntry] }

/// `fleet models <host> --json`: what Claude Code there can start with.
/// `section` is "main" (its picker) or "overflow" (older versions);
/// `defaultModel` is the id or alias its settings name, "" when Claude Code
/// decides on its own.
struct ModelEntry: Codable, Hashable {
    let id: String, name: String, shortName: String, section: String
    enum CodingKeys: String, CodingKey { case id, name, section; case shortName = "short_name" }
}
struct ModelsList: Codable {
    let host: String, defaultModel: String, models: [ModelEntry]
    enum CodingKeys: String, CodingKey { case host, models; case defaultModel = "default" }
    static let unknown = ModelsList(host: "", defaultModel: "", models: [])
    /// The catalog entry the default names: by id, or by alias ("opus" ->
    /// the first claude-opus-* in the main section, which is the latest).
    var resolvedDefault: ModelEntry? {
        let d = defaultModel.lowercased()
        guard !d.isEmpty else { return nil }
        if let m = models.first(where: { $0.id.lowercased() == d }) { return m }
        let ordered = models.filter { $0.section == "main" } + models.filter { $0.section != "main" }
        return ordered.first { $0.id.lowercased().hasPrefix("claude-\(d)-") || $0.shortName.lowercased() == d }
    }
}

/// The account's usage limits: one account across the fleet, so the freshest
/// status line snapshot on any host is the answer.
struct UsageLimits {
    let fiveHour: Int?, fiveHourResets: Date?
    let sevenDay: Int?, sevenDayResets: Date?
    let at: Date
}

/// The host a New-session sheet is for (sheet(item:) needs Identifiable).

extension Session {
    var badge: String {
        switch state {
        case "running": return "running"
        case "blocked": return "needs you"
        case "done": return "done"
        case "attached": return "alive"
        default: return "idle"
        }
    }
    /// "needs you · 12 min": how long the agent has been waiting, from the
    /// last hook event. Only for blocked sessions; others get the plain badge.
    var badgeWithWait: String {
        guard state == "blocked", let w = waiting else { return badge }
        return "\(badge) · \(w)"
    }
    var waiting: String? {
        guard state == "blocked", let t = shownTime else { return nil }
        let s = Int(Date().timeIntervalSince(t))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86400 { return "\(s / 3600) h \(s % 3600 / 60) min" }
        return "\(s / 86400) d"
    }
    /// One dot per state, colour carries the meaning (badge text spells it out).
    var dotColor: Color {
        switch state {
        case "running": return .green
        case "blocked": return .orange
        case "done": return .blue
        case "attached": return .gray
        default: return Color.gray.opacity(0.35)
        }
    }
    /// "MyApp" for the main session, "MyApp · review" for a named one.
    var title: String { name == "main" ? project : "\(project) · \(name)" }

    /// The model family as a tag: "FABLE" from "Fable 5.1", "OPUS" from
    /// "Claude Opus 5". Version dropped on purpose; nil without a snapshot.
    /// Exists so a costly model is visible at a glance in the sidebar.
    var modelFamily: String? {
        guard let m = model, !m.isEmpty else { return nil }
        let words = m.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { String($0) }
        let known = ["fable", "mythos", "opus", "sonnet", "haiku"]
        if let w = words.first(where: { known.contains($0.lowercased()) }) { return w.uppercased() }
        // Unknown family: the first word that is not just "Claude" or a version.
        return words.first(where: { $0.lowercased() != "claude" && $0.first?.isLetter == true })?.uppercased()
    }
    /// One colour per family so the tags tell apart without reading.
    var modelColor: Color {
        switch modelFamily {
        case "FABLE", "MYTHOS": return .purple
        case "OPUS": return .indigo
        case "SONNET": return .teal
        case "HAIKU": return .green
        default: return .gray
        }
    }
}
