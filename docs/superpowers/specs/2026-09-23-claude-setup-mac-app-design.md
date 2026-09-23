# Claude Setup screen in the Mac app

Date: 2026-09-23. Status: design, awaiting review.
Builds on: `2026-09-23-claude-setup-alignment-design.md` (the `fleet claude` CLI).

## Goal

Show the `fleet claude` matrix in the Mac app, and let the owner make one
item match between Macs, or remove it, from a menu on a cell. There is no
reference Mac and no bulk "make everything match": each change is one
`fleet claude copy` or `fleet claude rm`, exactly as on the command line.

Success:

- A "Claude Setup" sidebar item shows how the Macs' Claude Code setups
  differ, with a badge counting the differing items.
- From any cell the owner can copy that Mac's version to one or all other
  Macs, fetch it from a Mac that has it, or remove it (after confirming). They
  see the CLI's output and the result without leaving the screen.

## Non-goals

- The iOS app (`FleetMobile`).
- Polling. Each load asks every Mac, so it stays off the 8-second poll.
- Bulk actions ("make all like laptop"). They can come later if the per-cell
  menu proves slow.
- Any change to the CLI. Everything the screen needs is already in
  `fleet claude --json`, `copy` and `rm -y`.

## What the owner sees

### Sidebar

A row labelled "Claude Setup" (SF Symbol `slider.horizontal.3`) directly
under "Overview", outside the Machines section. Its badge is the number
of rows where `differs` is true and `kind` is not `perm`. There is no badge
before the first load or when the count is 0. Selecting it shows the
screen below in the detail column.

### When it loads

`fleet claude --json` runs:

- once after the app's first load of hosts (so the badge is there),
- whenever the screen is selected,
- when Refresh (⟳, ⌘R while the screen is up) is pressed,
- after every copy or remove finishes, whether it succeeded or failed.

While a load runs, the Refresh button shows a spinner and the old matrix
stays visible. A failed load (non-zero exit, bad JSON, the 60 s
`FleetCLI.pollTimeout`) shows its message in place of "Updated …" and keeps
the last good matrix. The header reads "Updated 10:42" after a good load.

### The matrix

A header row holds the title, a "Differences only" toggle (on by default),
a "Kinds" menu (checkboxes for Marketplaces, Plugins, MCP servers,
Settings, Files; all on by default) and Refresh.

The table has one column for the item name and one column per Mac in
`hosts` order. The Mac running the app comes first, labelled with its
name. Rows are grouped under section headers in the CLI's kind order.
`error` rows (a Mac whose settings file is not JSON) are always shown,
under "Problems", in orange.

Cells use the CLI's symbols:

- `●` present (plugin: enabled)
- `○` plugin disabled
- `·` absent
- a setting's `summary` (its value, clipped to 12)
- the first 4 characters of the digest for marketplace, mcp, file and the
  `env` setting

A row that differs has its name in the primary colour; a row that agrees
is secondary. The help tooltip of a cell is its `summary` plus, for files,
"executable" when `exec` is true. The JSON never holds secrets, so a
tooltip cannot show one.

Macs that did not answer (`down`) get no column. They are listed under
the table as "not answering: mini: ssh failed (fleet doctor mini)", the same
way as on the Overview.

### Permission rules

`perm` rows never appear in the main table. Below it, a single line reads
"Permission rules: 97 differ, 13 the same" with a Show button. The counts
follow the "Differences only" toggle the same way the CLI's summary line
follows `--diff`. Show expands an inline table with the same columns and
cell menus, plus a filter field that matches the rule text. Hide collapses
it. The expanded state is kept while the app runs.

### Cell menu

Right-click on any cell, or the `⋯` button that appears on hover over a
cell, opens the menu. Here M is that cell's Mac and "others" are the
other Macs that answered.

- **The cell has the item:**
  - "Copy M's version to ▸" → "All Other Macs", then one entry per other
    Mac. This runs `fleet claude copy <kind> <name> --from M --to all`
    (or `--to <mac>`).
  - "Remove from M…" asks "Remove <kind> <name> from M?" with a
    destructive Remove button, then runs `fleet claude rm -y <kind>
    <name> M`.
- **The cell is empty:** "Get from ▸", with one entry per Mac whose cell
  has the item. This runs `fleet claude copy <kind> <name> --from <that
  mac> --to M`.
- **An `error` row** has no menu.

Only one copy or remove runs at a time. While one runs, every cell menu is
disabled and a status line under the header streams the CLI's output lines
(`ok    plugin superpowers@… -> studio`, then indented messages such as
"authenticate it on studio with /mcp"). When it finishes, the status line
keeps the last output until the next action or until the screen is left,
and the matrix reloads.

A non-zero exit (a FAIL line, a refusal) shows in the app's existing
bottom banner (`actionError`) as "claude copy: <last line of output>" or
"claude rm: …". The streamed lines stay in the status line so the owner can
read every target's result.

