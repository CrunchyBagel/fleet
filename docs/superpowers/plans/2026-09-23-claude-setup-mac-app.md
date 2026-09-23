# Claude Setup Screen (Mac app) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Mac app gets a "Claude Setup" sidebar item that draws `fleet claude --json` as a matrix across Macs, with a per-cell menu that runs `fleet claude copy` / `fleet claude rm -y`.

**Architecture:** This is a pure wrapper, in keeping with the app. `FleetCLI` runs the three commands. `FleetModel` holds the loaded matrix and the state of the one running action. A new `ClaudeSetupView.swift` draws a SwiftUI `Grid`, because the number of Macs is only known at run time. `docs/demo-fleet` learns `claude --json|copy|rm` so the screen can be built and screenshotted without real Macs.

**Tech Stack:** SwiftUI (macOS 14+), XcodeGen, bash (`docs/demo-fleet`, `test/run.sh`).

**Spec:** `docs/superpowers/specs/2026-09-23-claude-setup-mac-app-design.md` (CLI spec: `docs/superpowers/specs/2026-09-23-claude-setup-alignment-design.md`)

## Global Constraints

- No CLI (`fleet`) changes. The app only runs `fleet claude --json`, `fleet claude copy …` and `fleet claude rm -y …`.
- `app/Shared/Models.swift` holds only records mirroring CLI JSON and their helpers; nothing platform-specific. `ClaudeCell` never decodes `value`.
- `Fleet.swift` is the only file that touches the CLI. Arguments go as an array, never as a shell string.
- One screen or concern per file: the screen lives in `app/Fleet/ClaudeSetupView.swift`.
- Not polled. Loads happen after the first host load, when the screen appears, on Refresh/⌘R while it is up, and after every copy or remove.
- Only one copy or remove runs at a time. Failures go to `actionError` (the bottom banner).
- Edit `app/project.yml` only if needed. After adding a file run `xcodegen` in `app/` and commit the regenerated `app/Fleet.xcodeproj`.
- Build commands:
  - Mac: `xcodebuild -project app/Fleet.xcodeproj -scheme Fleet -derivedDataPath app/.build build`
  - iOS: `xcodebuild -project app/Fleet.xcodeproj -scheme FleetMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath app/.build build`
- `env -u FLEET_TERM test/run.sh` must stay at `0 failed`. The session exports FLEET_TERM, which breaks 5 unrelated attach tests.
- No real machine names in the repo. The demo uses studio/mini/mbp16/air.

## Review Focus

1. **A rule or name containing quotes, spaces or `@`** (`Bash(echo 'it''s')`, `superpowers@claude-plugins-official`): it must reach `fleet` intact as a single argv element. Task 2 has a demo-fleet check that echoes the argv back.
2. **"All Other Macs" when a Mac is down**: it must target only the Macs in the matrix, not `--to all`, which would include down Macs and show FAILs for them. Task 2 has a step to check this.
3. **A copy or remove that fails with only stderr** (e.g. the source Mac lost the item): the banner must still say why, not show an empty message. Task 2 has a demo-fleet case.
4. **The matrix reloading while a menu is open or an action runs**: a stale load must not overwrite a newer one, and menus must be disabled during an action. Task 2 has a step to check this.
5. **A Mac with nothing in some kind, or every Mac agreeing**: the screen must say so rather than show an empty grid. Task 1 has a step to check this.

---

## File Structure

- Modify `app/Shared/Models.swift`: add `ClaudeSetup`, `ClaudeItem`, `ClaudeCell` and their helpers.
- Modify `app/Fleet/Fleet.swift`: add `FleetCLI.claudeSetup/claudeCopy/claudeRemove`.
- Modify `app/Fleet/Model.swift`: add `Item.claudeSetup`, `FLEET_SELECT=claude-setup`, the state, and `refreshNow()`. The first load kicks off the Claude load.
- Modify `app/Fleet/ModelActions.swift`: add `loadClaudeSetup`, `claudeCopy`, `claudeRemove`.
- Create `app/Fleet/ClaudeSetupView.swift`: the screen.
- Modify `app/Fleet/ContentView.swift`: the sidebar row with its badge, the detail case, and the toolbar refresh.
- Modify `app/Fleet/FleetApp.swift`: the ⌘R items call `refreshNow()`.
- Modify `docs/demo-fleet`: add `claude --json`, `claude copy`, `claude rm`.
- Modify `test/run.sh`: demo-fleet shape checks.
- Modify `CLAUDE.md` and `README.md`.
- Regenerate `app/Fleet.xcodeproj`.

---

### Task 1: The read-only screen (data, model, sidebar, matrix)

