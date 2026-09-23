# fleet

Single-file bash CLI (`fleet`) that manages Claude Code agent git worktrees across
several Macs on a Tailscale tailnet (typically a desktop workhorse, one or more
laptops, an always-on mini acting as CI, and possibly a terminal-only thin
client). Machines reach each other by tailnet hostname over ssh. Terminal is
Ghostty. Written by and for an indie iOS/macOS developer; "the owner" below is
whoever runs it.

## Decisions already made. Do not relitigate.

1. CLI first. A SwiftUI menu bar app may later wrap `fleet json`; the CLI stays
   the single source of truth so it works from a thin client and over ssh from a phone.
2. No daemon. A per-host launchd daemon was rejected: nothing to deploy/version.
3. Agent state comes only from Claude Code hook events (`fleet hook <state>`).
   Never scrape tmux pane output to infer state.
4. Polling with parallel ssh fan-out is accepted; latency is the known tradeoff.
5. Not a git client. No diffs, no history, no staging. Ever.
6. Git is the only transport between machines, including for installing fleet
   itself (`fleet install` clones/pulls this repo). Nothing is file-synced.
   `fleet claude copy` is not an exception: it is a per-item push over ssh
   that the owner starts, like `hosts push`, and nothing syncs by itself.
7. Anything to be debugged is built locally by Xcode on the Mac in front of the
   owner. Remote machines never produce runnable artifacts.

## Constraints

- bash only, one file, runs on stock macOS `/bin/bash` 3.2 (shebang is
  `/usr/bin/env bash`, so it may also run under Homebrew bash 5; both must work).
  No `mapfile`, `declare -A`, `${var,,}`, `&>`, `|&`, `;&`, `printf -v`,
  `readlink -f`. bash 3.2 `printf %-Ns` pads by bytes: use `pad`. A `case`
  inside `$(...)` inside double quotes does not parse on 3.2 (the `)` of a
  pattern ends the substitution): put it in a function. `bash -n` does not
  catch this; run the code path under `/bin/bash`.
- Dependencies: git, jq (macOS 15+ ships `/usr/bin/jq`), fzf (pick only),
  tmux (sessions), ssh. `fleet status` must need only git and jq.
- `set -euo pipefail` is on. shellcheck is clean; every suppression carries a
  reason on the same line. Keep it that way.
- Don't add features unless asked. Don't rewrite in another language.
- Every Mac clones the repo itself into FLEET_CHECKOUT (`~/Developer/fleet`)
  via `fleet install` (`clone_repo`: `gh` when installed, else plain git over
  https; gh is optional, needed only so agents can push to GitHub from
  ssh-started sessions), which also pulls on re-run and links `~/bin/fleet`
  to the checkout.
  `fleet install <host>` runs the same over ssh. Configs and the host list
  never go into git.
- Host list is `~/.config/fleet/hosts` on every machine (one ssh alias per
  line, `#` comments), read into FLEET_HOSTS at startup. `fleet hosts add|rm`
  edits it locally then pushes the file to every reachable host; `hosts push`
  and `install|update` push it again. Doctor flags a host whose list or script
  hash differs from this machine's. FLEET_HOSTS in the config overrides the
  file and doctor flags that too.
- FLEET_SELF defaults to the machine's tailnet name (first label of
  `tailscale status --self --json` `.Self.DNSName`; the CLI is found on PATH
  or inside `/Applications/Tailscale.app`), else `hostname -s`. Install writes
  it into the config and adds it to hosts. `fleet hosts add` with no name
  adds every macOS node on the tailnet. Host names are whatever ssh resolves;
  with MagicDNS no ssh config is needed.
- Per-machine config `~/.config/fleet/config` (sourced bash, wins over env;
  the example is embedded in the script, `write_example_config`):
  FLEET_SELF (must be in the host list), FLEET_ROOT (`~/Developer`; install seeds
  the config with `guess_root`, the folder one level under `$HOME` with the
  most `*/.git`, whatever its name, and doctor names that guess when
  FLEET_ROOT is missing or holds no project; an existing config is never
  rewritten, so a Mac whose clones live elsewhere needs the line edited),
  FLEET_STATE (`~/.local/state/fleet`), FLEET_BRANCH_PREFIX (`agent/`),
  FLEET_SIM, FLEET_SSH_TIMEOUT (3, connect), FLEET_CMD_TIMEOUT (10, whole remote
  status), FLEET_PATH (literal `$HOME/bin:$HOME/.local/bin:/opt/homebrew/bin:
  /usr/local/bin`), FLEET_CHECKOUT (`~/Developer/fleet`), FLEET_REPO
  (`CrunchyBagel/fleet`, gh owner/name).
