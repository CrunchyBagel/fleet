# Resume a Conversation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `fleet new … --resume [id]` and the Mac app's New-session sheet start a fleet session that resumes one of the project's earlier Claude Code conversations.

**Architecture:** A read-only `history_local` lists the transcripts Claude Code keeps under `~/.claude/projects/<dir key>/` for the project's clone and worktrees; `fleet history` exposes it per host. `new --local … --resume <id>` finds the transcript's directory and has `start_session` type `claude … --resume <id>`. The app loads `fleet history <host> <project> --json` into a second list in the sheet.

**Tech Stack:** bash 3.2 + jq (fleet), SwiftUI macOS 14 (app), `test/run.sh`.

**Spec:** `docs/superpowers/specs/2026-10-08-resume-conversation-design.md`

## Global Constraints

- bash 3.2: no `mapfile`, `declare -A`, `${var,,}`, `&>`, `|&`, `printf -v`, `readlink -f`; no `case` inside `$(...)` inside double quotes. Run new code paths under `/bin/bash`.
- `set -euo pipefail` is on: every `grep` that may match nothing inside a pipeline needs `|| true`.
- shellcheck clean; every suppression carries a reason on the same line.
- Values embedded in shell-parsed strings (`run_on "fleet … $(shq x)"`, `tmux send-keys` text) go through `shq`.
- jq/bash TSV: never emit an empty column except the last.
- fleet never writes, moves or copies Claude Code's files.
- Cap: 20 conversations (`HISTORY_MAX=20`), prompt clipped to 400.
- Run the suite with `FLEET_TERM` and `FLEET_ORIG_PATH` unset: `env -u FLEET_TERM -u FLEET_ORIG_PATH test/run.sh`.
- The app is a pure wrapper: only `Fleet.swift` spawns fleet; models in `Shared/Models.swift` mirror the JSON verbatim.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_013yUiQCTEynm7mWRJF87kXG
  ```

## Review Focus

1. **Stale `~/.claude/sessions/<pid>.json` after a power cut**: it must not hide that conversation (pid dead = not running). Test in Task 1.
2. **A transcript with a malformed line, or with `last-prompt` lines that only carry `leafUuid`**: it must still give its title and prompt. Test in Task 1.
3. **Symlinked paths** (git prints `/private/var/…` for a `/var/…` root): the main clone's conversations must be found under the path fleet registered the session with, not only the resolved one. Test in Task 1 (the main-clone transcript is written under `$T`, the worktree one under `$TR`).
4. **An id like `../../x` passed to `--resume`**: refused before it reaches a path. Test in Task 2.
5. **A conversation older than the newest 20, resumed by id**: still found, and still gets its worktree name. Test in Task 2.

---

### Task 1: `fleet history`

**Files:**
- Modify: `fleet` (new helpers after `claude_session_id`, around line 220; `cmd_history` after `cmd_models`, around line 1480; usage around line 3300; dispatch around line 3350)
- Test: `test/run.sh` (new section before the final summary)
- Modify: `CLAUDE.md` (Commands line and a short paragraph)

**Interfaces:**
- Produces:
  - `claude_dir_key <dir>`: prints the dir with every non `[A-Za-z0-9]` char turned into `-`.
  - `history_dirs <primary clone>`: the clone (as given) then every existing worktree path from `git worktree list` (one per line, may repeat the clone in resolved form).
  - `claude_live_ids`: the `sessionId` of every `~/.claude/sessions/<pid>.json` whose pid is alive, one per line.
  - `history_local <project> [id]`: JSON array `[{id, dir, name, title, prompt, ts}]`, newest first, max 20 (no cap and only that id when given). Dies "no clone for …" when the project has no clone.
  - `fleet history [host] <project> [--json]`; `fleet history --local <project> [id]`.

- [ ] **Step 1: Write the failing tests**

Append before the final `printf '\n%d passed…'` in `test/run.sh`:

```bash
# ---------------------------------------------------------------- history