**Files:**
- Modify: `docs/demo-fleet`, `test/run.sh`, `app/Shared/Models.swift`, `app/Fleet/Fleet.swift`, `app/Fleet/Model.swift`, `app/Fleet/ModelActions.swift`, `app/Fleet/ContentView.swift`, `app/Fleet/FleetApp.swift`
- Create: `app/Fleet/ClaudeSetupView.swift`
- Regenerate: `app/Fleet.xcodeproj`

**Interfaces:**
- Produces:
  - `ClaudeSetup { hosts: [String]; down: [String: String]; items: [ClaudeItem]; var differing: Int }`
  - `ClaudeItem { kind, name: String; differs: Bool; cells: [String: ClaudeCell?]; id; func cell(_:) -> ClaudeCell?; func text(_:) -> String; static func title(_:) -> String }`
  - `ClaudeCell { digest, summary: String; exec: Bool? }`
  - `FleetCLI.claudeSetup() async throws -> ClaudeSetup`
  - `Item.claudeSetup`
  - `FleetModel`: `claudeSetup: ClaudeSetup?`, `claudeSetupAt: Date?`, `claudeSetupError: String?`, `claudeSetupLoading: Bool`, `claudeShowRules: Bool`, `claudeAction: String?`, `claudeActionRunning: Bool`, `loadClaudeSetup()`, `refreshNow()`
  - `ClaudeSetupView`, with a private `matrix(_:cols:titles:)` and a private `ClaudeCellView(item:host:hosts:)` that Task 2 extends.

- [ ] **Step 1: Write the failing demo-fleet test**

Add to `test/run.sh`, just before the final `printf '\n%d passed, %d failed\n'` line:

```bash
section "demo-fleet (the app's stand-in)"
DEMO="$HERE/../docs/demo-fleet"
D=$(PATH="/usr/bin:/bin" "$DEMO" claude --json)
assert_eq "demo-fleet claude --json has the CLI's shape" \
  "$(printf '%s' "$D" | jq -r '[(.hosts | length > 1), (.down | type == "object"), all(.items[]; (.kind | type) == "string" and (.name | type) == "string" and (.differs | type) == "boolean" and (.cells | type) == "object")] | all')" "true"
assert_eq "  ...a cell is null or {digest, summary}"  "$(printf '%s' "$D" | jq -r '[.items[].cells[] | select(. != null) | (.digest | length >= 4) and (.summary | type) == "string"] | all')" "true"
assert_eq "  ...never a value field"                   "$(printf '%s' "$D" | jq -r '[.. | objects | has("value")] | any')" "false"
assert_eq "  ...differs agrees with the cells"        "$(printf '%s' "$D" | jq -r 'all(.items[]; .differs == ([.cells[] | if . == null then null else .digest end] | unique | length > 1))')" "true"
assert_eq "  ...with every kind"                      "$(printf '%s' "$D" | jq -r '[.items[].kind] | unique | join(",")')" "file,marketplace,mcp,perm,plugin,setting"
```

- [ ] **Step 2: Run it and check it fails**

Run: `env -u FLEET_TERM test/run.sh 2>&1 | tail -8`
Expected: the demo-fleet assertions FAIL (`claude --json` falls to `*) : ;;` and prints nothing).

- [ ] **Step 3: Teach demo-fleet `claude --json`**

In `docs/demo-fleet`, after the `hosts_info()` function, add:

```bash
# `claude --json`: made-up Claude Code setups on the three Macs that answer
# (air is down), in the CLI's shape: some plugins and MCP servers on some
# Macs only, a setting that differs, two CLAUDE.md versions, and a pile of
# permission rules, most of them on one Mac only.
claude_setup() {
  jq -n '
    def c($d; $s): {digest: $d, summary: $s};
    def on($hs; $cell): reduce ("studio", "mini", "mbp16") as $h ({}; .[$h] = (if ($hs | index($h)) then $cell else null end));
    def row($k; $n; $cells): {kind: $k, name: $n, cells: $cells};
    [ row("marketplace"; "claude-plugins-official"; on(["studio", "mini", "mbp16"]; c("0cff3e9a"; "anthropics/claude-plugins-official"))),
      row("marketplace"; "example-tools"; on(["studio"]; c("c7b41d20"; "example/tools"))),
      row("plugin"; "superpowers@claude-plugins-official"; on(["studio"]; c("e0a1"; "enabled"))),
      row("plugin"; "swift-lsp@claude-plugins-official"; on(["studio", "mbp16"]; c("e0a1"; "enabled"))),
      row("plugin"; "code-review@claude-plugins-official"; {studio: c("e0a1"; "enabled"), mini: c("d15a"; "disabled"), mbp16: null}),
      row("plugin"; "tools@example-tools"; on(["studio"]; c("e0a1"; "enabled"))),
      row("mcp"; "sentry"; on(["mini", "mbp16"]; c("91c04f7e"; "http mcp.sentry.dev"))),
      row("mcp"; "xcode"; on(["mini"]; c("3fa1b2c9"; "stdio xcrun"))),
      row("setting"; "effortLevel"; {studio: null, mini: c("aa11"; "medium"), mbp16: c("bb22"; "high")}),
      row("setting"; "model"; on(["studio", "mini", "mbp16"]; c("cc33"; "opus"))),
      row("setting"; "env"; on(["studio"]; c("9e8d7c6b"; ""))),
      row("file"; "CLAUDE.md"; {studio: c("a1f3e0"; "2480 bytes"), mini: null, mbp16: c("9c02d4"; "1911 bytes")}),
      row("file"; "scripts/render-md.py"; on(["studio", "mbp16"]; c("30ffab"; "5120 bytes") + {exec: true}))
    ]
    + [ ["Bash(git log:*)", "Bash(git diff:*)", "Bash(git status)", "Bash(swift build:*)", "Bash(swift test:*)",
         "Bash(xcodebuild:*)", "Bash(xcrun simctl list:*)", "Bash(rg:*)", "Bash(gh pr view:*)", "Bash(ls:*)",
         "Bash(echo '\''it'\'''\''s'\'')", "WebFetch(domain:developer.apple.com)", "Bash(jq:*)", "Bash(make test)",
         "Bash(git fetch:*)", "Bash(xcodegen)", "Bash(shellcheck:*)", "Read(//tmp/**)"]
        | to_entries[]
        | row("perm"; "allow:" + .value;
              on([["studio", "mini", "mbp16"], ["studio"], ["studio", "mini"]][.key % 3]; c("b5bea7"; ""))) ]
    | map(.differs = ([.cells[] | if . == null then null else .digest end] | unique | length > 1))
    | {hosts: ["studio", "mini", "mbp16"], down: {air: "offline according to Tailscale"}, items: .}'
}
```

In the `case` at the bottom, before `*)`, add:

```bash
  "claude --json") sleep 1; claude_setup ;;
```

- [ ] **Step 4: Run the test and check it passes**

Run: `env -u FLEET_TERM test/run.sh 2>&1 | tail -3` and `shellcheck docs/demo-fleet`
Expected: `0 failed`; shellcheck clean.

- [ ] **Step 5: The models (app/Shared/Models.swift)**

Append to `app/Shared/Models.swift`:

```swift
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

    /// What the matrix shows for a host, as `fleet claude` prints it.
    func text(_ host: String) -> String {
        guard let c = cell(host) else { return "·" }
        switch kind {
        case "plugin": return c.summary == "disabled" ? "○" : "●"
        case "perm": return "●"
        case "error": return "!"
        case "setting" where name != "env": return c.summary.isEmpty ? "\"\"" : c.summary
        default: return String(c.digest.prefix(4))
        }
    }

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
}
```

- [ ] **Step 6: The CLI call (app/Fleet/Fleet.swift)**

In `struct FleetCLI`, after `static func models(on:)`, add:

```swift
    /// `fleet claude --json`: every Mac's Claude Code setup, merged. It asks
    /// every Mac, so it is loaded on demand, never on the poll.
    static func claudeSetup() async throws -> ClaudeSetup {
        try decode(ClaudeSetup.self, from: run(["claude", "--json"], timeout: pollTimeout))
    }
```

- [ ] **Step 7: Model state, selection, loading (Model.swift, ModelActions.swift)**

In `app/Fleet/Model.swift`, add the case to `Item`:

```swift
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
```

Replace the `selected` initializer and its comment with:

```swift
    /// $FLEET_SELECT ("host/session", a host, or "claude-setup") picks what a launch shows, for screenshots (docs/demo-fleet).
    @Published var selected: Item? = {
        guard let v = ProcessInfo.processInfo.environment["FLEET_SELECT"], !v.isEmpty else { return .overview }
        if v == "claude-setup" { return .claudeSetup }
        return v.contains("/") ? .session(v) : .host(v)
    }()
```

After `@Published var loading: Set<String> = []`, add:

```swift
    // The Claude Setup screen: `fleet claude --json`, loaded on demand (it asks every Mac).
    @Published var claudeSetup: ClaudeSetup?
    @Published var claudeSetupAt: Date?
    @Published var claudeSetupError: String?           // the last load failed; the last good matrix stays
    @Published var claudeSetupLoading = false
    @Published var claudeShowRules = false             // permission rules expanded, kept while the app runs
    @Published var claudeAction: String?               // what the last copy/remove printed
    @Published var claudeActionRunning = false
```

In `refresh()`, change the first-load branch to also start the first Claude load:

```swift
                if lastRefresh == nil {
                    try await firstLoad(all: all)
                    loadClaudeSetup()
                } else {
```

After `func reveal(_:)`, add:

```swift
    /// ⌘R and the toolbar button: poll now, and ask for the Claude setups
    /// again when that screen is up (it is not on the poll).
    func refreshNow() {
        refresh()
        if selected == .claudeSetup { loadClaudeSetup() }
    }
```