- Security (SECURITY.md is the user-facing version, keep them in step):
  hosts are validated by `valid_host` on add and on load (letters, digits,
  `._-`; nothing that could be an ssh option). `update_checkout` is the only
  code path that changes fleet's own code: fetch, list incoming, fast-forward
  only, and when `~/.config/fleet/allowed_signers` (`FLEET_SIGNERS`) exists
  the new tip must `git verify-commit` against it (ssh signatures).
  `hosts_push` carries that file along with the hosts list. `repoint_origin`
  rewrites a github.com origin to FLEET_REPO on install/update (the repo moved
  from HendX to CrunchyBagel in September 2026; the noreply commit email keeps the
  old login, that is fine). Agents never ssh
  out; only control machines hold keys. Nothing runs on a timer.
- PATH rule: ssh non-interactive shells and Claude Code hooks never read
  `.zshrc`/`.zprofile`. fleet prepends FLEET_PATH to its own PATH at startup and
  every remote or `open`-spawned command goes through `with_path`, which sends
  FLEET_PATH with `$HOME` unexpanded so the remote expands its own. Never call
  `ssh host 'fleet …'` or `bash -lc` and hope the login PATH is there.

## Layout and conventions

- Layouts (see `project_layout`): **plain** = `$FLEET_ROOT/<project>/.git`,
  sessions run in the clone, no worktrees; **worktrees** = plain after
  `fleet convert` (marker is `.git/fleet-worktrees`; `.claude/worktrees/` alone
  is not enough, Claude Code's `--worktree` creates that too; excluded via
  `.git/info/exclude`), worktrees at `<project>/.claude/worktrees/<task>` on
  `agent/<task>`; **container** = `<project>/main` clone with sibling
  worktrees, the original layout, still supported. The primary clone is always
  reported as name `main`. Use `project_repo`/`worktree_path`, never hardcode.
  The owner is easing in: most projects stay plain for now.
- tmux session name is `session_name project task` = `<project>-<task>` with
  `.` and `:` turned into `_`, because tmux does that itself. Always go through
  the helper. `new` starts a shell and types `claude -n <FLEET_SELF>-<session> $FLEET_CLAUDE_ARGS`
  (default `--permission-mode auto --remote-control`) into it so the session
  outlives the agent and shows in the Claude apps, where the machine prefix
  tells two Macs' `<project>-main` apart (only that label carries it; the tmux
  session, the records and both Fleet apps do not).
- Agents commit and push with `-u`; until they push, `open` from another machine
  refuses and `ls` shows `no upstream`. `fleet status` never fetches, so
  ahead/behind reflect the last fetch on that host.
- Per-worktree DerivedData lives in `<worktree>/.build` (globally gitignored).
- `open` finds the local clone by the record's `project` name, else by its
  `remote` (`project_for_remote`: the one clone under FLEET_ROOT whose origin
  is the same repo, `repo_key` = lowercase owner/name whatever the URL
  shape; two matches = no guess), because the same repo can sit under
  different directory names on different Macs. `pick`/`record_for` rows carry
  the origin URL as their last column for this.
- `open` ends in `open_checkout`, driven by FLEET_OPEN (`auto` default):
  `auto` = xcode when `xed` exists and `xcode_target` finds a workspace or
  project (at the repo root or one level down, many repos nest
  `App/App.xcodeproj`, skipping `.build`, `Pods`, `Carthage`, `node_modules`,
  `.claude` and a project's inner workspace), else finder; `xcode` (prewarm
  + xed); `finder` (`open dir`); anything else is a command on PATH given the
  dir, else `open -a <name> dir`. It prints each step (fetching, switching,
  fast-forwarding, opening) as dim lines; the app streams those into the
  session view while the button is busy.
