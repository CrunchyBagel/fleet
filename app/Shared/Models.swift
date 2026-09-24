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
    let waitingFor: String?     // while blocked: idle_prompt = waiting for your next message, else a real question
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
        case waitingFor = "waiting_for"
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

    /// The model family: "FABLE" from "Fable 5.1", "OPUS" from "Claude Opus 5";
    /// nil without a snapshot. Picks the tag colour; `modelTag` adds the version.
    var modelFamily: String? {
        guard let m = model, !m.isEmpty else { return nil }
        let words = m.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { String($0) }
        let known = ["fable", "mythos", "opus", "sonnet", "haiku"]
        if let w = words.first(where: { known.contains($0.lowercased()) }) { return w.uppercased() }
        // Unknown family: the first word that is not just "Claude" or a version.
        return words.first(where: { $0.lowercased() != "claude" && $0.first?.isLetter == true })?.uppercased()
    }
    /// The sidebar tag: family plus version, "OPUS 5.5" from "Opus 5.5 (1M
    /// context)", "FABLE 5.1" from "Claude Fable 5.1". The version is the
    /// first number after the family word; just the family when there is none.
    var modelTag: String? {
        guard let family = modelFamily, let m = model else { return nil }
        let words = m.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        guard let i = words.firstIndex(where: { $0.uppercased().contains(family) }) else { return family }
        let version = words[(i + 1)...].first(where: { $0.first?.isNumber == true })?
            .prefix(while: { $0.isNumber || $0 == "." })
        guard let v = version?.trimmingCharacters(in: CharacterSet(charactersIn: ".")), !v.isEmpty else { return family }
        return "\(family) \(v)"
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

// `fleet claude --json`: how the Claude Code setup differs across the Macs.
// Mirrors the CLI, except `value`, which is left undecoded on purpose: the
// screen never needs it, so nothing added to it later can show a secret.
struct ClaudeSetup: Decodable {
    let hosts: [String]
    let down: [String: String]
    let items: [ClaudeItem]
    /// Rows that differ, permission rules apart (they outnumber the rest and matter less).
    var differing: Int { items.filter { $0.differs && $0.kind != "perm" }.count }
}

struct ClaudeItem: Decodable, Identifiable {
    let kind: String
    let name: String
    let differs: Bool
    let cells: [String: ClaudeCell?]       // host -> nil when that Mac lacks it
    var id: String { kind + "\u{1F}" + name }

    func cell(_ host: String) -> ClaudeCell? { cells[host] ?? nil }

    static func title(_ kind: String) -> String {
        switch kind {
        case "marketplace": return "Marketplaces"
        case "plugin": return "Plugins"
        case "mcp": return "MCP servers"
        case "setting": return "Settings"
        case "perm": return "Permission rules"
        case "file": return "Files"
        case "error": return "Problems"
        default: return kind
        }
    }
}

struct ClaudeCell: Decodable {
    let digest: String
    let summary: String
    let exec: Bool?
    let plugin: String?        // an MCP server this Mac has only because that plugin provides it
}

// How a Claude setup item reads to a person: plain names, what differs in
// words, and version letters instead of digests.
extension ClaudeItem {
    /// A plugin without its "@marketplace", a rule without its "allow:".
    var displayName: String {
        switch kind {
        case "plugin": return name.split(separator: "@", maxSplits: 1).first.map(String.init) ?? name
        case "perm": return name.split(separator: ":", maxSplits: 1).last.map(String.init) ?? name
        default: return name
        }
    }
    /// What the display name dropped: a plugin's marketplace, a rule's list.
    var qualifier: String? {
        switch kind {
        case "plugin": return name.contains("@") ? name.split(separator: "@", maxSplits: 1).last.map(String.init) : nil
        case "perm": return name.contains(":") ? name.split(separator: ":", maxSplits: 1).first.map(String.init) : nil
        default: return nil
        }
    }
    /// Each distinct value, lettered A, B, … in the order of `hosts`.
    func versions(_ hosts: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for h in hosts {
            if let d = cell(h)?.digest, out[d] == nil { out[d] = String(Character(UnicodeScalar(UInt8(65 + out.count % 26)))) }
        }
        return out
    }
    /// The plugin that provides this MCP server on some Mac, if any.
    var providingPlugin: String? { cells.values.compactMap { $0?.plugin }.first }

    /// What differs across `hosts` (the Macs that answered), in words.
    func status(_ hosts: [String]) -> String {
        let have = hosts.filter { cell($0) != nil }, missing = hosts.filter { cell($0) == nil }
        if kind == "error" { return "Not valid JSON on " + have.formatted(.list(type: .and)) }
        if kind == "mcp", providingPlugin != nil {
            // Where it comes from matters more than its digest: a plugin here, an entry there.
            let via = have.filter { cell($0)?.plugin != nil }, alone = have.filter { cell($0)?.plugin == nil }
            var parts: [String] = []
            if !via.isEmpty { parts.append("Via plugin on " + via.formatted(.list(type: .and))) }
            if !alone.isEmpty { parts.append("Standalone on " + alone.formatted(.list(type: .and))) }
            if !missing.isEmpty { parts.append("Missing on " + missing.formatted(.list(type: .and))) }
            return parts.joined(separator: " · ")
        }
        guard !have.isEmpty else { return "Nowhere" }
        if have.count == 1 && !missing.isEmpty { return "Only on \(have[0])" }
        var parts: [String] = []
        if Set(have.compactMap { cell($0)?.digest }).count > 1 {
            switch kind {
            case "plugin":
                parts.append("Disabled on " + have.filter { cell($0)?.summary == "disabled" }.formatted(.list(type: .and)))
            case "setting" where name != "env":
                // The CLI clips values to 12 characters: when two differing
                // values clip alike, say how many there are instead.
                var seen: [String] = []
                for h in have { let v = cell(h)!.summary; if !seen.contains(v) { seen.append(v) } }
                parts.append(seen.count < versions(have).count ? "\(versions(have).count) versions"
                             : seen.map { $0.isEmpty ? "\"\"" : $0 }.joined(separator: " · "))
            default:
                parts.append("\(versions(have).count) versions")
            }
        }
        if !missing.isEmpty { parts.append((kind == "setting" ? "Not set on " : "Missing on ") + missing.formatted(.list(type: .and))) }
        return parts.isEmpty ? "Same on all Macs" : parts.joined(separator: " · ")
    }
    /// Whether the item differs between just these Macs (missing counts as a value).
    func differs(among hosts: [String]) -> Bool {
        Set(hosts.map { cell($0)?.digest }).count > 1
    }
    /// The item from one Mac's side, against `others` (every other Mac
    /// that answered, or the one it is compared with): "Missing on studio
    /// · on the other Macs", "Only on studio", "Version A on studio · B on
    /// mini", "Same as mini".
    func status(on h: String, against others: [String]) -> String {
        let have = others.filter { cell($0) != nil }, missing = others.filter { cell($0) == nil }
        func list(_ hs: [String]) -> String {
            hs.count == others.count && others.count > 1 ? "the other Macs" : hs.formatted(.list(type: .and))
        }
        let missWord = kind == "setting" ? "not set on" : "missing on"
        let missCap = kind == "setting" ? "Not set on" : "Missing on"
        if kind == "error" { return cell(h) != nil ? "Not valid JSON on \(h)" : "Not valid JSON on " + list(have) }
        guard let c = cell(h) else {
            if have.isEmpty { return "Nowhere" }
            return "\(missCap) \(h) · on " + list(have)
        }
        if have.isEmpty { return others.count == 1 ? "Only on \(h), not on \(others[0])" : "Only on \(h)" }
        var parts: [String] = []
        if kind == "mcp", providingPlugin != nil {
            // Where it comes from matters more than its digest: a plugin here, an entry there.
            let via = have.filter { cell($0)?.plugin != nil }, alone = have.filter { cell($0)?.plugin == nil }
            if c.plugin != nil, !alone.isEmpty { parts.append("Via plugin on \(h) · standalone on " + list(alone)) }
            if c.plugin == nil, !via.isEmpty { parts.append("Standalone on \(h) · via plugin on " + list(via)) }
        } else {
            let diff = have.filter { cell($0)?.digest != c.digest }
            if !diff.isEmpty {
                switch kind {
                case "plugin":
                    parts.append(c.summary == "disabled" ? "Disabled on \(h) · enabled on " + list(diff)
                                                         : "Enabled on \(h) · disabled on " + list(diff))
                case "setting" where name != "env":
                    // The CLI clips values to 12 characters: when the other
                    // values clip alike, say only that they differ.
                    var seen: [String] = []
                    for o in diff { let v = cell(o)!.summary; if !seen.contains(v) { seen.append(v) } }
                    let mine = c.summary.isEmpty ? "\"\"" : c.summary
                    if seen.count == 1 && seen[0] != c.summary {
                        parts.append("\(mine) on \(h) · \(seen[0].isEmpty ? "\"\"" : seen[0]) on " + list(diff))
                    } else {
                        parts.append("\(mine) on \(h) · differs on " + list(diff))
                    }
                default:
                    let v = versions([h] + others)
                    parts.append("Version \(v[c.digest] ?? "?") on \(h) · "
                                 + diff.map { "\(v[cell($0)!.digest] ?? "?") on \($0)" }.joined(separator: ", "))
                }
            }
        }
        if !missing.isEmpty { parts.append((parts.isEmpty ? missCap : missWord) + " " + list(missing)) }
        if parts.isEmpty { return others.count == 1 ? "Same as \(others[0])" : "Same on all Macs" }
        return parts.joined(separator: " · ")
    }
    /// One Mac's line in the inspector.
    func detail(_ host: String, versions: [String: String]) -> String {
        guard let c = cell(host) else {
            switch kind {
            case "setting": return "Not set"
            case "perm": return "Not listed"
            case "file": return "Missing"
            case "error": return "OK"
            default: return "Not installed"
            }
        }
        let letter = versions.count > 1 ? versions[c.digest].map { "Version \($0)" } : nil
        if let p = c.plugin { return "Via the \(p.split(separator: "@").first.map(String.init) ?? p) plugin" }
        switch kind {
        case "plugin": return c.summary == "disabled" ? "Installed, disabled" : "Enabled"
        case "perm": return "Listed"
        case "error": return "Not valid JSON: fix it by hand"
        case "setting" where name == "env": return ["Set (values hidden)", letter].compactMap { $0 }.joined(separator: " · ")
        case "setting":
            let shown = c.summary.isEmpty ? "\"\"" : c.summary
            return c.summary.hasSuffix("…") ? [letter, shown].compactMap { $0 }.joined(separator: " · ") : shown
        case "mcp" where providingPlugin != nil:
            return "Standalone · " + c.summary          // the difference is where it comes from, not a version
        default:
            let exec = c.exec == true ? "executable" : nil
            var summary: String? = c.summary.isEmpty ? nil : c.summary
            if kind == "file", let n = Int64(c.summary.replacingOccurrences(of: " bytes", with: "")) {
                summary = ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
            }
            return [letter, summary, exec].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

/// `fleet move --targets <host> <session> --json`: whether the session can
/// move now, and which other Macs can take it (and why the others can not).
struct MoveTargets: Codable, Hashable {
    struct Source: Codable, Hashable { let host: String; let session: String }
    struct Target: Codable, Hashable, Identifiable {
        let host: String
        let project: String
        let ok: Bool
        let why: String
        var id: String { host }
    }
    let source: Source
    let movable: Bool
    let why: String
    let targets: [Target]
}

extension Session {
    /// Why this session can not move to another Mac yet, from the record
    /// alone; the CLI's move_refusal, same rules in the same order.
    var moveBlocker: String? {
        if state == "running" { return "The agent is working; move it once it is done" }
        if state == "blocked" && waitingFor != "idle_prompt" { return "The agent is waiting on you; answer it first" }
        if branch == "(detached)" { return "Detached HEAD: there is no branch to move" }
        if dirty { return "Uncommitted changes; commit and push them first" }
        if upstream.isEmpty { return "\(branch) was never pushed" }
        if ahead > 0 { return "\(ahead) commit\(ahead == 1 ? "" : "s") not pushed" }
        return nil
    }
}