In `app/Fleet/ModelActions.swift`, add at the end of the extension:

```swift
    /// `fleet claude --json`. A load already running wins over a new one, so
    /// an older answer can never land after a newer one.
    func loadClaudeSetup() {
        guard !claudeSetupLoading else { return }
        claudeSetupLoading = true
        Task {
            do {
                claudeSetup = try await FleetCLI.claudeSetup()
                claudeSetupAt = Date(); claudeSetupError = nil
            } catch { claudeSetupError = error.localizedDescription }
            claudeSetupLoading = false
        }
    }
```

In `app/Fleet/FleetApp.swift`, change both `Button("Refresh") { model.refresh() }.keyboardShortcut("r")` to `Button("Refresh") { model.refreshNow() }.keyboardShortcut("r")`. In `app/Fleet/ContentView.swift`, change the toolbar `Button { model.refresh() }` to `Button { model.refreshNow() }`.

- [ ] **Step 8: Sidebar row and detail (ContentView.swift)**

After `Label("Overview", systemImage: "square.grid.2x2").tag(Item.overview)`, add:

```swift
                Label("Claude Setup", systemImage: "slider.horizontal.3").tag(Item.claudeSetup)
                    .badge(model.claudeSetup?.differing ?? 0)
                    .help("How the Macs' Claude Code setups differ")
```

In the detail `switch model.selected`, add before `case .overview, nil:`:

```swift
            case .claudeSetup: ClaudeSetupView()
```

- [ ] **Step 9: The screen (new app/Fleet/ClaudeSetupView.swift)**

```swift
import SwiftUI

/// The Claude Setup screen: `fleet claude --json` as a matrix, one column per
/// Mac that answered (this Mac first). Permission rules sit behind one line:
/// they outnumber everything else and matter less. A Grid, not a Table:
/// Table's columns are fixed when compiled, the number of Macs is not.
struct ClaudeSetupView: View {
    @EnvironmentObject var model: FleetModel
    @State private var differencesOnly = true
    @State private var hiddenKinds: Set<String> = []
    @State private var ruleFilter = ""

    static let kinds = ["marketplace", "plugin", "mcp", "setting", "file"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let s = model.claudeSetup {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 18) {
                        let cols = columns(s)
                        let groups = groups(s)
                        if groups.isEmpty {
                            Label(differencesOnly ? "Every Mac that answered has the same setup." : "Nothing to show.",
                                  systemImage: "checkmark.circle").foregroundStyle(.secondary)
                        } else {
                            matrix(groups, cols: cols, titles: true)
                        }
                        rules(s, cols: cols)
                        if !s.down.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Not answering").font(.headline)
                                ForEach(s.down.sorted { $0.key < $1.key }, id: \.key) { h, why in
                                    Text("\(h): \(why)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .padding(.bottom)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let e = model.claudeSetupError {
                ContentUnavailableView("Could not read the Claude setups", systemImage: "exclamationmark.triangle", description: Text(e))
            } else {
                ProgressView("Asking every Mac…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .task { model.loadClaudeSetup() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("Claude Setup").font(.title2).bold()
                Spacer()
                Toggle("Differences only", isOn: $differencesOnly).toggleStyle(.checkbox)
                Menu("Kinds") {
                    ForEach(Self.kinds, id: \.self) { k in
                        Toggle(ClaudeItem.title(k), isOn: Binding(
                            get: { !hiddenKinds.contains(k) },
                            set: { on in if on { hiddenKinds.remove(k) } else { hiddenKinds.insert(k) } }))
                    }
                }
                .fixedSize()
                if model.claudeSetupLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { model.loadClaudeSetup() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Ask every Mac again (⌘R)")
                }
            }
            if let e = model.claudeSetupError, model.claudeSetup != nil {
                Text(e).font(.caption).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
            } else if let t = model.claudeSetupAt {
                Text("Updated \(t.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The Macs that answered, this one first.
    private func columns(_ s: ClaudeSetup) -> [String] {
        let me = model.selfHost
        return s.hosts.filter { $0 == me } + s.hosts.filter { $0 != me }
    }

    /// The main table's sections: problems first, then the kinds chosen, without permission rules.
    private func groups(_ s: ClaudeSetup) -> [(String, [ClaudeItem])] {
        var out: [(String, [ClaudeItem])] = []
        let errors = s.items.filter { $0.kind == "error" }
        if !errors.isEmpty { out.append(("error", errors)) }
        for k in Self.kinds where !hiddenKinds.contains(k) {
            let rows = s.items.filter { $0.kind == k && (!differencesOnly || $0.differs) }
            if !rows.isEmpty { out.append((k, rows)) }
        }
        return out
    }

    private func matrix(_ groups: [(String, [ClaudeItem])], cols: [String], titles: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
            GridRow {
                Text("")
                ForEach(cols, id: \.self) { h in Text(h).font(.headline) }
            }
            ForEach(groups, id: \.0) { kind, items in
                if titles {
                    GridRow {
                        Text(ClaudeItem.title(kind).uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
                            .padding(.top, 8).gridCellColumns(cols.count + 1)
                    }
                }
                ForEach(items) { item in
                    GridRow {
                        Text(item.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 380, alignment: .leading)
                            .foregroundStyle(item.kind == "error" ? Color.orange : item.differs ? Color.primary : Color.secondary)
                            .help(item.name)
                        ForEach(cols, id: \.self) { h in ClaudeCellView(item: item, host: h, hosts: cols) }
                    }
                }
            }
        }
    }

    /// Permission rules: one line with the counts, expanded on request into
    /// the same matrix with a filter (there can be over a hundred).
    @ViewBuilder
    private func rules(_ s: ClaudeSetup, cols: [String]) -> some View {
        let all = s.items.filter { $0.kind == "perm" }
        let differ = all.filter(\.differs).count
        if !all.isEmpty && (!differencesOnly || differ > 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("Permission rules").font(.headline)
                    Text(differencesOnly ? "\(differ) differ" : "\(differ) differ, \(all.count - differ) the same").foregroundStyle(.secondary)
                    Button(model.claudeShowRules ? "Hide" : "Show") { model.claudeShowRules.toggle() }
                }
                if model.claudeShowRules {
                    TextField("Filter rules", text: $ruleFilter).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    let shown = all.filter { (!differencesOnly || $0.differs) && (ruleFilter.isEmpty || $0.name.localizedCaseInsensitiveContains(ruleFilter)) }
                    if shown.isEmpty { Text("No rule matches.").foregroundStyle(.secondary) }
                    else { matrix([("perm", shown)], cols: cols, titles: false) }
                }
            }
        }
    }
}

/// One Mac's cell for one item: the CLI's symbol or value, its summary on hover.
private struct ClaudeCellView: View {
    @EnvironmentObject var model: FleetModel
    let item: ClaudeItem
    let host: String
    let hosts: [String]
    var body: some View {
        Text(item.text(host))
            .font(.body.monospaced())
            .foregroundStyle(item.cell(host) == nil ? Color.secondary : Color.primary)
            .help(tooltip)
    }
    private var tooltip: String {
        guard let c = item.cell(host) else { return "not on \(host)" }
        let s = c.summary.isEmpty ? "on \(host)" : c.summary
        return c.exec == true ? s + " · executable" : s
    }
}
```

