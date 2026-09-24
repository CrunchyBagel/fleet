# Moving a session to another Mac

Date: 2026-09-24. Status: implemented.

## Goal

Move a fleet session from one Mac to another: the work continues on the
target with the same branch and a new agent that knows what the old one was
doing, and the session on the source ends. Typical use: an agent started on
the desktop, the owner leaves with the laptop.

Success looks like: one command (or one menu item in the Mac app) that
refuses when anything could be lost, offers only Macs that can take the
session, and ends with the owner attached to a new session on the target
whose first prompt is a handoff note from the previous agent.

## Decisions made while designing

- **Context travels as a handoff note, not the transcript.** Claude Code's
  transcript lives only on the Mac that ran it
  (`~/.claude/projects/<cwd>/<id>.jsonl`). Copying it would let
  `claude --resume` work, but it is an internal format and bends decision 6.
  Instead the source agent writes a short note, which becomes the target
  agent's first prompt. Nothing but git and ssh carries anything.
- **Only when the agent is not working.** States `done`, `attached` and
  `idle` may move; `running` and `blocked` are refused (answering the handoff
  request would dismiss a pending permission prompt). With no agent in the
  pane (`idle`, or `attached` at a shell) there is nobody to ask: the move
  goes ahead with a note that only says where the session came from and
  which branch it is on.
- **Committed and pushed, checked twice.** Before asking for the note and
  again after it arrives (the agent was told not to change files, but might).
- **The source ends only after the target is up.** Any failure before that
  leaves the source session untouched, apart from having been asked a
  question.
- **Mac app yes, iOS app no** (for now). A move is one Mac driving two
  others; the phone talks to each Mac separately. It could later run
  `fleet move` on the source Mac, but only where that Mac holds keys to the
  others.

## CLI

```
fleet move [-y] [--no-attach] <host> <session> [target]
fleet move --targets <host> <session> [--json]
fleet move --local <project> <name> <branch> <worktree>   # on the target, note on stdin
```

Runs on the machine in front of the owner, like `open`. `<host> <session>`
is the source, as for `attach`/`open`/`kill` (`record_for`).

### 1. Check the source

`record_for <host> <session> ""` gives the record. Refuse, naming the reason:

| condition                      | message                                         |
|--------------------------------|-------------------------------------------------|
| state `running`                | the agent is working; move it once it is done   |
| state `blocked`                | the agent is waiting on you; answer it first    |
| `dirty`                        | uncommitted changes on `<host>`; commit and push first |
| `upstream` empty               | `<branch>` was never pushed                     |
| `ahead > 0`                    | N commit(s) not pushed                          |
| branch `(detached)`            | detached HEAD, nothing to move to               |

`ahead` reflects the source's last fetch (status never fetches); commits
the agent pushed are counted from its own push, which updates the tracking
ref, so this is accurate for the agent's own work.

### 2. Choose the target: `move --targets`

Fans out `fleet projects --local` (as `new` does) to every reachable host
other than the source, plus one small per-host probe for the checks below.
A host qualifies when:

- it has a clone of the same repo: the project of that name whose origin
  has the same `repo_key`, else `project_for_remote` on that host (the one
  clone with that origin; two = no guess, host not offered);
- it has no tmux session with the target session name (`session_name
  <target project> <name>`);
- for a session in the repo itself (`worktree: false`) whose branch differs
  from the target clone's current branch: that clone has no uncommitted
  changes to tracked files and no live fleet session running in it (a
  checkout would change the branch under that agent).

The probe is `fleet move --check <project> <remote> <name> <branch>
<worktree>` on each candidate, fanned out with `gather_into`/`host_fetch`
(so offline, dead and hung hosts cost what they cost `ls`); it prints one
JSON object `{ok, project, why}`. `--targets` prints a table
(host, project, reason for the ones that do not qualify, dimmed), or with
`--json`:

```json
{"source": {"host": "...", "session": "..."},
 "movable": true, "why": "",
 "targets": [{"host": "laptop", "project": "MyApp", "ok": true,  "why": ""},
             {"host": "mini",   "project": "",      "ok": false, "why": "no clone of this repo"}]}
```

`movable`/`why` is the step 1 verdict, so the app gets both answers in one
call. A down host is listed with `ok: false` and its down reason.

Without a `target` argument, `move` runs the same and picks among the `ok`
hosts with fzf (`--select-1`). A named target that does not qualify is
refused with its reason.

### 3. Ask for the handoff note

Only when an agent is in the pane (`pane_command` is not a shell).
On the source, over `run_on`, `fleet move --ask <session>`:

- records `t0` (now), sends `C-u`, then types a fixed one-line prompt and
  Enter:
  > This session is being moved to another Mac. Do not change, commit or
  > push anything. Reply with a handoff note for the agent that continues
  > there: the goal, what is done, what is next, and any open questions or
  > decisions pending with the owner. Reply with the note only.
- polls `$FLEET_STATE/<session>.json` every second until `state == done`
  and `ts >= t0` and `said` is non-empty, up to `FLEET_HANDOFF_TIMEOUT`
  (new config key, default 180);
- prints `said` on stdout and exits 0, or exits 1 with "no handoff after
  Ns; the session is left as it was" on timeout, or on `blocked` (the agent
  asked for permission after all).

`said` is clipped to 800 characters and flattened to one line by the hook,
which is too little for a note. While a
`$FLEET_STATE/<session>.handoff-pending` marker exists (written by `--ask`,
removed when it finishes), the hook's `done` also stores the full
`last_assistant_message` as `handoff` in the state file: newlines kept,
other control characters dropped, capped at 20000 characters. `--ask` reads
`handoff`. The record never carries it (status picks fields by name), and
`said` is unchanged.