section "history"
# conv <dir> <id> <touch -t stamp> <title> <prompt>: a Claude Code transcript
# for a conversation that ran in <dir>, as ~/.claude/projects keeps it. The
# leafUuid-only last-prompt line after the real one is what Claude Code writes too.
conv() {
  local d; d="$T/home/.claude/projects/$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$d"
  { printf '{"type":"user","message":{"content":"hi"}}\n'
    [ -z "$4" ] || jq -nc --arg t "$4" --arg id "$2" '{type: "custom-title", customTitle: $t, sessionId: $id}'
    [ -z "$5" ] || jq -nc --arg p "$5" --arg id "$2" '{type: "last-prompt", lastPrompt: $p, sessionId: $id}'
    printf '{"type":"last-prompt","leafUuid":"x","sessionId":"%s"}\n' "$2"
  } > "$d/$2.jsonl"
  touch -t "$3" "$d/$2.jsonl"
}
U1=11111111-1111-1111-1111-111111111111; U2=22222222-2222-2222-2222-222222222222
U3=33333333-3333-3333-3333-333333333333; U4=44444444-4444-4444-4444-444444444444
U5=55555555-5555-5555-5555-555555555555; U6=66666666-6666-6666-6666-666666666666
U7=77777777-7777-7777-7777-777777777777; U8=88888888-8888-8888-8888-888888888888
git clone -q "$T/origins/alpha.git" "$T/root/hist"
conv "$T/root/hist" "$U1" 202609010900 "laptop-hist-main" "first thing"
conv "$T/root/hist" "$U2" 202609030900 "laptop-hist-review" "review the PR"
conv "$T/root/hist" "$U3" 202609020900 "Fix login" "$(printf 'x%.0s' $(seq 1 500))"
conv "$T/root/hist" "$U4" 202609040900 "laptop-hist-stub" ""                       # nothing ever asked
conv "$T/root/hist" "$U5" 202609050900 "laptop-hist-live" "still running"
conv "$T/root/hist" "$U6" 202609060900 "laptop-hist-crashed" "was running at the power cut"
printf 'not json\n' >> "$T/home/.claude/projects/$(printf '%s' "$T/root/hist" | sed 's/[^A-Za-z0-9]/-/g')/$U2.jsonl"
mkdir -p "$T/home/.claude/sessions"
printf '{"sessionId":"%s"}\n' "$U5" > "$T/home/.claude/sessions/$$.json"          # this shell: alive
sh -c 'exit 0' & DEADPID=$!; wait "$DEADPID"
printf '{"sessionId":"%s"}\n' "$U6" > "$T/home/.claude/sessions/$DEADPID.json"    # left behind
H=$(run history --local hist)
assert_eq "history: newest first, stub and running ones left out" \
  "$(printf '%s' "$H" | jq -r 'map(.id[0:1]) | join(" ")')" "6 2 3 1"
assert_eq "  ...a fleet title gives the name"      "$(printf '%s' "$H" | jq -r --arg u "$U2" '.[] | select(.id == $u) | "\(.name)|\(.title)|\(.prompt)"')" "review|laptop-hist-review|review the PR"
assert_eq "  ...the bare one is main"              "$(printf '%s' "$H" | jq -r --arg u "$U1" '.[] | select(.id == $u) | .name')" "main"
assert_eq "  ...another title gives no name"       "$(printf '%s' "$H" | jq -r --arg u "$U3" '.[] | select(.id == $u) | "\(.name)|\(.title)"')" "|Fix login"
assert_eq "  ...prompt clipped to 400"             "$(printf '%s' "$H" | jq -r --arg u "$U3" '.[] | select(.id == $u) | .prompt | length')" "400"
assert_eq "  ...dir and ts"                        "$(printf '%s' "$H" | jq -r --arg u "$U1" '.[] | select(.id == $u) | "\(.dir) \(.ts > 0)"')" "$T/root/hist true"
assert_eq "history --local <id>: just that one"    "$(run history --local hist "$U1" | jq -r 'map(.id) | join(" ")')" "$U1"
assert_eq "  ...[] for an unknown id"              "$(run history --local hist "$U7")" "[]"
assert_contains "history of a project with no clone fails" "$(run history --local nosuch 2>&1)" "no clone for nosuch"
assert_eq "  ...exit 1"                            "$(run history --local nosuch >/dev/null 2>&1; echo $?)" "1"
assert_eq "history of a project with none is []"   "$(run history --local plainB)" "[]"
# worktrees: a converted project, one live worktree and one removed
git clone -q "$T/origins/alpha.git" "$T/root/histW"; run convert histW >/dev/null
run new --local histW ui >/dev/null; run new --local histW old >/dev/null
conv "$TR/root/histW/.claude/worktrees/ui"  "$U7" 202609070900 "laptop-histW-whatever" "worktree work"
conv "$TR/root/histW/.claude/worktrees/old" "$U8" 202609080900 "laptop-histW-old" "gone soon"
git -C "$T/root/histW" worktree remove "$T/root/histW/.claude/worktrees/old"
HW=$(run history --local histW)
assert_eq "history: a worktree's conversation is named after the worktree" \
  "$(printf '%s' "$HW" | jq -r --arg u "$U7" '.[] | select(.id == $u) | "\(.name) \(.dir)"')" "ui $TR/root/histW/.claude/worktrees/ui"