- [ ] **Step 10: Regenerate the project and build both targets**

Run:
```bash
cd app && xcodegen && cd ..
xcodebuild -project app/Fleet.xcodeproj -scheme Fleet -derivedDataPath app/.build build 2>&1 | grep -E 'error:|warning: .*ClaudeSetup|BUILD (SUCCEEDED|FAILED)'
xcodebuild -project app/Fleet.xcodeproj -scheme FleetMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath app/.build build 2>&1 | grep -E 'error:|BUILD (SUCCEEDED|FAILED)'
```
Expected: `BUILD SUCCEEDED` twice and no errors. If `ForEach(groups, id: \.0)` does not compile because tuples are not `Identifiable`, keep `id: \.0` (String is Hashable) and check the error text. A likely fix is `Array(groups.enumerated())` with `id: \.element.0`.

- [ ] **Step 11: Look at it against demo-fleet**

Write the window-id helper to the scratchpad (not the repo), `$SCRATCH/winid.swift`:

```swift
import CoreGraphics
let owner = CommandLine.arguments[1]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == owner && (w[kCGWindowLayer as String] as? Int) == 0 {
    print(w[kCGWindowNumber as String]!); break
}
```

Run:
```bash
APP=app/.build/Build/Products/Debug/Fleet.app/Contents/MacOS/Fleet
FLEET_BIN="$PWD/docs/demo-fleet" FLEET_SELECT=claude-setup "$APP" & sleep 6
screencapture -x -o -l "$(swift "$SCRATCH/winid.swift" Fleet)" "$SCRATCH/claude-setup-1.png"
```
Then read the PNG and check it against the spec:
- The sidebar row "Claude Setup" has a badge of 11 (the non-perm rows that differ in the demo data).
- The columns are studio (self), mini, mbp16.
- The sections are Marketplaces, Plugins, MCP servers, Settings, Files, showing only differing rows: `model` does not appear, `effortLevel` does.
- The line reads "Permission rules  12 differ  Show".
- Below it: "Not answering / air: offline according to Tailscale".
Kill the app (`kill %1`) afterwards.

Then check the empty case: temporarily run with `FLEET_BIN` pointing at a scratch script that prints `{"hosts":["studio"],"down":{},"items":[]}` for `claude --json` and execs `docs/demo-fleet` otherwise. The screen must say "Every Mac that answered has the same setup." and the badge must be gone.

