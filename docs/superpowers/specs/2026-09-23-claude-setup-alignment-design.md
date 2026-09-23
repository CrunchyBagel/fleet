# Claude setup alignment across Macs: `fleet claude`

Date: 2026-09-23. Status: design, awaiting review.

## Problem

Each Mac in the fleet has drifted into a different Claude Code setup. On
2026-09-23 the desktop Mac had nine plugins enabled and no user MCP servers,
mini had one plugin and the `sentry` + `xcode` MCP servers, and laptop had
`swift-lsp` only, `effortLevel: high` and the `sentry` server. An agent started
on one Mac therefore has different tools from the same agent started on
another, and nothing shows this.

## Goal

The owner can **see** how the Claude setups differ across every Mac, item by
item, and **reconcile** any item by copying one Mac's version to others or
removing it. There is no canonical profile and no reference Mac: every Mac is
a peer, and the owner decides each item.

Success:

- `fleet claude` shows one matrix across all reachable hosts: which Mac has
  which plugin, marketplace, MCP server, setting and global file, and which
  differ.
- `fleet claude copy …` / `fleet claude rm …` fix a row in one command.
- `fleet claude --json` gives a later Mac app screen the same data.

## Non-goals

- No stored profile, repo or "desired state", and nothing applied
  automatically, on a timer or by `install`.
- Project-scope config (`.claude/` inside repos, `~/.claude.json`
  `projects.*.mcpServers`) is out of scope: it travels with the repo already.
- Skills: `~/.claude/skills/synced/` is handled by Claude's own account sync.
- Machine-specific settings: `hooks`, `statusLine` (fleet's own installers
  own these), and UI/bookkeeping state.
- The Mac app screen is a separate, later spec. This spec only makes sure the
  `--json` output is enough for it.

## Relationship to the recorded decisions

- Decision 6 ("git is the only transport, nothing is file-synced") stays true
  for fleet's own code and for the hosts list's origin. `fleet claude copy` is
  a **deliberate, per-item push over ssh that the owner starts**, the same
  kind of thing as `hosts push`. It is not a sync. CLAUDE.md's decisions
  section gets one line saying this, so the exception is written down.
- Decision 1: the CLI is the source of truth; the app will only draw
  `fleet claude --json` and run `copy`/`rm`.
- Decision 2: no daemon. Everything happens when the owner runs a command.

## What counts as an item

Each item has a **kind**, a **name** and, on each host, either *absent* or a
**value**. Two hosts agree on an item when their value digests are equal.

| kind          | name                    | value on a host                                           | read from |
|---------------|-------------------------|-----------------------------------------------------------|-----------|
| `marketplace` | marketplace name        | its `source` object (`{"source":"github","repo":…}`)       | `~/.claude/plugins/known_marketplaces.json` |
| `plugin`      | `name@marketplace`      | `"enabled"` or `"disabled"`                                | `enabledPlugins` in `~/.claude/settings.json` |
| `mcp`         | server name             | the whole user-scope entry                                 | `mcpServers` in `~/.claude.json` |
| `setting`     | top-level key           | its JSON value                                             | `~/.claude/settings.json` |
| `perm`        | `allow:<rule>`, `deny:<rule>`, `ask:<rule>` | `true` (present)                        | `permissions.allow/deny/ask` arrays |
| `file`        | path under `~/.claude`  | sha256 of the content                                      | `CLAUDE.md`, `scripts/*` (regular files, one level) |

Settings keys excluded from `setting` rows: `hooks`, `statusLine`, `$schema`,
`enabledPlugins` (the `plugin` rows), `extraKnownMarketplaces` (the
`marketplace` rows), `permissions` (the `perm` rows, plus
`permissions.defaultMode` and `permissions.additionalDirectories`, which *are*
`setting` rows named with that dotted path), and bookkeeping keys Claude Code
writes itself: `feedbackSurveyState` and any key ending in `State`,
`Cache` or `Timestamp`. The exclusion list lives in one variable,
`CLAUDE_SKIP_KEYS`, so it can grow.

Why permission rules are rows of their own: allowlists grow separately on
each Mac as the owner approves prompts. Copying the whole array would wipe
the other Mac's rules; one row per rule lets the owner add the ones they want.

`settings.local.json` is not read: by name it is meant to be local.

## Secrets

MCP entries and the `env` setting can hold tokens (`env`, `headers`). The
human table never prints values of `mcp` entries or of `setting env`: it
prints the digest's first 4 characters instead. `--json` carries `digest` for every
cell and `value` only for kinds that are safe to show (`marketplace`,
`plugin`, `setting` other than `env`, `perm`). `copy` moves the real value
from the source to the target over ssh (owner's own Macs, the same channel
fleet already trusts) and never writes it to FLEET_STATE or anywhere else.