assert_eq "  ...a removed worktree's is not offered" "$(printf '%s' "$HW" | jq -r --arg u "$U8" '[.[] | select(.id == $u)] | length')" "0"
# the cap
git clone -q "$T/origins/alpha.git" "$T/root/histN"
for i in $(seq 10 31); do conv "$T/root/histN" "aaaaaaaa-0000-0000-0000-0000000000$i" "2026090100$i" "laptop-histN-n$i" "p$i"; done
assert_eq "history: at most 20, the newest"        "$(run history --local histN | jq -r 'length, .[0].name, .[19].name' | tr '\n' ' ')" "20 n31 n12 "
# the command
assert_contains "history table: name, when and id" "$(run history hist)" "review"
assert_contains "  ...the id to resume with"       "$(run history hist)" "$U2"
assert_contains "  ...a title when there is no name" "$(run history hist)" "Fix login"
assert_eq "history --json is the array"            "$(run history hist --json | jq -r 'length')" "4"
RK="$RH/.claude/projects/$(printf '%s' "$T/rootR/plainR" | sed 's/[^A-Za-z0-9]/-/g')"; mkdir -p "$RK"
jq -nc '{type: "last-prompt", lastPrompt: "on studio"}' > "$RK/$U1.jsonl"
assert_eq "history on another host"                "$(renv FLEET_HOSTS="laptop studio" -- history studio plainR --json | jq -r '.[0].prompt')" "on studio"
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `env -u FLEET_TERM -u FLEET_ORIG_PATH test/run.sh 2>&1 | tail -30`
Expected: FAILs in the history section (`unknown command "history"`).

- [ ] **Step 3: Implement the helpers and `history_local`**

In `fleet`, after `claude_session_id` (ends `return 0` / `}` around line 219):

```bash
# Claude Code's transcripts: ~/.claude/projects/<key>/<id>.jsonl, one per
# conversation, <key> being the working directory with every character but a
# letter or digit turned into "-". fleet only reads them, for `history` and
# `new --resume`; a conversation resumes only on the Mac where it lives.
claude_dir_key() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
# Where a project's conversations can be: its primary clone as fleet names it
# (sessions start there, so that is the cwd Claude saw) and every worktree
# that still exists, as git prints them (the clone again, resolved).
history_dirs() {   # $1 primary clone
  local d
  printf '%s\n' "$1"
  git -C "$1" worktree list --porcelain 2>/dev/null | awk "$WORKTREE_AWK" | cut -f1 \
    | while IFS= read -r d; do if [ -d "$d" ]; then printf '%s\n' "$d"; fi; done
  return 0
}
# Conversations open in a running Claude Code: ~/.claude/sessions/<pid>.json
# with a live pid. A crash or a power cut leaves the file behind, and that
# is when resuming matters, so the pid decides.
claude_live_ids() {
  local f pid
  for f in "$HOME"/.claude/sessions/*.json; do
    [ -f "$f" ] || continue
    pid=$(basename "$f" .json)
    kill -0 "$pid" 2>/dev/null || continue
    jq -r '.sessionId // empty' "$f" 2>/dev/null || true
  done
  return 0
}
HISTORY_MAX=20
# history_local <project> [id]: the project's conversations Claude Code can
# resume, newest first, at most HISTORY_MAX (with an id: just that one, any
# age), as [{id, dir, name, title, prompt, ts}]. name is the fleet session
# part of a "<FLEET_SELF>-<session>" title (the -n label fleet gives), the
# worktree's name for a conversation in a worktree, else "". Left out: the
# running ones, and stubs with no prompt.
history_local() {
  local project="$1" want="${2:-}" main mainp pre live d f ts id wt n=0
  main=$(project_repo "$project") || die "no clone for $project under $FLEET_ROOT"
  mainp=$(cd "$main" && pwd -P)
  pre="$FLEET_SELF-$(session_name "$project" x)"; pre=${pre%x}
  live=" $(claude_live_ids | tr '\n' ' ') "
  history_dirs "$main" | awk '!seen[$0]++' | while IFS= read -r d; do
      for f in "$HOME/.claude/projects/$(claude_dir_key "$d")"/*.jsonl; do
        [ -f "$f" ] || continue
        [ -z "$want" ] || [ "$(basename "$f" .jsonl)" = "$want" ] || continue
        printf '%s\t%s\t%s\n' "$(stat -f %m "$f")" "$d" "$f"
      done
    done | sort -rn | while IFS=$'\t' read -r ts d f; do
      [ "$n" -lt "$HISTORY_MAX" ] || break
      id=$(basename "$f" .jsonl)
      case "$live" in *" $id "*) continue ;; esac
      wt=""; [ "$(cd "$d" && pwd -P)" = "$mainp" ] || wt=$(basename "$d")
      # Only rows that came out count towards the cap (a stub prints nothing).
      if { grep -h -e '"custom-title"' -e '"lastPrompt"' "$f" 2>/dev/null || true; } \
        | jq -Rnc --arg id "$id" --arg dir "$d" --arg wt "$wt" --arg pre "$pre" --argjson ts "$ts" '
            [inputs | fromjson? // empty | objects] as $l
            | ([$l[] | select(.type == "custom-title") | .customTitle // empty | strings] | last // "") as $t
            | ([$l[] | select(.type == "last-prompt") | .lastPrompt // empty | strings] | last // "") as $p
            | select($p != "")
            | {id: $id, dir: $dir,
               name: (if $wt != "" then $wt elif ($t | startswith($pre)) and ($t | length) > ($pre | length) then $t[($pre | length):] else "" end),
               title: $t, prompt: $p[:400], ts: $ts}' \
        | grep .; then n=$((n + 1)); fi
    done | jq -sc 'unique_by(.id) | sort_by(-.ts)'
}
```