- [ ] **Step 12: Commit**

```bash
git add docs/demo-fleet test/run.sh app/Shared/Models.swift app/Fleet/Fleet.swift app/Fleet/Model.swift app/Fleet/ModelActions.swift app/Fleet/ContentView.swift app/Fleet/FleetApp.swift app/Fleet/ClaudeSetupView.swift app/Fleet.xcodeproj
git commit -m "Mac app: Claude Setup screen, the fleet claude matrix across Macs"
```

---

### Task 2: Copy and remove from a cell

**Files:**
- Modify: `docs/demo-fleet`, `test/run.sh`, `app/Fleet/Fleet.swift`, `app/Fleet/ModelActions.swift`, `app/Fleet/ClaudeSetupView.swift`

**Interfaces:**
- Consumes: `ClaudeItem`, `claudeAction`, `claudeActionRunning`, `loadClaudeSetup()`, `ClaudeCellView(item:host:hosts:)` (Task 1).
- Produces:
  - `FleetCLI.claudeCopy(kind:name:from:to:progress:)` and `FleetCLI.claudeRemove(kind:name:host:progress:)`
  - `FleetModel.claudeCopy(_ item: ClaudeItem, from: String, to: [String])` and `FleetModel.claudeRemove(_ item: ClaudeItem, from host: String)`

- [ ] **Step 1: Write the failing demo-fleet tests**

Append to the demo-fleet section of `test/run.sh`:

```bash
O=$(PATH="/usr/bin:/bin" "$DEMO" claude copy perm "allow:Bash(echo 'it''s')" --from studio --to mini mbp16)
assert_contains "demo-fleet claude copy prints an ok line per target" "$O" "ok    perm allow:Bash(echo 'it''s') -> mbp16"
assert_eq "  ...one per target"                       "$(printf '%s\n' "$O" | grep -c '^  ok ')" "2"
O=$(PATH="/usr/bin:/bin" "$DEMO" claude rm -y plugin swift-lsp@claude-plugins-official mbp16); RC=$?
assert_contains "demo-fleet claude rm prints ok"      "$O" "ok    removed plugin swift-lsp@claude-plugins-official on mbp16"
assert_eq "  ...exit 0"                               "$RC" "0"
O=$(PATH="/usr/bin:/bin" "$DEMO" claude rm -y mcp xcode mini); RC=$?
assert_contains "demo-fleet: removing mini's xcode fails, for the banner" "$O" "FAIL  mcp xcode on mini"
assert_eq "  ...exit 1"                               "$RC" "1"
O=$(PATH="/usr/bin:/bin" "$DEMO" claude copy mcp nope --from studio --to mini 2>&1 >/dev/null); RC=$?
assert_contains "demo-fleet: a copy that dies says so on stderr only" "$O" "fleet: no mcp 'nope' on studio"
assert_eq "  ...exit 1"                               "$RC" "1"
```

- [ ] **Step 2: Run and check they fail**

Run: `env -u FLEET_TERM test/run.sh 2>&1 | tail -12`
Expected: the new demo-fleet assertions FAIL.

- [ ] **Step 3: demo-fleet copy and rm**

In `docs/demo-fleet`'s `case`, before `*)`, add:

```bash
  # claude copy <kind> <name> --from <mac> --to <mac...>: an ok line per
  # target, slowly, so the app's status line can be seen streaming. An item
  # named "nope" is missing on the source, which fleet reports on stderr.
  "claude copy")   [ "$4" != nope ] || { echo "fleet: no $3 '$4' on $6" >&2; exit 1; }
                   for t in "${@:8}"; do sleep 0.5; printf '  ok    %s %s -> %s\n' "$3" "$4" "$t"; done ;;
  # claude rm -y <kind> <name> <mac...>; mini's xcode fails, to show the banner.
  "claude rm")     for t in "${@:6}"; do
                     sleep 0.5
                     if [ "$4 $5 $t" = "mcp xcode mini" ]; then
                       printf '  FAIL  mcp xcode on mini: claude mcp remove xcode: No MCP server named xcode\n'; exit 1
                     fi
                     printf '  ok    removed %s %s on %s\n' "$4" "$5" "$t"
                   done ;;
```

Run: `env -u FLEET_TERM test/run.sh 2>&1 | tail -3` and `shellcheck docs/demo-fleet`
Expected: `0 failed`; shellcheck clean.

- [ ] **Step 4: The CLI calls (Fleet.swift)**

After `claudeSetup()`, add:

```swift
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
```

- [ ] **Step 5: The actions (ModelActions.swift)**

Append to the extension:

```swift
    func claudeCopy(_ item: ClaudeItem, from: String, to: [String]) {
        claudeRun("claude copy") { p in try await FleetCLI.claudeCopy(kind: item.kind, name: item.name, from: from, to: to, progress: p) }
    }
    func claudeRemove(_ item: ClaudeItem, from host: String) {
        claudeRun("claude rm") { p in try await FleetCLI.claudeRemove(kind: item.kind, name: item.name, host: host, progress: p) }
    }
    /// One copy or remove at a time. Its lines stream into the status line;
    /// a failure also goes to the banner, as the FAIL line when there is one,
    /// else fleet's own message (stderr); the matrix reloads either way.
    private func claudeRun(_ what: String, _ op: @escaping (@escaping @Sendable (String) -> Void) async throws -> Void) {
        guard !claudeActionRunning else { return }
        actionError = nil
        claudeActionRunning = true
        claudeAction = ""
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
                let why = lines.last { $0.hasPrefix("FAIL") } ?? error.localizedDescription
                actionError = "\(what): \(why)"
            }
            claudeActionRunning = false
            loadClaudeSetup()
        }
    }
```

- [ ] **Step 6: The cell menu, confirmation and status line (ClaudeSetupView.swift)**

Replace `ClaudeCellView` with:

```swift
/// One Mac's cell for one item: the CLI's symbol or value, its summary on
/// hover, and a menu (right-click, or ⋯ on hover) to copy this Mac's version
/// to the other Macs, get it from one that has it, or remove it here.
private struct ClaudeCellView: View {
    @EnvironmentObject var model: FleetModel
    let item: ClaudeItem
    let host: String
    let hosts: [String]                   // the Macs that answered: "All Other Macs" is never a down one
    let remove: (ClaudeRemoval) -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 4) {
            Text(item.text(host))
                .font(.body.monospaced())
                .foregroundStyle(item.cell(host) == nil ? Color.secondary : Color.primary)
            if item.kind != "error" {
                Menu { menu } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .opacity(hover ? 1 : 0)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(tooltip)
        .contextMenu { if item.kind != "error" { menu } }
    }
    @ViewBuilder private var menu: some View {
        let others = hosts.filter { $0 != host }
        if item.cell(host) != nil {
            Menu("Copy \(host)'s Version To") {
                Button("All Other Macs") { model.claudeCopy(item, from: host, to: others) }
                Divider()
                ForEach(others, id: \.self) { h in Button(h) { model.claudeCopy(item, from: host, to: [h]) } }
            }
            .disabled(others.isEmpty || model.claudeActionRunning)
            Button("Remove from \(host)…") { remove(ClaudeRemoval(item: item, host: host)) }
                .disabled(model.claudeActionRunning)
        } else {
            Menu("Get From") {
                ForEach(others.filter { item.cell($0) != nil }, id: \.self) { h in
                    Button(h) { model.claudeCopy(item, from: h, to: [host]) }
                }
            }
            .disabled(model.claudeActionRunning)
        }
    }
    private var tooltip: String {
        guard let c = item.cell(host) else { return "not on \(host)" }
        let s = c.summary.isEmpty ? "on \(host)" : c.summary
        return c.exec == true ? s + " · executable" : s
    }
}

/// A removal waiting for its confirmation.
private struct ClaudeRemoval: Identifiable {
    let item: ClaudeItem
    let host: String
    var id: String { item.id + "\u{1F}" + host }
}
```

In `ClaudeSetupView`:
- Add `@State private var confirmRemove: ClaudeRemoval?`.
- In `matrix`, construct cells as `ClaudeCellView(item: item, host: h, hosts: cols, remove: { confirmRemove = $0 })`.
- Below `header` in `body`'s `VStack`, add the status line:

```swift
            if let a = model.claudeAction, !a.isEmpty || model.claudeActionRunning {
                HStack(alignment: .top, spacing: 8) {
                    if model.claudeActionRunning { ProgressView().controlSize(.small) }
                    ScrollView {
                        Text(a.isEmpty ? "Starting…" : a).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 80)
                }
                .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
```

- After `.task { model.loadClaudeSetup() }`, add:

```swift
        .onDisappear { if !model.claudeActionRunning { model.claudeAction = nil } }
        .confirmationDialog(
            "Remove \(confirmRemove?.item.name ?? "") from \(confirmRemove?.host ?? "")?",
            isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
            presenting: confirmRemove
        ) { r in
            Button("Remove", role: .destructive) { model.claudeRemove(r.item, from: r.host) }
        } message: { r in
            Text("Runs fleet claude rm on \(r.host). A file or settings change is backed up once as .fleet-backup; plugins, marketplaces and MCP servers are removed through Claude Code.")
        }
```

- [ ] **Step 7: Build and exercise it against demo-fleet**

Run the Mac build command from the Global Constraints. Expected: `BUILD SUCCEEDED`.