- Commands: `ls` (default), `attach|a`, `open|o`, `new|n`, `projects|p`,
  `models`, `claude`, `shell`, `kill|stop`, `reap`, `hosts`, `keys`, `doctor`, `install|update`, `status`, `hook`.
  `models [host] [--json]` (`models_local` on the host) = what Claude Code
  there can start with: `{default, models: [{id, name, short_name,
  section}]}` plus `host` in the `--json` form. There is no `claude models`;
  the list is the freshest `surface: cc` (the CLI's) or `ccd` (desktop
  app's, absent on a Mac without it) file in
  `~/.claude/cache/model-catalog/` (`section` main = the picker, overflow =
  older versions) and `default` is `model` from `~/.claude/settings.local.json`
  else `settings.json`, its `[1m]` suffix dropped; both `""`/`[]` when
  unknown. `new ... --model <m>` (anywhere on the line, alias or id) appends
  `--model <m>` to the claude command; without it nothing is passed, so
  Claude Code's own default (including a `[1m]` variant) applies.
  `claude [--json] [--diff] [--kind k,...] [host...]` = how the Claude Code setup differs
  across the Macs, one row per item: `marketplace` (known_marketplaces.json),
  `plugin` (`enabledPlugins`, enabled/disabled), `mcp` (user-scope
  `mcpServers` in `~/.claude.json`), `setting` (settings.json top-level keys
  and `permissions.<k>`, minus `CLAUDE_SKIP_KEYS` and `*State|*Cache|*Timestamp`),
  `perm` (one row per `permissions.allow|deny|ask` rule, so separately grown
  allowlists are not clobbered), `file` (`~/.claude/CLAUDE.md`,
  `scripts/*`). Each host answers `claude --local` (`claude_snapshot_local`,
  `{version, items:[{kind,name,value,summary,digest[,exec]}]}`; mcp entries
  and the `env` setting leave only as a sha256 digest), gathered with
  `gather_into … claude_fetch`. There is no reference Mac: `claude copy
  <kind> <name> --from H --to H…|all` reads the full value there
  (`claude get --local`) and pipes it into `claude set --local` on each
  target (claude CLI for plugin/marketplace/mcp, never `-y`; jq with a
  one-time `.fleet-backup` for settings/perm; temp file + mv for files).
  `claude rm [-y]` runs `claude unset --local`. The table (and `--diff`)
  hides `perm` rows behind one count line, since rules outnumber everything
  and matter less; `--kind <k>[,<k>]` shows only those kinds (`--kind perm`
  for the rules) and also filters `--json`, which otherwise has every row.
  Fan-out doctor adds one informational "claude setup differs on N item(s)
  and M permission rule(s)" line.
  `keys add "<openssh line>"` (validated to one `<type> <base64> [comment]`
  line, `valid_pubkey`) appends to `~/.ssh/authorized_keys` here and on every
  reachable host via `keys_script` (umask 077, idempotent); `keys rm
  <comment>` drops every line with that comment everywhere; `--local` = this
  Mac only; bare `keys` lists `fleet-` tagged lines here.
  `shell [host] [dir]` is a login shell there, in `dir` when given (exec
  ssh / your shell, or a FLEET_TERM window via `open_term_window`; `shq`
  single-quotes the directory for the remote shell). `kill [-y] <host> <session>`
  ends a fleet session: `record_for` finds it, then `kill --local` on the
  host runs `tmux kill-session`, drops the state file, and forgets the
  registry entry when the session is in the repo itself (a worktree row
  stays, idle, until `reap`). Without `-y` it asks on a tty and refuses
  otherwise. Only sessions `fleet status` lists can be killed.
  `hosts info --json` carries `model` (the identifier, `Mac15,8`) and
  `model_name` (`system_profiler`'s "Model Name", `""` if unknown, absent
  from older remotes); the app picks the sidebar symbol from `model_name`.
  It also carries `lan_name` (Bonjour `<LocalHostName>.local`), `lan_ip`
  (IPv4 of the default-route interface) and `lan_link` (`ethernet`, `wifi`,
  or `""` when the default route is a VPN or unknown), from `lan_info`, all
  `""` when unknown and absent from older remotes: the app's Screen Sharing
  uses them.
  For a wrapper app: `projects [host] --json`, `hosts info [host...] --json`,
  and the picker-free `attach <host> <session>` / `open <host> <session>`
  (record_for). `ls` and `hosts info` take host names to ask one host only.
- `new` and `attach` end by attaching in the current terminal (`exec tmux
  new-session -A` locally, `exec ssh -t host ...` remotely; `switch-client`
  when already inside tmux). `FLEET_TERM=ghostty|terminal|iterm` (what the
  app uses, chosen in its Settings) first asks that app, via AppleScript, for
  a window whose title contains `<session> · <host> · fleet` (the host because
  two Macs can have the same session name; tmux `set-titles` is
  turned on per session for this) and brings it to the front
  (`raise_term_window`); otherwise it opens a new window running the attach
  (`open_term_window`: Ghostty 1.3+ `new surface configuration` with
  `command`, Terminal `do script`, iTerm `create window with default profile
  command`). iTerm is written to its published dictionary but not exercised
  here. Tests stub `osascript` (logs argv and the script, finds no window).
- `fleet new [host] [project] [task]`: a first argument that is in the host
  list is the host, otherwise the host is FLEET_SELF and the argument is the
  project pattern. It runs `fleet projects
  --local` on that host (folders under FLEET_ROOT, ranked CLAUDE.md/.claude
  first, then worktrees/container, plain, dir), picks with fzf, and runs
  `fleet new --local <project> [task]` there. No task = session `<project>-main`
  in the repo. With a task: plain project = another named session in the same
  repo (`<project>-<task>`, no worktree); converted project = a worktree.
  `status` emits one row per registered session for the primary repo (field
  `worktree: false`) and one per worktree (`worktree: true`).
  `fleet convert <project>` is local-only by design. `attach`, `open`, `new`, `reap` are
  only meaningful on the machine in front of the owner. Remotes run `status`,
  `doctor --local`, `new --local` (prints the worktree path) and
  `install --local`; the `--local` forms never fan out or open a terminal.
- Mode strings passed to `host_fetch`/`status_local`/`pick`/`record_for`: `""`
  = fleet's sessions (default), `--all` = everything. Older remotes ignore
  them and return everything; the client filters on `.managed` anyway.
- `reap` offers a worktree when its branch has nothing beyond origin's default
  branch (`refs/remotes/origin/HEAD`, else `origin/main`). That includes
  unstarted branches, so the prompt says "nothing beyond", dirty worktrees are
  skipped, `worktree remove` runs without `--force`, and the state file is
  removed with the worktree. No default branch means the project is skipped
  with a note. Squash/rebase merges are not detected.
- `doctor` is read-only apart from a `git fetch` of the checkout to report
  "behind origin". `install` mutates a machine's setup (clone or pull the
  checkout, link `~/bin/fleet`, seed config and hosts, brew deps; remotely:
  push hosts, then clone-or-pull and `install --local` there via gh).
  `hosts add|rm|push` write the hosts file here and on every reachable host.