- [ ] **Step 4: Implement `cmd_history`, usage and dispatch**

After `cmd_models`:

```bash
# fleet history [host] <project> [--json]: the conversations Claude Code there
# has for the project, which `fleet new … --resume <id>` picks up again.
cmd_history() {
  if [ "${1:-}" = --local ]; then history_local "${2:-}" "${3:-}"; return 0; fi
  local host="$FLEET_SELF" json=0 args=() a out label ts id p
  for a in "$@"; do case "$a" in --json) json=1 ;; *) args+=("$a") ;; esac; done
  set -- ${args[@]+"${args[@]}"}
  if [ $# -ge 2 ]; then host="$1"; shift; fi
  [ -n "${1:-}" ] || die "usage: fleet history [host] <project> [--json]"
  out=$(run_on "$host" "fleet history --local $(shq "$1")") || die "could not list conversations for $1 on $host (fleet doctor $host; is fleet up to date there?)"
  if [ "$json" = 1 ]; then printf '%s\n' "$out"; return 0; fi
  [ "$(printf '%s' "$out" | jq 'length')" -gt 0 ] || { printf 'no conversations for %s on %s\n' "$1" "$host"; return 0; }
  printf '%s\n' "$out" | jq -r '.[] | [(if .name != "" then .name elif .title != "" then .title else "-" end), (.ts | tostring), .id, .prompt] | @tsv' \
    | while IFS=$'\t' read -r label ts id p; do
        printf '%s  %s  %s  %s%s%s\n' "$(pad "$label" 20)" "$(pad "$(reltime "$ts")" 9)" "$id" "$DIM" "${p:0:60}" "$RESET"
      done
}
```

In `usage`, after the `fleet models` line:

```
  fleet history [host] <project> [--json]
                                  that project's earlier Claude Code conversations there,
                                  to pick up with fleet new … --resume <id>
```

In the dispatch, after `models)`: `  history)  cmd_history "$@" ;;`

- [ ] **Step 5: Run the tests**

Run: `env -u FLEET_TERM -u FLEET_ORIG_PATH test/run.sh 2>&1 | tail -15` and `shellcheck fleet`
Expected: all pass; shellcheck prints nothing.

- [ ] **Step 6: Document in CLAUDE.md**

In the Commands list add `history` after `models`, and after the `models` paragraph add:

```
  `history [host] <project> [--json]` (`history_local` there, `--local
  <project> [id]`) = the conversations `fleet new --resume` can pick up:
  Claude Code's transcripts `~/.claude/projects/<dir key>/<id>.jsonl`
  (`claude_dir_key`: non-alphanumerics to `-`) for the clone and each
  existing worktree, newest 20, `[{id, dir, name, title, prompt, ts}]`;
  name from a `<FLEET_SELF>-<session>` custom-title, a worktree's own
  name in a worktree, else `""`; the last `lastPrompt`; running ones
  (`claude_live_ids`: a `~/.claude/sessions/<pid>.json` with a live pid,
  since a power cut leaves the files) and stubs left out. Read-only.
```

- [ ] **Step 7: Commit**

```bash
git add fleet test/run.sh CLAUDE.md
git commit -m "fleet history: a project's Claude Code conversations, to resume"
```

---

### Task 2: `fleet new … --resume [id]`

**Files:**
- Modify: `fleet` (`start_session` ~2023, `new_local` ~2050, `cmd_new` ~2092, usage)
- Test: `test/run.sh` (append to the history section)
- Modify: `CLAUDE.md` (the `fleet new` paragraph)

**Interfaces:**
- Consumes: `history_local <project> [id]`, `history_dirs`, `claude_dir_key`, `claude_live_ids` (Task 1).
- Produces:
  - `is_uuid <s>`: 0 when 8-4-4-4-12 hex.
  - `start_session <session> <dir> <project> [model] [first-prompt file] [resume id]`: 6th argument appends ` --resume '<id>'` after `--model`.
  - `new_local <project> [task] [model] [resume id]`.
  - `fleet new [host] [project] [task] --resume [id]`, `fleet new --local <project> [task] --resume <id>`; output unchanged (`<host>\t<session>\t<dir>` with `--no-attach`).

- [ ] **Step 1: Write the failing tests**