Launch as in Task 1 Step 11. Drive the app with the `anthropic-skills:computer-use` skill (load it first). If computer use is not available, ask the owner to do these clicks and report what they see. Check each against the spec:
1. Hovering a cell shows `⋯`. Right-click on studio's `superpowers` cell → "Copy studio's Version To ▸ All Other Macs / mini / mbp16", "Remove from studio…".
2. Choose "All Other Macs". The status line shows a spinner and then two `ok … -> mini` / `-> mbp16` lines, arriving about 0.5 s apart. Menus are disabled while it runs. The matrix reloads after. The demo data does not change, which is expected.
3. Right-click mini's empty `superpowers` cell → "Get From ▸ studio".
4. Right-click mini's `xcode` cell → Remove from mini… → confirm. The FAIL line appears in the status line, and the banner reads "claude rm: FAIL  mcp xcode on mini: …".
5. Show the permission rules, filter "git", and right-click a rule cell. The same menu appears.
6. The "All Other Macs" copy lists only studio/mini/mbp16 in its argv. Check with `FLEET_BIN` pointing at a scratch wrapper that appends `"$@"` to a log and then execs demo-fleet, and confirm there is no `air` or `all`.
Take screenshots of states 1, 4 and 5 to `$SCRATCH` and look at them.

- [ ] **Step 8: Commit**

```bash
git add docs/demo-fleet test/run.sh app/Fleet/Fleet.swift app/Fleet/ModelActions.swift app/Fleet/ClaudeSetupView.swift
git commit -m "Mac app: copy and remove Claude setup items from a cell"
```

---

### Task 3: Docs and a real run

**Files:**
- Modify: `CLAUDE.md`, `README.md`

**Interfaces:**
- Consumes: everything above. Produces nothing new.

- [ ] **Step 1: CLAUDE.md**

In "The apps", in the "Files in `app/Fleet/`" sentence, add `ClaudeSetupView.swift` (the Claude Setup screen) after `HostView.swift (with the Doctor section)`. After the "Machine screen:" bullet paragraph, add a paragraph:

```markdown
- Claude Setup (sidebar item under Overview, `Item.claudeSetup`,
  `FLEET_SELECT=claude-setup`): `fleet claude --json` drawn as a `Grid`
  (one column per Mac that answered, this Mac first; `Table` cannot have
  run-time columns), badge = differing items without permission rules.
  Not polled: loaded after the first load, when shown, on ⌘R/⟳ there
  (`refreshNow`) and after each action. "Differences only" and a Kinds menu
  filter it; permission rules collapse into one line with Show and a filter.
  Every cell has a menu (right-click or ⋯ on hover): copy this Mac's
  version to all other answering Macs or one, get it from a Mac that has it,
  remove it (confirmed) — `fleet claude copy|rm -y`, one at a time, lines
  streamed into a status line, failures (the FAIL line, else stderr) in the
  banner. `ClaudeCell` never decodes `value`.
```

- [ ] **Step 2: README.md**

In the "## Apps" section, after the paragraph describing the Mac app, add:

```markdown
The Mac app's Claude Setup screen shows `fleet claude` as a table across your
Macs; right-click a cell to copy that Mac's plugin, MCP server, setting or file
to the others, or remove it.
```

- [ ] **Step 3: Real run**

Build the Mac app. Launch it without `FLEET_BIN`, so it uses `~/bin/fleet`, which is linked to this checkout. Select Claude Setup and screenshot it. Expected: one column for this Mac, the Macs still on the old fleet listed under "Not answering" ("… is fleet up to date there?"), and the badge on the sidebar row. Do not run copy or remove against real Macs.

- [ ] **Step 4: Tests and commit**

Run: `env -u FLEET_TERM test/run.sh 2>&1 | tail -1`
Expected: `0 failed`.

```bash
git add CLAUDE.md README.md
git commit -m "Docs: the Mac app's Claude Setup screen"
```

---

## Amendment: list + inspector (replaces Task 1 Step 9, Task 2 Step 6)

The owner rejected the matrix after seeing it. See the spec's Amendment.
The Grid view from Task 1 Step 9 and the cell menu from Task 2 Step 6 are
replaced by the following:
- `ClaudeItem` helpers in `app/Shared/Models.swift`: `displayName`,
  `qualifier`, `versions(_:)`, `status(_:)`, `detail(_:versions:)`.
- A rewritten `app/Fleet/ClaudeSetupView.swift`: a `List` with sections,
  a toolbar picker and search, and an `.inspector` with per-Mac blocks and
  buttons.
- `FleetModel.claudeSelected: String?`.

The rest of Task 2 (demo-fleet copy/rm, `FleetCLI.claudeCopy/claudeRemove`,
`claudeRun`) is unchanged. Verification uses the scratch offscreen harness
(`NSHostingView` + `cacheDisplay`), because this shell has neither Screen
Recording nor Accessibility access. The harness also checks `status()`
strings against the demo data.