## How it is built

### Shared/Models.swift

This mirrors the `fleet claude --json` shape verbatim and holds no platform
code:

```swift
struct ClaudeSetup: Decodable {
    let hosts: [String]
    let down: [String: String]
    let items: [ClaudeItem]
}
struct ClaudeItem: Decodable, Identifiable {
    let kind: String, name: String, differs: Bool
    let cells: [String: ClaudeCell?]      // host -> nil when absent
    var id: String { kind + "\u{1F}" + name }
}
struct ClaudeCell: Decodable {
    let digest: String, summary: String
    let exec: Bool?
}
```

`value` is not decoded. The screen does not need it, and leaving it out
keeps a future secret-bearing field from being shown by accident. Helpers
live next to the models, as the `Session` helpers do: the cell's display
text (the rules above), a kind's section title, and the badge count.

### Fleet.swift (`FleetCLI`)

- `claudeSetup() async throws -> ClaudeSetup` runs `claude --json` with
  `pollTimeout`.
- `claudeCopy(kind:name:from:to:progress:) async throws` runs
  `claude copy <kind> <name> --from <from> --to <to…>` through
  `runStreaming`. `to` is `["all"]` or a list of hosts.
- `claudeRemove(kind:name:host:progress:) async throws` runs
  `claude rm -y <kind> <name> <host>` through `runStreaming`.

The arguments are passed as an argument array, never as a shell string, so
names with quotes (permission rules) need no quoting.

### Model.swift / ModelActions.swift

- `Item.claudeSetup`, with id `"claude-setup"`. `$FLEET_SELECT=claude-setup`
  selects it at launch, and is checked before the host/session parsing.
- State: `@Published var claudeSetup: ClaudeSetup?`, `claudeSetupAt:
  Date?`, `claudeSetupError: String?`, `claudeSetupLoading: Bool`,
  `claudeAction: String?` (the status line text; non-nil while or after an
  action) and `claudeActionRunning: Bool`.
- `loadClaudeSetup()` is async, skips if a load is running, and sets the
  state above.
- `claudeCopy(…)` and `claudeRemove(…)` follow the `open`/`kill` pattern:
  clear `actionError`, set `claudeActionRunning`, stream lines into
  `claudeAction`, set `actionError` on failure, then call `loadClaudeSetup()`.
- The first load kicks off `loadClaudeSetup()` once the host list is known.
  Selecting `.claudeSetup` triggers a load (in the view's `.task` or
  `onChange` of `selected`).

### ClaudeSetupView.swift (new, app/Fleet/)

This file holds the whole screen: header, main table, permission rules
section, cell view with hover `⋯` and context menu, and the remove
confirmation. It does not use SwiftUI's `Table`: its columns are fixed at
compile time and the number of Macs is not. It uses a `Grid` inside a
`ScrollView`, which also allows section header rows. Column widths come
from the longest cell text per column, as the CLI's table does.

### ContentView.swift

The sidebar row and badge go under Overview, and the detail `switch` gets a
`case .claudeSetup: ClaudeSetupView()`.

### project.yml

The new file is inside `app/Fleet/`, which the `Fleet` target's sources
already cover. Run `xcodegen` in `app/` and commit the regenerated
project.

### docs/demo-fleet

It answers `claude --json` with made-up setups on studio, mini, mbp16 and
air (air down):

- a few plugins differing, one disabled
- the `sentry`/`xcode` MCP servers present on some Macs
- `effortLevel` differing
- two different `CLAUDE.md` digests
- about 30 permission rules, most of them on one Mac only

`claude copy …` and `claude rm …` print plausible `ok` lines, one per
target, with a short delay between lines so the streaming can be seen.
`claude rm` of `mcp xcode` on mini prints a FAIL line and exits 1, so the
error path can be seen.

## Verification

There is no Swift test target, so the checks are:

- `xcodebuild -project app/Fleet.xcodeproj -scheme Fleet -derivedDataPath
  app/.build build` succeeds.
- The FleetMobile build succeeds too, because Shared/Models.swift changed.
- The Mac app launched with `FLEET_BIN=docs/demo-fleet
  FLEET_SELECT=claude-setup` is screenshotted in four states: the default
  view (differences only), with permission rules shown, a cell menu open,
  and after a failing remove (banner up). The screenshots are looked at
  against this spec.
- One launch against the real CLI on this Mac, to confirm the matrix
  loads, the badge appears, and "not answering" lists the Macs that still
  run old fleet.
- `test/run.sh` still passes. The CLI is unchanged, but demo-fleet is in
  the repo.

## Docs

- CLAUDE.md, in "The apps": a paragraph on the Claude Setup screen covering
  the sidebar item, when it loads, the per-cell menu, and permission rules
  collapsed. Add `ClaudeSetupView.swift` to the file list.
- README "Apps" section: one sentence.