Append to the history section:

```bash
: > "$SHIM_LOG"
assert_eq "new --resume: the conversation's name, in its directory" \
  "$(run new laptop hist --resume "$U2" --no-attach)" "$(printf 'laptop\thist-review\t%s' "$T/root/hist")"
assert_contains "  ...claude is told to resume it" "$(cat "$SHIM_LOG")" "--permission-mode auto --remote-control --resume '$U2'"
assert_eq "  ...and it is registered there"   "$(sed -n 1p "$T/state/sessions/hist-review")" "$T/root/hist"
assert_eq "new --resume with a name: that name" "$(run new laptop hist again --resume "$U2" --no-attach | cut -f2)" "hist-again"
assert_eq "new --resume of an untitled one: main" "$(run new laptop hist --resume "$U3" --no-attach | cut -f2)" "hist-main"
: > "$SHIM_LOG"
run new laptop hist --model claude-sonnet-5 --resume "$U1" --no-attach >/dev/null
assert_contains "--model and --resume together"  "$(cat "$SHIM_LOG")" "--model 'claude-sonnet-5' --resume '$U1'"
assert_contains "new --resume refuses a running name" \
  "$(renv "FAKE_TMUX_SESSIONS=plainR-main hist-review" -- new laptop hist --resume "$U2" --no-attach 2>&1)" "hist-review is already running"
assert_contains "new --resume refuses an unknown id" "$(run new --local hist --resume 99999999-9999-9999-9999-999999999999 2>&1)" "no conversation 99999999-9999-9999-9999-999999999999 for hist"
assert_contains "new --resume refuses a non-id"  "$(run new --local hist --resume=../../etc 2>&1)" "not a conversation id"
assert_contains "new --resume refuses a running conversation" "$(run new --local hist --resume "$U5" 2>&1)" "open in a running Claude Code"
assert_contains "new --local --resume needs an id" "$(run new --local hist --resume 2>&1)" "needs a conversation id"
assert_contains "new --no-attach --resume needs an id" "$(run new laptop hist --resume --no-attach 2>&1)" "needs a conversation id"
# worktrees
assert_eq "new --resume of a worktree conversation: the worktree's session" \
  "$(run new laptop histW --resume "$U7" --no-attach)" "$(printf 'laptop\thistW-ui\t%s' "$TR/root/histW/.claude/worktrees/ui")"
assert_contains "  ...another name for it is refused" "$(run new laptop histW other --resume "$U7" --no-attach 2>&1)" "in the ui worktree"
conv "$T/root/histW" "$U4" 202609090900 "laptop-histW-triage" "in the clone"
assert_eq "new --resume of a clone conversation in a converted project stays in the clone" \
  "$(run new laptop histW --resume "$U4" --no-attach)" "$(printf 'laptop\thistW-triage\t%s' "$T/root/histW")"
assert_false "  ...no worktree made for it"      test -d "$T/root/histW/.claude/worktrees/triage"
# older than the newest 20, by id
assert_eq "new --resume finds one beyond the 20" "$(run new laptop histN --resume aaaaaaaa-0000-0000-0000-000000000010 --no-attach | cut -f2)" "histN-n10"
# the picker: fzf (the shim) takes the first row, the newest
: > "$SHIM_LOG"
run new laptop '^hist ' --resume >/dev/null 2>&1
assert_contains "new --resume with no id picks from the history" "$(cat "$SHIM_LOG")" "--resume '$U6'"
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `env -u FLEET_TERM -u FLEET_ORIG_PATH test/run.sh 2>&1 | tail -30`
Expected: the new assertions FAIL (`--resume` is taken as a task name or a project pattern).

- [ ] **Step 3: `is_uuid` and `start_session`**

Next to `claude_dir_key`:

```bash
# A Claude Code conversation id. --resume takes nothing else: it ends up in a path.
is_uuid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
```

`start_session`: header comment gains `[resume id]`, and:

```bash
start_session() {
  local session="$1" dir="$2" project="$3" model="${4:-}" first="${5:-}" resume="${6:-}" prompt=""
```

and the send-keys line becomes:

```bash
    tmux send-keys -t "$session" "claude -n $(shq "$FLEET_SELF-$session") $FLEET_CLAUDE_ARGS${model:+ --model $(shq "$model")}${resume:+ --resume $(shq "$resume")}$prompt" Enter
```

- [ ] **Step 4: `new_local` with a resume id**

Replace the start of `new_local` up to the running check, and guard the worktree block:

```bash
#   new_local <project> [task] [model] <id>   resume conversation <id> where
#                                it ran; in a worktree under the worktree's name
new_local() {
  local project="$1" task="${2:-}" model="${3:-}" resume="${4:-}" main layout dir="" branch base session wt
  need git; need tmux; need claude
  main=$(project_repo "$project") || die "no clone for $project under $FLEET_ROOT"
  layout=$(project_layout "$project")
  if [ -n "$resume" ]; then
    is_uuid "$resume" || die "$resume is not a conversation id   (fleet history $FLEET_SELF $project)"
    case " $(claude_live_ids | tr '\n' ' ') " in
      *" $resume "*) die "conversation $resume is open in a running Claude Code on $FLEET_SELF" ;;
    esac
    dir=$(history_dirs "$main" | while IFS= read -r d; do
            if [ -f "$HOME/.claude/projects/$(claude_dir_key "$d")/$resume.jsonl" ]; then printf '%s\n' "$d"; fi
          done | head -1)
    [ -n "$dir" ] || die "no conversation $resume for $project on $FLEET_SELF   (fleet history $FLEET_SELF $project)"
    if [ "$(cd "$dir" && pwd -P)" != "$(cd "$main" && pwd -P)" ]; then
      wt=$(basename "$dir")
      [ -z "$task" ] || [ "$task" = "$wt" ] || die "that conversation is in the $wt worktree: it resumes as $(session_name "$project" "$wt")"
      task="$wt"
    fi
  fi
  session=$(session_name "$project" "${task:-main}")
```

(keep the existing running-session check and its comment unchanged after this), then:

```bash
  if [ -n "$dir" ]; then
    :   # resuming: where the conversation ran, never a new worktree
  elif [ -z "$task" ] || [ "$layout" = plain ]; then
```

…existing branches unchanged…, and the end:

```bash
  start_session "$session" "$dir" "$project" "$model" "" "$resume"
```


- [ ] **Step 5: `cmd_new` parsing and the client side**

The first loop becomes:

```bash
  # --resume [id] anywhere: pick up that Claude Code conversation (fleet
  # history lists them); without an id, choose it after the project.
  local model="" resume="" rest=() want=0 wantr=0 a
  for a in "$@"; do
    if [ "$want" = 1 ]; then model="$a"; want=0; continue; fi
    if [ "$wantr" = 1 ]; then wantr=0; if is_uuid "$a"; then resume="$a"; continue; fi; fi
    case "$a" in
      --model) want=1 ;; --model=*) model="${a#--model=}" ;;
      --resume) resume=pick; wantr=1 ;; --resume=*) resume="${a#--resume=}" ;;
      *) rest+=("$a") ;;
    esac
  done
  [ "$want" = 0 ] || die "--model needs a value (fleet models lists them)"