## Load-bearing interfaces (treat changes as breaking)

- `fleet status [--all] [--json]`: this host only, never fans out. `--json` is
  the wire format remotes are asked for (`fleet status --json [--all]`, fast,
  git+jq only); without it, the same table as `ls`. Default = registered
  sessions' projects only; `--all` = every project.
- `fleet ls [--all] [--json] [host...]`: merged across FLEET_HOSTS, sorted by
  `-ts`; `--json` replaces the old `fleet json`. A dead, slow
  or garbage-emitting host contributes `[]`; a hung one is killed after
  FLEET_CMD_TIMEOUT. `host_status` first asks Tailscale whether the peer is
  online and skips it instantly if not (every `tailscale status` call goes
  through `tailscale_status`, cut off after FLEET_SSH_TIMEOUT: the CLI hangs
  for good while the Tailscale app restarts, and it once froze the Mac
  app's polling for 12 hours); it records the reason a host counts
  as down (`<host>.down`: ssh failed / fleet not installed / no answer) and
  `ls` prints those reasons.
- Record schema (all keys always present):

  | key      | type   | meaning                                                  |
  |----------|--------|----------------------------------------------------------|
  | host     | string | FLEET_SELF of the reporting machine                      |
  | project  | string | `<project>` directory name                               |
  | name     | string | worktree directory name (`main` for the primary)         |
  | path     | string | absolute worktree path on `host`                         |
  | branch   | string | branch without `refs/heads/`, or `(detached)`            |
  | upstream | string | e.g. `origin/agent/x`; `""` if none or pruned            |
  | state    | string | running, blocked, done, attached, idle                   |
  | subject  | string | last commit subject                                      |
  | session  | string | tmux session name (see session_name)                     |
  | dirty    | bool   | `git status --porcelain` non-empty                       |
  | ts       | int    | epoch of last commit (0 if none), not of agent activity  |
  | ahead    | int    | commits ahead of upstream (0 if no upstream)             |
  | behind   | int    | commits behind upstream (0 if no upstream)               |
  | managed  | bool   | started by `fleet new` (registry in FLEET_STATE/sessions) |
  | activity | int    | epoch of last hook event, else session start, else 0; `ls` shows this when > 0, else `ts` |
  | worktree | bool   | false for sessions in the primary repo, true for a git worktree row |
  | remote   | string | origin URL of the project's repo, `""` if none                |
  | claude_session | string | Remote Control id (`session_01…`) from `~/.claude/sessions/<pid>.json` matched on its `tmux` field, else the local id from the hook stdin; the app opens `claude://claude.ai/code/<id>` |
  | attached_from | [string] | machines with a tmux client on the session (tmux client tty -> `who` origin IP -> tailnet name; local terminal = the host itself) |
  | prompt   | string | UserPromptSubmit's text (`user_input`/`prompt`), clipped to 400: what the agent is working on; `""` if none |
  | note     | string | while blocked: for `idle_prompt` what the agent last said (the actual question; Claude Code's "waiting for your input" also fires while a background task runs, which hooks cannot see), else the Notification's `message`, else a phrase for its `notification_type`; `""` otherwise |
  | said     | string | Stop's `last_assistant_message`, clipped to 800; kept until the next running event; `""` otherwise. A tag-shaped prompt (`<task-notification>`, Claude Code talking to itself) is never recorded or emitted |
  | model    | string | status line `model.display_name`; `""` without a snapshot |
  | context_pct | int | status line `context_window.used_percentage`; -1 unknown |
  | cost_usd | number | status line `cost.total_cost_usd`; 0 unknown |
  | limit_5h, limit_7d | int | account `rate_limits` used %; -1 unknown (one account: the freshest across hosts is the answer) |
  | limit_5h_reset, limit_7d_reset | int | epoch the window resets; 0 unknown |
  | stats_ts | int | epoch of the status line snapshot; 0 = none |

- Session registry: `fleet new` writes `$FLEET_STATE/sessions/<session>`
  (line 1 the directory, line 2 the project). `ls` and `attach` show only registered rows;
  `ls --all` shows everything. A registered session in the repo itself (`worktree: false`)
  is forgotten as soon as its tmux session is gone; a worktree session stays
  until `reap` removes the worktree. Anything started outside `fleet new`,
  including `claude --worktree`, is not shown by default.
- `install_hooks` merges the five hook groups into `~/.claude/settings.json`
  with jq (idempotent: an event already running `fleet hook` is skipped; a
  `.fleet-backup` copy is made once). `hooks_missing` backs the doctor check.
- Hook state contract: Claude Code hooks call `$HOME/bin/fleet hook <state>`
  (UserPromptSubmit=running, PostToolUse=running, Notification with matcher
  `permission_prompt|idle_prompt`=blocked, Stop=done, SessionEnd=idle). It
  writes `$FLEET_STATE/<tmux session>.json` as `{"state","ts","session_id"}`;
  `session_id` is read from the hook's stdin JSON (kept from an earlier event
  if a later one lacks it) and is what claude.ai/code/<id> addresses.
  Session comes from `tmux display-message -p '#S'`; outside tmux it writes
  `detached.json`. Precedence: state file, else `attached` if a tmux session
  exists, else `idle`. The hook also keeps `prompt`, `note` and `said` from
  the event JSON (see the record schema; running clears note and said, done
  clears note; garbage stdin is treated as `{}`), reading it with a 1s
  timeout so it never blocks. It prints nothing and exits 0: a
  UserPromptSubmit hook's stdout becomes context and exit 2 blocks the prompt.
- Status line contract: `install_statusline` makes Claude Code's
  `statusLine.command` `$HOME/bin/fleet statusline -- '<previous command>'`
  (idempotent; `statusline_missing` backs the doctor check). Claude Code
  pipes a JSON snapshot after every assistant message; `cmd_statusline`
  writes `$FLEET_STATE/<tmux session>.stats.json` (ts, model, context_pct,
  context_size, cost_usd, limit_5h[_reset], limit_7d[_reset]; -1/0 when a
  field is absent) and then runs the previous command via `sh -c` with the
  same JSON, or prints "Opus · ctx 34% · 5h 23% · 7d 41%" when there was
  none. `status` merges the file into the record; `ls` prints a "usage:"
  line from the freshest snapshot and each row's note (blocked) or prompt.

## The apps (app/)

- One Xcode project, `app/Fleet.xcodeproj`, generated by XcodeGen from
  `app/project.yml` (edit the yml, run `xcodegen` in `app/`, commit both),
  with two targets: `Fleet` (macOS 14+, sources `app/Fleet/`) and
  `FleetMobile` (iOS 17+, sources `app/FleetMobile/`). `app/Shared/Models.swift`
  is compiled into both: the records mirroring the CLI's JSON (`Session`,
  `HostInfo` with `score` optional because `hosts --info-local` has none,
  `DoctorLine`, `UsageLimits`, the `Session` badge/dot/title helpers).
  Nothing platform-specific goes in Shared.