An http MCP server that uses OAuth (sentry) arrives on the target
unauthenticated. `copy` prints "authenticate it there with /mcp" for an http
or sse entry.

## Commands

```
fleet claude [--json] [--diff] [host...]
fleet claude copy <kind> <name> --from <host> --to <host...>|all
fleet claude rm <kind> <name> <host...>|all
fleet claude --local                   # snapshot of this Mac, JSON (wire format)
fleet claude set --local <kind> <name> # apply the value on stdin here
fleet claude unset --local <kind> <name>
```

`this` is accepted anywhere a host is, meaning FLEET_SELF. `all` means every
host in FLEET_HOSTS apart from `--from`.

### `fleet claude` (the matrix)

Fans out with `gather`/`host_fetch` like `ls` (remote command
`fleet claude --local`, empty fallback `{}`), so an offline, slow or old
host behaves the same as in `ls`: its column shows `?` and the
"down" reason is printed under the table, as `ls` does.

Rows are grouped by kind in the order of the table above, then sorted by
name. `--diff` (and the doctor hint) shows only rows where the reachable
hosts do not all agree. The default shows every row. Cells:

- `●` present (plugin: enabled), `○` plugin installed but disabled, `·` absent.
- `setting`: the value, clipped to 12 characters (digest for `env`).
- `mcp`, `file`, `marketplace`: the digest's first 4 characters, so equal
  values are visibly equal and different ones visibly differ.

```
                              studio mini    laptop
plugin  superpowers@…official  ●      ·       ·
plugin  swift-lsp@…official    ●      ·       ●
mcp     xcode                  ·      3fa1    ·
mcp     sentry                 ·      91c0    91c0
setting effortLevel            ·      ·       high
perm    allow:Bash(git log:*)  ●      ·       ·
file    CLAUDE.md              a1f3   ·       9c02
air is down: ssh failed (fleet doctor air)
```

Column headers are host names. Rows are padded with `pad` (bash 3.2 byte
widths). No colours unless stdout is a tty.

`--json` shape:

```json
{"hosts": ["studio", "mini", "laptop"],
 "down": {"air": "ssh failed (fleet doctor air)"},
 "items": [
   {"kind": "mcp", "name": "sentry", "differs": true,
    "cells": {"studio": null,
              "mini": {"digest": "91c0…", "summary": "http mcp.sentry.dev"},
              "laptop":  {"digest": "91c0…", "summary": "http mcp.sentry.dev"}}}
 ]}
```

`null` = absent. `summary` is a short non-secret description: for `mcp` the
transport plus the host of the URL or the command's basename, for `plugin` the
state, for a `setting` the clipped value, for `file` the size. `value` is
added under the rules in *Secrets*.

### `fleet claude --local` (the snapshot, the wire format)

Prints one JSON object for this Mac:

```json
{"version": 1,
 "items": [{"kind": "plugin", "name": "swift-lsp@claude-plugins-official",
            "digest": "…", "summary": "enabled", "value": "enabled"}]}
```

For the matrix, `value` is dropped from `mcp` and `setting env` before the
snapshot leaves the Mac (the rule in *Secrets*). Digests are sha256 of `jq
-cS` of the value (files: of the content), via `shasum -a 256` (stock
macOS). Missing files count as empty objects; a file that is not JSON counts
as empty and adds `{"kind":"error","name":"<file>","summary":"not JSON"}`,
which shows as a row so the owner sees it. Needs only jq and shasum, like
`status`.

### `fleet claude copy`

1. Fetch the item's full value from `--from`:
   `fleet claude get --local <kind> <name>` there (prints the raw value, or
   the raw file content for `file`; exit 1 if absent → "not on <host>").
2. For each target (in parallel, like `hosts_push`): pipe that into
   `fleet claude set --local <kind> <name>` there, and print
   `<host>: ok` or `<host>: <error>` per target. Exit 1 if any target failed.

`set --local` on the target, per kind:

| kind          | apply |
|---------------|-------|
| `marketplace` | `claude plugin marketplace add <source>` (github repo → `owner/name`, git/url → the url, directory source → refused: "a local path, add it by hand") |
| `plugin`      | `copy plugin` first copies the plugin's `marketplace` item from the same source to any target whose snapshot lacks it (a normal `marketplace` set); then `claude plugin install <name> --scope user`; `"disabled"` → then `claude plugin disable <name>` |
| `mcp`         | `claude mcp remove -s user <name>` if present (ignore failure), then `claude mcp add-json -s user <name> <json>` |
| `setting`     | jq merge of the key into `~/.claude/settings.json` (tmp + mv), the same pattern as `install_hooks`; dotted `permissions.*` names set that subkey |
| `perm`        | append the rule to `permissions.<list>` if missing (jq, tmp + mv) |
| `file`        | write to a temp file beside the target then mv. The first time a file is overwritten, `<file>.fleet-backup` is made (like `settings.json.fleet-backup`). `scripts/*` keeps the source's executable bit (copy passes it) |