```

The `--local` branch: before `new_local`:

```bash
    [ "$resume" != pick ] || die "--resume needs a conversation id here   (fleet history $FLEET_SELF $1)"
    new_local "$1" "${2:-}" "$model" "$resume"
```

and its usage message gains `[--resume <id>]`.

In the client path, right after `IFS=$'\t' read -r _ project kind <<< "$sel"`, and before the `case "$kind"` prompts:

```bash
  if [ -n "$resume" ]; then
    [ "$resume" != pick ] || [ "$noattach" != 1 ] || die "fleet new --no-attach --resume needs a conversation id   (fleet history $host $project)"
    if [ "$resume" = pick ]; then
      list=$(run_on "$host" "fleet history --local $(shq "$project")") || die "could not list conversations for $project on $host (is fleet up to date there?)"
      [ "$(printf '%s' "$list" | jq 'length')" -gt 0 ] || die "no conversations to resume for $project on $host"
      resume=$(printf '%s\n' "$list" | jq -r '.[] | [(if .name != "" then .name elif .title != "" then .title else "-" end), (.ts | tostring), .id, .prompt] | @tsv' \
        | while IFS=$'\t' read -r a b id c; do
            printf '%s  %s  %s\t%s\n' "$(pad "$a" 20)" "$(pad "$(reltime "$b")" 9)" "${c:0:80}" "$id"
          done \
        | fzf --delimiter='\t' --with-nth=1 --height=40% --reverse --header="conversation to resume in $project on $host" \
        | cut -f2) || return 1
      [ -n "$resume" ] || return 1
    else
      is_uuid "$resume" || die "$resume is not a conversation id   (fleet history $host $project)"
    fi
    # The session's name: the one given, else the conversation's (its
    # worktree's), else main. Asked for by id so the 20 cap does not apply.
    if [ -z "$task" ]; then
      task=$(run_on "$host" "fleet history --local $(shq "$project") $(shq "$resume")" 2>/dev/null | jq -r '.[0].name // ""' 2>/dev/null) || task=""
    fi
  fi
```

Each prompt in the `case "$kind"` block (the `dir` one excepted, a non-repo has no history) gets `&& [ -z "$resume" ]` added to its `if`. The remote call adds the id:

```bash
  dir=$(run_on "$host" "fleet new --local $(shq "$project")${task:+ $(shq "$task")}${init:+ $init}${model:+ --model $(shq "$model")}${resume:+ --resume $(shq "$resume")}") || die "fleet new failed on $host"