- Mac app: not sandboxed (spawns fleet); hardened runtime on;
  automatic signing. Build from the shell:
  `xcodebuild -project app/Fleet.xcodeproj -scheme Fleet -derivedDataPath app/.build build`. Single window,
  `NavigationSplitView`: sidebar = machines, each with its fleet sessions
  in a fixed project order, as one flat list of rows (`ContentView.rows`;
  `HostRow` draws its own fold chevron). Not a `DisclosureGroup` per
  machine: the outline view behind that strands the selected row's cell
  whenever rows around it come or go, a stale copy drawn over its
  neighbour, and neither an `.id` on the group nor disabling animations
  stops it; to reproduce, poll a stand-in whose session set changes with a
  session selected (`FLEET_SELECT=host/session`). Every row two lines
  (the second the note/prompt else the branch: the List caches row heights,
  and a row that grows later is drawn over its neighbour), with how long a
  blocked one has waited, searchable (⌘F, project/
  name/branch/session), with context menus (`SessionMenu`, `HostMenu`);
  detail = a session's action buttons and details, or a machine's info,
  sessions table and Doctor section; nothing selected = hosts table and
  "needs you" count. Selection lives in the model (`selected`) so the
  Session menu (⌘↩ attach, ⌘N new, End Session…), the menu bar item and a
  notification click can drive it; `reveal` reopens the window via
  `openMain`, captured from the window's `openWindow`.