`claude` is found via FLEET_PATH (it lives in `~/.local/bin`). A missing
`claude` fails the plugin, marketplace and mcp kinds with "claude not found on
<host>". A plugin install that Claude Code refuses without a person (a
marketplace-declared command needing `--accept-command`) is reported with
its message and "install it on <host> by hand"; fleet never passes `-y` or
`--accept-command`.

All values reach the target on stdin, never on the ssh command line. Kind and
name go through `shq` (a permission rule is full of quotes and parentheses).
`kind` is checked against the fixed list before anything runs; `file` names
are checked against `CLAUDE.md` or `scripts/<name>` with no `/` or `..` in
`<name>`.

### `fleet claude rm`

Runs `fleet claude unset --local <kind> <name>` on each named host:
`claude plugin uninstall --scope user`, `claude plugin marketplace remove`
(refused while a plugin from it is enabled there: "remove its plugins
first"), `claude mcp remove -s user`, jq `del` of the key or rule, or deletes
the file (after the same one-time backup). Without `-y` it asks on a tty and
refuses otherwise, like `kill`.

## Doctor

`fleet doctor` (the fan-out form) adds one line after the host-list checks,
using the same gathered snapshots:

- `ok   claude setup is the same on every reachable Mac`
- `·    claude setup differs on 7 items (fleet claude --diff)`

It is informational (`·`, not `FAIL`), because different setups can be
intentional. `doctor --local` does not change.

## Code shape (in `fleet`)

One section, `# ---- claude setup`, near `models`:

- `claude_snapshot_local`: builds the `--local` JSON (one jq program per source file).
- `claude_get_local <kind> <name>`: prints the full value.
- `claude_set_local`, `claude_unset_local <kind> <name>`: one `case` on kind each.
- `cmd_claude`: argument parsing and dispatch; the matrix is one jq merge of
  the gathered `<host>.json` files into the `--json` shape, and the table is
  drawn from `@tsv` of that (the last column may be empty, no others).
- `CLAUDE_SKIP_KEYS`, `claude_valid_kind`, `claude_valid_file`.
- Dispatch line `claude) cmd_claude "$@" ;;`, usage text, CLAUDE.md command list.

Keep to bash 3.2: no `case` inside `$(...)` in double quotes (the kind
dispatch is in functions), no `mapfile`/`declare -A`.

## Testing (`test/run.sh`)

- A new shim `test/shims/claude` that logs argv to a file and applies the
  subcommands fleet uses (`plugin install/uninstall/disable`,
  `plugin marketplace add/remove`, `mcp add-json/remove`) to the fake
  HOME's `settings.json` / `~/.claude.json` / `known_marketplaces.json`, so
  the snapshot afterwards shows the change. It also has a mode that refuses
  an install with an `--accept-command` message.
- Fixtures: this machine and the fake remote "studio" start with different
  plugins, an mcp entry with an `env` token, a differing `effortLevel`,
  different permission rules and different CLAUDE.md files.
- Assertions:
  - The matrix has the expected rows and cells, `--diff` drops the agreeing
    ones, and dead/nofleet/slow hosts show `?` plus their reason.
  - `--json` never contains the token string (grep the output).
  - `copy` of plugin (with its marketplace), mcp, setting, perm and file each
    changes studio's snapshot to match.
  - `copy` of a permission rule with quotes and parentheses survives.
  - `rm` removes each kind; `rm` without `-y` and without a tty refuses.
  - The file backup is made once, and `file` names with `..` are refused.
  - A refused plugin install reports "by hand" and exits 1.
  - Doctor prints the "differs on N items" line.
- Everything runs under `/bin/bash`; shellcheck stays clean.

## Docs

- CLAUDE.md: the command in the command list, the item table and the
  exclusions in a short paragraph, and the decision 6 note.
- README: a short "Keeping Claude setups aligned" section.
- SECURITY.md: `copy` moves MCP/env secrets between the owner's Macs over
  ssh on explicit request, `--json` and the table never print them, and a
  plugin install never auto-accepts a marketplace command.

## Later (separate spec)

A "Claude setup" screen in the Mac app: the matrix from `fleet claude --json`,
with a menu per cell (copy this Mac's version to… / remove here) that runs
`copy`/`rm -y` and streams the output.