```

Usage line for `new` becomes:

```
  fleet new [host] [project] [task] [--all] [--no-attach] [--model <m>] [--resume [id]]
                                  pick a folder on that host (default: here) and start a session in
                                  it; a name adds a session there, or a worktree once converted;
                                  --model: which Claude model (default: Claude Code's own choice);
                                  --resume: pick up an earlier conversation (fleet history)
```

- [ ] **Step 6: Run the tests, under /bin/bash**

Run: `env -u FLEET_TERM -u FLEET_ORIG_PATH test/run.sh 2>&1 | tail -15` and `shellcheck fleet`
Expected: all pass, shellcheck silent. If the picker test fails because the project fzf query `^hist ` does not reach the shim as a regex, change the pattern to the one the shim sees (`--query=^hist `) and keep the assertion.

- [ ] **Step 7: CLAUDE.md**

In the `fleet new [host] [project] [task]` paragraph, after "No task = session `<project>-main` in the repo.", add:

```
  `--resume [id]` (an id from `fleet history`; none = an fzf of them,
  interactive only) starts the session with `claude … --resume <id>` in
  the directory the conversation ran in (`new_local` finds the transcript
  among `history_dirs`; never a new worktree), named by the task given,
  else the conversation's name (`history --local <project> <id>`), else
  main; a worktree conversation always takes the worktree's name. Ids
  are UUID-checked (`is_uuid`); a running conversation is refused.
```

- [ ] **Step 8: Commit**

```bash
git add fleet test/run.sh CLAUDE.md
git commit -m "fleet new --resume: pick up an earlier conversation"
```

---

### Task 3: The New-session sheet offers earlier conversations

**Files:**
- Modify: `app/Shared/Models.swift` (after `ProjectsList`, line ~181)
- Modify: `app/Fleet/Fleet.swift` (`FleetCLI.newSession` ~282, a `history` next to `models` ~184)
- Modify: `app/Fleet/ModelActions.swift` (`newSession` ~64)
- Modify: `app/Fleet/SessionView.swift` (`NewSessionSheet` ~259-380)
- Modify: `CLAUDE.md` (the New-session sheet sentence)

**Interfaces:**
- Consumes: `fleet history <host> <project> --json` → `[{id, dir, name, title, prompt, ts}]`; `fleet new <host> <project> [name] --no-attach [--model m] [--resume id]`.
- Produces: `HistoryEntry`, `FleetCLI.history(host:project:)`, `FleetCLI.newSession(…, resume:)`, `FleetModel.newSession(…, resume:…)`.

- [ ] **Step 1: The model**

`app/Shared/Models.swift`, after `ProjectsList`:

```swift
/// `fleet history <host> <project> --json`: a conversation Claude Code there
/// can resume. `name` is its fleet session name ("" when it was not started
/// by fleet; `title` is shown then), `ts` the transcript's mtime.
struct HistoryEntry: Codable, Hashable, Identifiable {
    let id: String, dir: String, name: String, title: String, prompt: String, ts: Int
    var label: String { !name.isEmpty ? name : (!title.isEmpty ? title : "untitled") }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
}
```

- [ ] **Step 2: The CLI bridge**

`app/Fleet/Fleet.swift`, after `models(on:)`:

```swift
    /// `fleet history <host> <project> --json`: earlier conversations to resume.
    static func history(host: String, project: String) async throws -> [HistoryEntry] {
        try await decode([HistoryEntry].self, from: run(["history", host, project, "--json"]))
    }
```

`newSession` gains the id:

```swift
    static func newSession(host: String, project: String, name: String?, model: String? = nil, resume: String? = nil) async throws -> (String, String, String) {
        var args = ["new", host, project]; if let n = name, !n.isEmpty { args.append(n) }; args.append("--no-attach")
        if let m = model, !m.isEmpty { args += ["--model", m] }
        if let r = resume, !r.isEmpty { args += ["--resume", r] }
```

(rest unchanged).

- [ ] **Step 3: The model action**

`app/Fleet/ModelActions.swift`:

```swift
    func newSession(host: String, project: String, name: String?, model: String? = nil, resume: String? = nil, thenAttach: Bool,
                    status: @escaping (String) -> Void) async throws {
        let t = Terminal.preferred
        status(resume == nil ? "Starting \(project) on \(host): creating the tmux session and launching Claude Code…"
                             : "Resuming the conversation in \(project) on \(host)…")
        let (h, sess, _) = try await FleetCLI.newSession(host: host, project: project, name: name, model: model, resume: resume)
```

(rest unchanged).

- [ ] **Step 4: The sheet**

In `NewSessionSheet`, new state:

```swift
    @State private var resume: String = ""                   // conversation id; "" = New conversation
    @State private var history: [String: [HistoryEntry]] = [:]   // per project, for the sheet's life
    @State private var historyError: [String: String] = [:]
    private var picked: HistoryEntry? { chosen.flatMap { history[$0] }?.first { $0.id == resume } }
    private static let ago: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f }()
```

Shrink the project list to `.frame(height: 150)` and add, right after its `.overlay { … }`:

```swift
            // Earlier conversations in the chosen project (fleet history), to
            // resume instead of starting fresh. Fixed height, like the list
            // above, so the sheet does not change size as they load.
            List(selection: Binding(get: { resume }, set: { resume = $0 ?? "" })) {
                Text("New conversation").tag("")
                ForEach(chosen.flatMap { history[$0] } ?? []) { c in
                    HStack(spacing: 8) {
                        Text(c.label).lineLimit(1)
                        Text(Self.ago.localizedString(for: c.date, relativeTo: Date())).foregroundStyle(.secondary).font(.caption)
                        Text(c.prompt).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    .tag(c.id)
                }
            }
            .frame(height: 120)
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                if let r = ids.first { resume = r; start() }
            }
            .overlay(alignment: .bottom) {
                if let p = chosen {
                    if let e = historyError[p] { Text(e).font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(6) }
                    else if history[p] == nil { ProgressView().controlSize(.small).padding(6) }
                    else if history[p]!.isEmpty { Text("No earlier conversations").font(.caption).foregroundStyle(.secondary).padding(6) }
                }
            }
            .task(id: chosen) { await loadHistory(chosen) }
```

The name field's placeholder follows the pick:

```swift
            TextField(picked.map { $0.name.isEmpty ? "Session name (empty = main)" : "Session name (empty = \($0.name))" } ?? "Session name (empty = main)", text: $name)
                .textFieldStyle(.roundedBorder)
```

The Start button:

```swift
                Button(picked == nil ? "Start" : "Resume") { start() }.keyboardShortcut(.defaultAction).disabled(chosen == nil || status != nil)
```

`start` passes the id:

```swift
                try await model.newSession(host: host, project: p, name: name.isEmpty ? nil : name,
                                           model: chosenModel.isEmpty ? nil : chosenModel,
                                           resume: p == chosen && !resume.isEmpty ? resume : nil,
                                           thenAttach: attach) { status = $0 }
```

and the loader, after `start`:

```swift
    /// The chosen project's conversations, once per project per sheet; the
    /// choice goes back to New conversation whenever the project changes.
    private func loadHistory(_ p: String?) async {
        resume = ""
        guard let p, history[p] == nil, historyError[p] == nil else { return }
        do { history[p] = try await FleetCLI.history(host: host, project: p) }
        catch { historyError[p] = "Could not list conversations: \(error.localizedDescription)" }
    }
```

- [ ] **Step 5: Build**

Run: `xcodebuild -project app/Fleet.xcodeproj -scheme Fleet -derivedDataPath app/.build build 2>&1 | grep -E 'error:|warning: .*SessionView|BUILD' | tail`
Expected: `** BUILD SUCCEEDED **`, no new warnings.

- [ ] **Step 6: Run it on the real fleet**

Install fleet's new CLI on this Mac only (`~/bin/fleet` links the checkout, so it already is). Open the built app (`open app/.build/Build/Products/Debug/Fleet.app`), keep it running 90s+, and on this Mac (m3):
- New session… → a project with history (Fleet) lists conversations below the projects; New conversation is selected; picking one turns Start into Resume and shows its name in the placeholder.
- A project without history shows "No earlier conversations".
- Resume one → a tmux session starts with `claude … --resume <id>` and the attach opens it.
- A remote Mac running an older fleet shows "Could not list conversations…" and New conversation still works.
- `ls ~/Library/Logs/DiagnosticReports | grep -i fleet` shows nothing new.

- [ ] **Step 7: CLAUDE.md**

In the Mac app section, after "(`FleetModel.newSession` is async and reports stages)", add:

```
  Under the project list a Conversation list (`fleet history <host>
  <project> --json`, loaded per project for the sheet's life,
  `HistoryEntry`): New conversation first and selected, then the
  project's earlier conversations; picking one makes Start "Resume"
  (`fleet new … --resume <id>`) and puts its name in the name field's
  placeholder (a typed name wins).
```

- [ ] **Step 8: Commit**

```bash
git add app/Shared/Models.swift app/Fleet/Fleet.swift app/Fleet/ModelActions.swift app/Fleet/SessionView.swift CLAUDE.md
git commit -m "New-session sheet: resume an earlier conversation"
```

- [ ] **Step 9: Mark the spec implemented**

Change the spec's `Status:` line to `implemented.` and commit with the plan file.

After this, the other Macs need the new fleet (`fleet update all`) before the sheet lists their conversations; that pushes to every Mac, so ask the owner first.