- Beyond polling: a session that goes to blocked posts a notification
  (`noteNewlyBlocked`, diffing the previous refresh, nothing on the first),
  clicking it selects the session (`AppDelegate` is the UN delegate); the
  Dock badge and a `MenuBarExtra` (list of what is waiting, click to show)
  carry the count; with the menu bar item on, closing the window does not
  quit. Launch at login uses `SMAppService.mainApp`.
- What each agent is doing: the sidebar row's second line is the note
  (orange, blocked) else the prompt (`Session.doing`); the session screen
  shows the exchange: "You asked", a "Needs" row only for a request that is
  not the reply (a permission), and the reply, orange when it is what the
  agent waits on; then a git box (`GitStateBox`: uncommitted yes/no, and
  unpushed = ahead count, never pushed, or no remote; "behind" when > 0;
  state from the record only, decision 5) because that is the work no other
  Mac can see; then Model and a "Context window" gauge (no cost: the
  owner does not want it shown, `cost_usd` stays in the record); the machine table has Doing and Context columns; the Overview
  shows a Claude usage box (`UsageView`, from `FleetModel.usage`, the
  freshest snapshot with limits) and the menu bar menu repeats the numbers;
  notifications carry the note in their body.
- Claude Setup (sidebar item under Overview, `Item.claudeSetup`,
  `FLEET_SELECT=claude-setup`): `fleet claude --json` as a native `List`
  grouped by kind, each row saying in words what differs
  (`ClaudeItem.status`: "Only on studio", "Missing on mini", "medium ·
  high", "2 versions"; version letters, never digests), with an
  `.inspector` showing the selected item on each Mac that answered
  (`ClaudeItem.detail`) and visible buttons: Copy to Others (split button,
  only to Macs that lack it or differ; never `--to all`, which would
  include down Macs), Remove… (confirmed), Get from. A first version drew
  the CLI's matrix (dots, digests, cell menus); the owner found it ugly and
  un-Mac-like, so do not go back to that. Badge = differing items without
  permission rules, which sit in a collapsed section. Not polled: loaded
  after the first load, when shown, on ⌘R/toolbar Refresh (`refreshNow`)
  and after each action. Its sidebar row's `.tag` must come after
  `.badge`: a tag under `.badge` is invisible to the List and the row
  cannot be selected (clicking it did nothing). `fleet claude copy|rm -y` run one at a time,
  output streamed into the inspector; failures go to the banner (the FAIL
  line, else fleet's stderr). `ClaudeCell` never decodes `value`.
- Machine screen: Shell (`fleet shell <host>` with FLEET_TERM), Screen
  Sharing, New session, and a Doctor section that runs `fleet doctor <host>`;
  a session's terminal button (named after the chosen app) is a menu:
  Claude Code = attach, Open Shell = `fleet shell <host> <path>` (a fresh
  login shell in the session's directory)
  on demand (text parsed by `DoctorLine.parse`: ok/FAIL/fix/· lines, exit 1
  tolerated; the raw text is kept in `doctorText` for the Copy button) and an
  Update fleet button streaming `fleet install <host>`. The New-session sheet
  says so when the host lists no project at all (FLEET_ROOT wrong there).
  A session's End button (and menu items) confirm, then `fleet kill -y`.
  Settings > Hosts edits the list through `fleet hosts add|rm` (add with no
  name = every Mac on the tailnet) and shows the CLI's push results.
- Files in `app/Fleet/`, one screen or concern each: `FleetApp.swift` (entry,
  delegate, menu bar), `ContentView.swift` (window, sidebar rows and menus),
  `OverviewViews.swift`, `HostView.swift` (with the Doctor section),
  `ClaudeSetupView.swift` (the Claude Setup screen),
  `SessionView.swift` (with the New-session sheet), `SettingsViews.swift`,
  `Controls.swift` (buttons, styles, brand marks), `ScreenSharing.swift`
  (address and mode for the vnc:// URL), `Model.swift` (state,
  tree, polling, notifications) and `ModelActions.swift` (what the buttons
  run), `Fleet.swift` (prefs, terminals, the CLI bridge).
- It is a pure wrapper: `Fleet.swift` is the only file that touches the CLI
  (`FleetCLI.run` spawns `~/bin/fleet`, or `$FLEET_BIN`; `docs/demo-fleet`
  is a stand-in with made-up data for the README screenshots, and
  `$FLEET_SELECT` picks the item shown at launch), models mirror the
  JSON schemas verbatim, and every action is a fleet command, except Screen
  Sharing (machine screen, and a remote session's action row), which opens
  a `vnc://` URL in Screen Sharing.app (`ScreenSharing.swift`,
  `FleetModel.screenShare`): the host's `lan_name` and `lan_ip` from `hosts
  info` are probed on port 5900 (1.5s, `.local` only resolves on the same
  link; needs Local Network access, `NSLocalNetworkUsageDescription`,
  denied = "Local network prohibited" = tailnet name; the app delegate
  asks for it at launch with a throwaway TCP connect to a link-local
  address, `ScreenSharing.requestLocalNetworkAccess` (a Bonjour browse
  does not go through the check), because
  the first probe fails instantly while the prompt, or the re-check a
  rebuilt binary's new UUID triggers, is pending) and whichever answers is the address (the IP first: a `.local`
  name costs mDNS and Kerberos timeouts on link-local IPv6), else the
  tailnet name; the query is Screen Sharing's own .vncloc URL format and
  presets High Performance, `?quality=high&numVirtualDisplays=1` (only
  when the LAN answered and both Macs report `lan_link` ethernet and an
  Apple chip; a count of 0, or no count at all, silently gives Standard:
  Screen Sharing's log says "pro mode with no virtual displays"), else Standard,
  `?quality=full&numVirtualDisplays=0` (View > Full Quality) on the LAN and
  `quality=adaptive` over the tailnet, so its mode chooser does not come up. The Claude and GitHub buttons draw
  the real marks: SVG path data from Simple Icons (CC0) in `Brand`, drawn
  by `SVGShape` (lines and cubics only, no assets). Action buttons are icon over caption
  with a shared minimum width (`FilledStyle`) so the row never wraps; there
  is no Copy path button, the path is selectable in the details grid. A
  machine with no sessions gets a "New session…" row in the sidebar, which
  opens the same sheet as the machine screen's button: a type-to-filter
  field over a list of the host's projects (Enter starts when one is
  chosen), and Start keeps the sheet up with a status line through `fleet
  new` and the attach, closing on success and showing the error otherwise
  (`FleetModel.newSession` is async and reports stages). Settings (⌘,) is
  a two-tab window, keys in `Prefs`: General = terminal (`Terminal` enum,
  installed apps only, `terminal` default), refresh interval (`refreshInterval`,
  8s), show sessions fleet did not start (`showAllSessions` -> `ls --all`),
  fleet command path (`fleetBinary`, after `$FLEET_BIN`, needs relaunch);
  Buttons = which of Open/Claude/GitHub/Screen Sharing/Finder a session
  shows (`show*`, all on); the Open button is `fleet open`, whose target is
  FLEET_OPEN in the CLI config, so its caption is just "Open". The
  model re-arms its timer and refetches on `UserDefaults.didChangeNotification`.
  Attach sends `FLEET_TERM` from that terminal choice: raise the existing
  window or open a new one. `open` streams fleet's step lines into a busy row.
  The first load (`FleetModel.firstLoad`) reads the host list, shows every
  machine at once with a spinner (`loading`), asks each host on its own
  (`ls --json <host>`, `hosts info <host> --json`) and fills rows in as
  answers land, then sorts into `hosts info` order; later polls are the two
  fan-out calls. `docs/demo-fleet` answers per host with a short random delay
  so this can be seen.
  Polls carry a 60s deadline (`FleetCLI.pollTimeout`: the child is killed
  and the call throws, so one hung `fleet` cannot leave `refreshing` stuck).
  Polling errors clear themselves on the next good refresh (`lastError`);
  button errors stay in the bottom banner until dismissed (`actionError`).
- Polls every 8s (decision 4). No project management, no GitHub/ASC: keep it
  a fleet wrapper. Kept in this repo under `app/` only so it can move later;
  nothing in `fleet` may depend on it.

- iOS app (`FleetMobile`): the same fleet from a phone on the tailnet. It
  is a control machine that runs the CLI over ssh instead of locally:
  `SSHRunner` (Citadel, SwiftNIO SSH underneath; package in project.yml)
  keeps one connection per host and runs
  `export PATH=…; "$HOME/bin/fleet" <args>` with every argument
  single-quoted (`SSHRunner.shq`), `tolerate` returning stdout+stderr on a
  non-zero exit as the Mac app does. Per host it runs `hosts --info-local`
  and `status --json` itself in a task group (the Macs need no keys to each
  other); `projects --json`, `new --local <project> [name]` (session name by
  `Session.sessionName`, the CLI's rule) and `kill --local <session>` are
  run on the session's host. No attach, editor or screen sharing; "Open in
  Claude" is the `claude://` link. Polls every 10s while the overview is up.
  The overview is one line per session under its host (a blocked one adds
  its question); there is no "needs you" section, the prompt and reply live
  on the session screen. Settings > Hosts refreshes the list by asking the
  Macs it already knows (`refreshHosts`), or adds one by name; only
  onboarding asks for a Mac to type.
  Identity: one Ed25519 key made on the phone (`KeyStore`, Keychain,
  never exported); its OpenSSH line with comment `fleet-<device>` is what
  `fleet keys add "<line>"` authorizes on every Mac (`fleet keys rm
  fleet-<device>` revokes). Host keys are trust-on-first-use: the first
  connection accepts any key and pins the host's
  `/etc/ssh/ssh_host_ed25519_key.pub` line (`HostKeys`, UserDefaults);
  later connections require it and a mismatch is reported as such, with
  Settings > Forget pinned host keys for a reinstalled Mac. Onboarding asks
  for the username, shows the key, and learns the host list from one Mac
  (`fleet hosts`). Debug builds print the public key to the console so the
  simulator can be authorized with `fleet keys add … --local`; build with
  `xcodebuild -project app/Fleet.xcodeproj -scheme FleetMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath app/.build build`.
- Claude Code's own registry `~/.claude/sessions/<pid>.json` (one per running
  session: `sessionId`, `bridgeSessionId`, `tmux` target, `name`, `status`) is
  read for the Remote Control id only. Its `status` field would be another
  source of agent state; decision 3 says hooks, so it is not used for that.

## Internal conventions worth knowing

- Worktree enumeration parses `git worktree list --porcelain` with the shared
  `WORKTREE_AWK`. Git does not quote paths, so it takes the whole line after
  `worktree `, never `$2`. Bare entries are skipped.
- Any value embedded in a string a shell will parse (the `inner` attach
  command, `tmux send-keys` text, `run_on "fleet ... --local <x>"`, the
  status line chain) goes through `shq` (single-quoted for sh/zsh); a
  session or task name with a quote in it is legal and tested. Values passed
  as separate arguments need nothing.
- The hook's stdin loop is `read -r -t 1 line || [ -n "$line" ]`: the last
  line of a payload with no trailing newline would otherwise be dropped.
- Data moves between jq and bash as `@tsv` read with `IFS=$'\t'`. Tab is IFS
  whitespace, so an empty field shifts every later field: never emit an empty
  column except as the last one.
- Colours are set only when stdout is a tty; `status` output has none.
- Tests: `test/run.sh` (add `-v` for every assertion). Builds throwaway
  repos in a temp dir covering every layout and git edge, a fake remote
  "studio" reached through `test/shims/ssh` (same script, own HOME/config/
  root), and fake hosts dead/nofleet/slow; stand-ins for tmux, claude, fzf,
  open, xed in `test/shims/` (FLEET_PATH points there first; FAKE_TMUX_SESSIONS
  lists the sessions the fake tmux reports alive); `expect` drives reap. Runs
  under /bin/bash 3.2. Run it before every commit; it caught `cmd_hook` having
  been deleted by an earlier refactor. `install` is not covered (needs gh).
