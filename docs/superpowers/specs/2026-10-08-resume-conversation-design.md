# Resuming a conversation in a new session

Date: 2026-10-08. Status: implemented.

## Goal

When a Mac restarts, every fleet session on it ends: tmux and the agents
inside it do not survive, and fleet forgets a session in the repo itself as
soon as its tmux session is gone. The conversations are not lost, though:
Claude Code keeps each one on disk and `claude --resume <id>` picks it up.
Today getting one back means `fleet new`, then `/resume` inside the agent.

Success looks like: the New-session flow (Mac app sheet, and the CLI with a
flag) offers the project's recent conversations next to "New conversation",
and choosing one starts a fleet session that resumes it, under its old name,
in its old directory, with a fresh Remote Control link.

It is not tied to restarts: any past conversation in the project can be
picked up this way.

## Decisions made while designing

- **No "lost sessions" record.** A first idea was to keep the registry entry
  of a session that died with the Mac (registered before the last boot) and
  offer to restart it. Rejected for this: Claude Code's own history already
  holds everything needed, covers conversations fleet never started, and
  needs no change to when fleet forgets a session.
- **Part of `new`, not a separate command.** Resuming is starting a session
  with a different first step, so it rides on `fleet new` and the existing
  sheet. The flow stays: choose machine, choose project, then new or resume.
- **One sheet, no extra step in the app.** Choosing a project loads its
  conversations below the project list, with "New conversation" selected,
  so the common path is unchanged.
- **The CLI asks only when told to.** `fleet new … --resume` without an id
  opens an fzf of the conversations; without the flag the terminal flow is
  exactly what it is today.
- **Read-only use of Claude Code's files.** fleet reads transcripts and
  never writes, moves or copies them (decision 6 stands: a conversation
  resumes only on the Mac where it lives).
- **Mac app and CLI only.** Not on iOS for now.

## Where the history comes from

Claude Code keeps one transcript per conversation at
`~/.claude/projects/<encoded dir>/<id>.jsonl`, where the encoded dir is the
conversation's working directory with every character other than a letter
or digit turned into `-` (`/Users/x/Developer/Fleet` ->
`-Users-x-Developer-Fleet`). Entries fleet reads, by grep for the last
match of each type, never parsing the whole file:

| what            | from                                                    |
|-----------------|---------------------------------------------------------|
| id              | the file name without `.jsonl`                          |
| last active     | the file's mtime                                        |
| title           | last `{"type":"custom-title","customTitle":…}` line     |
| prompt          | last `{"type":"last-prompt","lastPrompt":…}` line       |

A fleet-started conversation's title is the `-n` label,
`<FLEET_SELF>-<session>`. When it has that shape the session part gives the
name (`<session>` minus the `session_name <project>` prefix and its `-`;
`main` for the bare one). Any other title (started outside fleet, or
`/rename`d in Claude Code) gives no name, and the title itself is shown.

Directories searched: the project's primary clone and each of its existing
worktrees (`WORKTREE_AWK`). A worktree that has been removed is not
searched, so its conversations are not offered (claude resumes per working
directory, and the directory is gone).

A conversation in a worktree is named after the worktree whatever its
title says, because `status` derives a worktree session's name from the
worktree's directory name.

Left out: conversations running now (their `sessionId` appears in a
`~/.claude/sessions/<pid>.json` whose pid is alive: a power cut leaves
those files behind, and that is exactly when resuming matters), and transcripts with no `last-prompt` line
(nothing was ever asked; Claude Code writes small stubs like that).

## CLI

### `fleet history [host] <project> [--json]`

`history --local <project>` on the host (`history_local`), the newest 20
conversations, newest first.

- `history --local <project> <id>`: just that conversation, whatever its
  age (the 20 cap does not apply), `[]` when there is none; `new --resume
  <id>` uses it to learn the name.
- `--json`: an array of `{id, dir, name, title, prompt, ts}`; `name` is
  `""` when the title is not fleet's shape; `prompt` clipped to 400 like the
  record's; `ts` the mtime epoch.
- Without: a table, `name-or-title  when  prompt`, padded with `pad`.
- No clone for the project: exit 1 with the usual "no clone for" message.
  No conversations: `[]` / nothing, exit 0.

### `fleet new [host] [project] [task] --resume [id]`

- `--resume <id>` (anywhere on the line, an id is a UUID) resumes that
  conversation; `--resume` with no id, interactive only, shows the
  project's history in fzf after the project is chosen and resumes the pick
  (`--no-attach` without an id is an error).
- An id that is not UUID-shaped is refused before anything else (it ends
  up in a path).
- The name: the task given on the line, else the conversation's own name,
  else `main`. A conversation in a worktree has the worktree's name; a
  different task given for it is refused ("that conversation is in the ui
  worktree: it resumes as <project>-ui"). The session-is-already-running refusal applies unchanged.
- Sent to the host as `new --local <project> [task] --resume <id>`. There
  `new_local` looks the id up among the history directories above, and:
  - not found: die "no conversation <id> for <project> on <host>";
  - running now (see above): die, it is open in another Claude Code;
  - found: the session starts in the transcript's directory, not the one
    the name would pick. In a converted project a conversation from the
    primary clone keeps running in the clone even under a non-main name;
    registered like any session in the repo itself.
- `start_session` takes the id and types
  `claude -n <FLEET_SELF>-<session> $FLEET_CLAUDE_ARGS [--model m] --resume <id>`.
  `--model` combines with it as today.
- Output as today (`<host>\t<session>\t<dir>` with `--no-attach`).

## Mac app

- `FleetCLI.history(host:project:)` runs `history <host> <project> --json`;
  `HistoryEntry` in `Shared/Models.swift` mirrors it. `FleetCLI.newSession`
  gains `resume: String?` (appends `--resume <id>`).
- `NewSessionSheet`: under the project list a "Conversation" list, loaded
  when the chosen project changes (cached per host/project for the sheet's
  life, a spinner meanwhile, a quiet "No earlier conversations" when
  empty). First row "New conversation" (selected by default and whenever
  the project changes), then one row per conversation: name (or title),
  how long ago, the prompt in secondary text, one line each. A fixed
  height, so the sheet does not change size as the list loads.
- Choosing a conversation fills the name field's placeholder with its name
  (the field itself stays as typed, so a typed name wins, as on the CLI) and
  turns Start into Resume. Enter and double-click work as now.
- A failed history load shows its error in place of the list; New
  conversation still works.

## Testing

`test/run.sh`, with transcripts written into the test HOMEs (local and the
fake `studio`):

- `history --json`: ordering by mtime, the 20 cap, name from a fleet title,
  `""` and the title for another, the prompt, the running one and the stub
  left out, a worktree's conversations included, a removed worktree's not.
- `history` table output, and on the fake remote.
- `new --resume <id> --no-attach`: the typed claude line carries
  `--resume <id>` (the tmux shim logs send-keys), the session's name from
  the title, a given task overriding it, the transcript's directory used in
  a converted project, an unknown id refused, a running name refused.
- `--resume` with no id under `--no-attach` refused.

The app per the usual check: built and run against the real fleet, the
sheet exercised on a project with history and one without.

## Not in scope

- Restarting sessions automatically after a reboot, or listing which ones
  were running (no daemon, nothing at login).
- iOS.
- `--fork-session`, `--continue`.