Then step 1's checks run again on a fresh `record_for`; a change (a new
commit, dirty files) aborts with the reason, the session left as it is.

### 4. Prepare the target and start the session

The note, wrapped in a header, goes to the target on stdin:

```
This session was moved from <source host> to <target host> by fleet.
Branch <branch>, last commit: <subject>. The previous agent's handoff:

<note>
```

(or the header alone when there was no agent). On the target:
`fleet move --local <project> <name> <branch> <worktree>`:

1. `prepare_checkout <project> <name> <branch> <worktree>`: the checkout
   half of today's `cmd_open`, moved into a function both use: fetch,
   worktree prune, then for a repo session switch the clone to the branch
   (refusing with uncommitted tracked changes) and fast-forward; for a
   worktree session `enable_worktrees`, create or reuse the worktree, and
   fast-forward. Unlike `open`, a missing `origin/<branch>` or a diverged
   local branch is an error here, not a warning: the target must end up at
   exactly what the source pushed. Prints its dim step lines as `open` does.
2. Writes stdin to `$FLEET_STATE/<session>.handoff`.
3. `start_session <session> <dir> <project> <model> <handoff file>`: the
   tail of `new_local` (tmux session, claude typed in, brand, register),
   moved into a function both use. With a file, the typed claude line ends
   with `"$(cat <f>; rm -f <f>)"` (path through `shq`), so the note is
   claude's first prompt, never passes through `send-keys` as text, and is
   removed as soon as it is read. The session name is `session_name
   <target project> <name>`; a session of that name already running there
   is refused.
4. Prints the directory, as `new --local` does.

The session keeps the source's model only if the owner chose one; `move`
passes no `--model` (the target Mac's default applies). `--model` on
`move` is passed through to `new_local`.

### 5. End the source

`run_on <source> "fleet kill --local <session>"` (existing `kill_local`:
`/exit`, kill the tmux session, forget a repo session; a worktree on the
source stays until `reap`). A failure here is reported but the move counts
as done: the target is up.

### 6. Attach

`launch_term <target> <session> <dir>`, as `new` ends. `--no-attach`
prints `host \t session \t dir` instead (the app's form, same as `new`).

Without `-y`, before step 3: on a tty ask "move <session> from <host> to
<target>? the agent writes a handoff note, this session ends, a new one
starts there. [y/N]"; not a tty = refuse, as `kill` does.

## Mac app

- `Move` in the session's action row (`SessionView`), a `Menu` whose items
  are the targets; "Move To" submenu in `SessionMenu`. Targets load when
  the session screen shows, and again when the record's movability
  changes (`fleet move --targets <host> <session> --json`); `ok: false`
  targets are shown disabled with their reason. The sidebar's context menu
  uses the targets already loaded, else offers "Move To…", which selects
  the session so its screen loads them.
- The button itself is disabled with a help text when the record already
  says it cannot move (`state`, `dirty`, `upstream`, `ahead`: the same
  rules as step 1, in `Session` in Shared/Models.swift), so no call is made
  for those.
- Choosing a target confirms ("Move to laptop? The agent writes a handoff
  note, this session ends, and a new one starts there with the note."),
  then `FleetModel.moveSession` (ModelActions.swift) runs `fleet move -y
  --no-attach <host> <session> <target>` with a timeout of
  `FLEET_HANDOFF_TIMEOUT` plus a margin, streaming step lines into a busy
  row as `open` does. On success: refresh, select the new session, attach
  with FLEET_TERM. On failure: the banner (the `fleet:` line, else stderr).
- `FleetCLI` stays the only thing that runs fleet. A `MoveTargets` model
  mirroring the `--targets --json` shape goes in Shared/Models.swift.

`docs/demo-fleet` answers `move --targets … --json` and `move -y
--no-attach …` with made-up data, so the button can be tried without Macs.

## Docs

- CLAUDE.md: `move` in the command list and a paragraph under Layout and
  conventions (the flow above, condensed); `move --targets --json` under
  load-bearing interfaces; the Move button under the app; the new
  `FLEET_HANDOFF_TIMEOUT` key in the config list.
- README: a short "Moving a session" section.
- The embedded example config (`write_example_config`) gets the new key.
- SECURITY.md: the handoff note is agent-written text passed to the target
  over ssh stdin and to claude as a quoted argument (`"$(cat …)"`, never
  evaluated as shell); nothing new is executed.

## Tests (`test/run.sh`, under /bin/bash 3.2)

Using the fake remote `studio` and the fake tmux (which logs `send-keys`).
The fake tmux gains `FAKE_TMUX_ANSWER=<file>`: on a `send-keys` containing
"handoff note", it writes a `done` state file with that file's text as
`said` and a current `ts`, standing in for the agent.

- refusals: dirty, never pushed, ahead, running, blocked, detached
- `--targets`: a clone under a different directory name with the same
  origin qualifies; a host without the repo, one whose clone is dirty and
  on another branch, one with a live session in the clone on another
  branch, and one with a session of the same name do not; a dead host is
  listed as not ok with its reason; `--json` shape
- happy path, repo session: target clone switched to the branch and
  fast-forwarded; the claude line typed on the target ends with the
  `$(cat …; rm -f …)` of a file containing the header and the note; the
  source's `kill --local` runs after the target's `new --local`
- happy path, worktree session to a plain target clone: converted,
  worktree created at the branch
- no agent in the pane: no question asked, header-only note
- handoff timeout: exit 1, the source not killed, the target untouched
- the agent commits during the handoff: aborted after the note
- a note with quotes, `$` and backticks arrives verbatim
- `open` behaves as before after the `prepare_checkout` extraction (the
  existing open tests)

## Out of scope

- The iOS app.
- Carrying the transcript (`--resume`).
- Moving a session that is working, or queueing a move until it is done.
- Moving several sessions at once.
