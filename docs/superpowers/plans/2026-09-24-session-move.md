# Moving a Session to Another Mac: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `fleet move <host> <session> [target]` (and a Move menu in the Mac app) moves a fleet session to another Mac. The work must be committed and pushed. The target checkout is put on the branch at origin's tip, and the new agent starts with a handoff note from the old one. The source session ends only after the target is up.

**Architecture:** Everything is in the single-file bash CLI `fleet`, as hidden subcommands that run on the right Mac:
- `move --check` runs on each candidate target. It is fanned out through the existing `gather_into`/`host_fetch`.
- `move --ask` runs on the source and gets the handoff note.
- `move --local` runs on the target and gets the note on stdin.

Two pieces of existing code are extracted so `open`/`new` and `move` share them: `prepare_checkout`, from `cmd_open`, and `start_session`, from `new_local`. The Mac app only calls `fleet move --targets … --json` and `fleet move -y --no-attach …`.

**Tech Stack:** bash 3.2 (`/bin/bash`), git, jq, tmux; SwiftUI (macOS 14+); the test suite `test/run.sh` with the shims in `test/shims/`.

**Spec:** `docs/superpowers/specs/2026-09-24-session-move-design.md`

## Global Constraints

- **bash 3.2.** It must run on stock macOS `/bin/bash` 3.2 and on Homebrew bash 5.
  - Not allowed: `mapfile`, `declare -A`, `${var,,}`, `&>`, `|&`, `;&`, `printf -v`, `readlink -f`.
  - Don't put a `case` inside a `$(...)` that sits inside double quotes: put it in a function.
  - Pad table columns with `pad`, not `printf %-Ns`.
- `set -euo pipefail` is on. shellcheck must stay clean, and every suppression carries its reason on the same line.
- Any value embedded in a string that a shell will parse goes through `shq`, or jq's `@sh` for a list of words. Values passed as separate arguments need nothing.
- **jq/bash `@tsv` handoff:** never emit an empty column, except as the last one.
- **Colours:** only `$DIM`, `$YELLOW`, `$RESET` etc. They are already empty when stdout is not a tty.
- **Step lines:** `printf '%s  <text>%s\n' "$DIM" "$RESET"` on stdout, as `open` does. The app streams them.
- Don't change the record schema. `status` must never output a `handoff` key.
- Git is the only transport for code. The note travels as ssh stdin, which is allowed: it is a one-off push the owner starts.
- **Tests:** run `env -u FLEET_TERM test/run.sh`. It must end with `0 failed` before every commit. (This session exports FLEET_TERM, which breaks unrelated attach tests.)
- **shellcheck:** `shellcheck fleet test/run.sh test/shims/*` must print nothing.
- **App builds:**
  - Mac: `xcodebuild -project app/Fleet.xcodeproj -scheme Fleet -derivedDataPath app/.build build`
  - iOS (must still build; its code does not change): `xcodebuild -project app/Fleet.xcodeproj -scheme FleetMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath app/.build build`
- **Mac app files:**
  - `Fleet.swift` is the only file that runs the CLI.
  - `app/Shared/Models.swift` holds only records mirroring CLI JSON and their helpers.
  - No new Swift files are needed. If you add one anyway, run `xcodegen` in `app/` and commit the project.
- **No owner-specific names in the repo.** Tests use laptop/studio, docs use laptop/mini/studio. Before each commit, grep the diff for real machine and project names.
- **Commit messages** end with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01E3UhJCFdxe91W8tPp1WCNJ
  ```

## Review Focus

1. **A source host that is the machine you're on vs. one reached over ssh.** Every `run_on` must work both ways, and stdin (the note) must reach `move --local` in both cases. The tests move laptop→studio, so the remote target path runs through the fake ssh. Task 5 adds a studio→laptop move for the other direction.
2. **A handoff note with quotes, `$`, backticks and newlines.** It must arrive verbatim as claude's first prompt and must never be evaluated. Task 5's happy path uses exactly such a note and checks the file byte for byte.
3. **Ctrl-C or a failure while waiting for the note.** The `.handoff-pending` marker must not be left behind, or every later `done` would store a `handoff`. Task 4 checks the marker is gone after a timeout and after a blocked answer.
4. **The same repo under different directory names, and a same-named folder that is a different repo.** The target must be found by origin, and a folder with the right name but a different origin must never be used. Task 3 tests both.
5. **An older fleet on the target, which has no `move` command.** It must show up as a target that is not ok, with a reason, rather than breaking `--targets`. Task 3 checks this with the `nofleet` fake host (exit 127), and the reason text comes from `host_fetch`.

---

## File Structure

- `fleet`: hook change; `prepare_checkout` extracted from `cmd_open`; `start_session` extracted from `new_local`; new `record_json`, `move_refusal`, `move_check`, `move_verdict`, `move_check_self`, `move_fetch`, `move_targets_json`, `move_targets`, `move_ask`, `move_local`, `cmd_move`, `HANDOFF_PROMPT`, `FLEET_HANDOFF_TIMEOUT`; usage text; dispatch; example config.
- `test/shims/tmux`: a `send-keys` branch that plays the agent answering (`FAKE_TMUX_ANSWER`, `FAKE_TMUX_ANSWER_RUN`).
- `test/run.sh`: a `hook: handoff` section and a `move` section, both placed just before the final summary line.
- `docs/demo-fleet`: answers `move --targets … --json` and `move -y --no-attach …`.
- `app/Shared/Models.swift`: `MoveTargets`, `Session.moveBlocker`.
- `app/Fleet/Fleet.swift`: `FleetCLI.moveTargets`, `FleetCLI.move`.
- `app/Fleet/Model.swift`: `moveTargets`, `confirmMove` state, `PendingMove`.
- `app/Fleet/ModelActions.swift`: `loadMoveTargets`, `moveSession`.
- `app/Fleet/SessionView.swift`: the Move menu button, and loading the targets.
- `app/Fleet/ContentView.swift`: "Move To" in `SessionMenu`, and the confirmation dialog.
- `CLAUDE.md`, `README.md`, `SECURITY.md`: docs.

---

### Task 1: The hook keeps the full reply while a handoff is pending

**Files:**
- Modify: `fleet` (`cmd_hook`, around lines 2635-2682)
- Test: `test/run.sh` (new section just before the final `printf '\n%d passed, %d failed\n'`)

**Interfaces:**
- Produces: while `$FLEET_STATE/<session>.handoff-pending` exists, a `hook done` writes `handoff` (string: `last_assistant_message` with `\r` and control characters other than `\n`/`\t` removed, at most 20000 characters) into `$FLEET_STATE/<session>.json`, next to the usual keys. Without the marker, or for any other state, there is no `handoff` key.

- [ ] **Step 1: Write the failing tests.** Insert before the final `printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"` in `test/run.sh`:

```bash
section "hook: handoff"
: > "$T/state/plain-main.handoff-pending"
printf '%s' '{"last_assistant_message":"Goal: x.\nNext: **y** with `z`\u001b[31m.\r\nDone."}' \
  | renv FAKE_TMUX_SESSION=plain-main -- hook done >/dev/null
assert_eq "while a handoff is pending, done keeps the whole reply as handoff" \
  "$(jq -r .handoff "$T/state/plain-main.json")" "$(printf 'Goal: x.\nNext: **y** with `z`[31m.\nDone.')"
assert_eq "  ...said is still the clipped one-liner"   "$(jq -r .said "$T/state/plain-main.json")" "Goal: x. Next: y with z [31m. Done."
rm -f "$T/state/plain-main.handoff-pending"
printf '%s' '{"last_assistant_message":"later"}' | renv FAKE_TMUX_SESSION=plain-main -- hook done >/dev/null
assert_eq "without the marker there is no handoff key" "$(jq -r 'has("handoff")' "$T/state/plain-main.json")" "false"
: > "$T/state/plain-main.handoff-pending"
renv FAKE_TMUX_SESSION=plain-main -- hook running </dev/null >/dev/null
assert_eq "  ...nor for a state other than done"      "$(jq -r 'has("handoff")' "$T/state/plain-main.json")" "false"
printf '%s' '{"last_assistant_message":"note"}' | renv FAKE_TMUX_SESSION=plain-main -- hook done >/dev/null
assert_eq "the record never carries handoff" \
  "$(renv "FAKE_TMUX_SESSIONS=plainR-main plain-main" -- status --json | jq -r '[.[] | has("handoff")] | any')" "false"
rm -f "$T/state/plain-main.handoff-pending"
```

- [ ] **Step 2: Run the tests and confirm the new ones fail.**

Run: `env -u FLEET_TERM test/run.sh 2>&1 | tail -15`
Expected: FAIL on "while a handoff is pending, done keeps the whole reply as handoff" (it gets `null`). The "no handoff key" and "record never carries" asserts pass already.

- [ ] **Step 3: Implement.** In `cmd_hook`:

After `f="$FLEET_STATE/$session.json"`, add:

```bash
  # While `fleet move` waits for a handoff note (move_ask), keep the whole
  # reply too: said is clipped to one line of 800, too little for a note.
  local full=false; [ -e "$FLEET_STATE/$session.handoff-pending" ] && full=true
```

Pass it to jq by adding `--argjson full "$full"` to the `jq -c` call's arguments, next to `--argjson old "$old"`.

In the jq program, make the first line after the `def owners…` line capture the input:

```
    . as $in
    | ($old | if type == "object" then . else {} end) as $o
```

(this replaces the existing `($old | if type == "object" then . else {} end) as $o` line). After the closing `said: $said }` of the object, and before `' > "$f.tmp"`, add:

```
    | if $full and $state == "done"
      then .handoff = ($in.last_assistant_message // "" | if type == "string" then . else "" end
                       | gsub("\r"; "") | gsub("[\\x01-\\x08\\x0b-\\x1f\\x7f]"; "") | .[:20000])
      else . end
```

Also extend the comment block at the top of `cmd_hook` with one line under `said`:

```
  #   handoff     the whole of it, only while `fleet move` waits for a note
```

- [ ] **Step 4: Run the tests and confirm they pass.**

Run: `env -u FLEET_TERM test/run.sh 2>&1 | tail -3`
Expected: `… passed, 0 failed`. Then run `shellcheck fleet`, which should print nothing.

- [ ] **Step 5: Commit.**

```bash
git add fleet test/run.sh
git commit -m "hook: keep the whole reply as handoff while fleet move waits for a note" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01E3UhJCFdxe91W8tPp1WCNJ"
```

---

### Task 2: Extract `prepare_checkout` and `start_session`

This is a pure refactor with no behaviour change. The existing `open` and `new` tests are the safety net (the sections "open" and "doctor and misc", around lines 255-295 and 390-401).

**Files:**
- Modify: `fleet` (`cmd_open` around 1746-1811; `new_local` around 1578-1625)

**Interfaces:**
- Produces:
  - `prepare_checkout <project> <name> <branch> <worktree:true|false> [strict]`. Must be called directly, never inside `$(...)`, because it sets the global `CHECKOUT_DIR`. It prints step lines on stdout and dies on a hard error. With `strict` non-empty, a missing `origin/<branch>`, or a checkout that cannot be fast-forwarded to it, also dies.
  - `start_session <session> <dir> <project> [model] [first-prompt-file]`. It creates the tmux session if there isn't one, types the claude line into it, brands it and registers it. It prints nothing. With a file, the typed line ends with ` "$(cat '<file>'; rm -f '<file>')"`.

- [ ] **Step 1: Confirm the baseline is green.**

Run: `env -u FLEET_TERM test/run.sh 2>&1 | tail -1`
Expected: `… passed, 0 failed`

- [ ] **Step 2: Add `prepare_checkout`** directly above `cmd_open`:

```bash
# prepare_checkout <project> <name> <branch> <worktree> [strict]: put this
# Mac's checkout of a session's branch at origin's tip, one dim line per
# step. <worktree> true = the worktree at worktree_path (made when missing,
# converting a plain clone first); else the clone itself, switched to
# <branch> (never with uncommitted changes to tracked files). `open` takes
# what it can and warns; strict (`move`) dies unless the checkout ends up at
# origin/<branch>. Sets CHECKOUT_DIR, so call it directly, never in $(...).
prepare_checkout() {
  local project="$1" name="$2" branch="$3" worktree="$4" strict="${5:-}" mainrepo dir cur dirty
  mainrepo=$(project_repo "$project") || die "no clone for $project under $FLEET_ROOT"
  if [ "$worktree" != true ]; then dir="$mainrepo"   # a session in the repo itself
  else enable_worktrees "$mainrepo"; dir=$(worktree_path "$project" "$name"); fi
  CHECKOUT_DIR="$dir"

  printf '%s  fetching origin for %s%s\n' "$DIM" "$project" "$RESET"
  git -C "$mainrepo" fetch origin --prune -q
  git -C "$mainrepo" worktree prune
  if ! git -C "$mainrepo" rev-parse -q --verify "origin/$branch" >/dev/null; then
    { [ -d "$dir" ] && [ -z "$strict" ]; } || die "origin/$branch not found: not pushed yet, or deleted after merge"
    printf '%s  origin/%s not found (not pushed, or deleted after merge), left alone%s\n' \
      "$YELLOW" "$branch" "$RESET"
  elif [ "$worktree" != true ]; then
    # A session in the repo itself: put the local repo on that branch first.
    # Never touch a checkout with uncommitted changes to tracked files.
    # Untracked files ride along, as git checkout itself allows (a collision
    # is git's error, surfaced below). The refusal says what is dirty.
    cur=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ "$cur" != "$branch" ]; then
      dirty=$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null | head -5)
      [ -z "$dirty" ] \
        || die "$dir is on '$cur' with uncommitted changes; commit or stash before switching to '$branch':
$dirty"
      if git -C "$dir" show-ref -q --verify "refs/heads/$branch"; then git -C "$dir" checkout -q "$branch"
      else git -C "$dir" checkout -q --track -b "$branch" "origin/$branch"; fi
      printf '%s  switched %s from %s to %s%s\n' "$DIM" "$project" "$cur" "$branch" "$RESET"
    fi
    if git -C "$dir" merge --ff-only -q "origin/$branch" 2>/dev/null; then
      printf '%s  %s is at origin/%s (%s)%s\n' "$DIM" "$branch" "$branch" "$(git -C "$dir" log -1 --format=%s 2>/dev/null)" "$RESET"
    else
      [ -z "$strict" ] || die "local $branch in $dir can't be fast-forwarded to origin/$branch (diverged, or local changes in the way)"
      printf '%s  local %s diverged from origin/%s, left alone%s\n' "$YELLOW" "$branch" "$branch" "$RESET"
    fi
  else
    if [ ! -d "$dir" ]; then
      mkdir -p "$(dirname "$dir")"
      if git -C "$mainrepo" show-ref -q --verify "refs/heads/$branch"; then
        git -C "$mainrepo" worktree add -q "$dir" "$branch"
      else
        git -C "$mainrepo" worktree add -q --track -b "$branch" "$dir" "origin/$branch"
      fi
    fi
    if ! git -C "$dir" merge --ff-only -q "origin/$branch" 2>/dev/null; then
      [ -z "$strict" ] || die "the worktree $dir can't be fast-forwarded to origin/$branch (diverged, or local changes in the way)"
      printf '%s  local worktree diverged from origin/%s, left alone%s\n' "$YELLOW" "$branch" "$RESET"
    fi
  fi
}
```

- [ ] **Step 3: Replace the body of `cmd_open`** after the `detached` check with:

```bash
  # The local clone is the directory of the same name, else the one clone
  # under FLEET_ROOT with the same origin: the same repo can live under
  # different directory names on different Macs.
  local other
  if ! project_repo "$project" >/dev/null; then
    other=$(project_for_remote "${remote:-}") \
      || die "no local clone for $project under $FLEET_ROOT${remote:+ (origin $remote)}"
    printf '%s  no %s here, using %s (same origin)%s\n' "$DIM" "$project" "$other" "$RESET"
    project="$other"
  fi
  prepare_checkout "$project" "$name" "$branch" "$worktree"
  open_checkout "$CHECKOUT_DIR"
}
```

(Delete the old `local mainrepo dir other` block through the end of the old if/elif/else chain.)

- [ ] **Step 4: Add `start_session`** directly above `new_local`, and make `new_local` use it. New function:

```bash
# start_session <session> <dir> <project> [model] [first-prompt file]: the
# tmux session in <dir> with claude typed into it (an existing session is
# reused as it is), branded and registered. With a file, claude's first
# prompt is its text, read by the pane's shell and removed as it is read, so
# a long note never passes through send-keys.
start_session() {
  local session="$1" dir="$2" project="$3" model="${4:-}" first="${5:-}" prompt=""
  [ -z "$first" ] || prompt=" \"\$(cat $(shq "$first"); rm -f $(shq "$first"))\""
  if ! tmux has-session -t "$session" 2>/dev/null; then
    # A shell with claude typed into it, not `claude` as the session command,
    # so the session (and the `attached` fallback state) outlives the agent.
    tmux new-session -d -s "$session" -c "$dir"
    # Named <machine>-<tmux session>: the Claude apps list every machine's
    # sessions together and two Macs can both have a Project-main. Only this
    # label carries the machine; the tmux session and fleet's records do not.
    # --remote-control makes it reachable from claude.ai/code and the mobile
    # app, --permission-mode auto starts it in auto mode. FLEET_CLAUDE_ARGS in
    # the config changes the flags per machine. --model only when asked
    # (fleet new --model), so Claude Code's own default applies otherwise.
    tmux send-keys -t "$session" "claude -n $(shq "$FLEET_SELF-$session") $FLEET_CLAUDE_ARGS${model:+ --model $(shq "$model")}$prompt" Enter
  fi
  brand_session "$session" "$FLEET_SELF"
  register_session "$session" "$dir" "$project"
}
```

In `new_local`, replace everything from `if ! tmux has-session -t "$session"` through `register_session "$session" "$dir" "$project"` with:

```bash
  start_session "$session" "$dir" "$project" "$model"
```

(keep the final `printf '%s\n' "$dir"`).

- [ ] **Step 5: Run the tests and shellcheck.**

Run: `env -u FLEET_TERM test/run.sh 2>&1 | tail -3 && shellcheck fleet`
Expected: `… passed, 0 failed` (same count as Step 1), and shellcheck prints nothing.

- [ ] **Step 6: Commit.**

```bash
git add fleet
git commit -m "Extract prepare_checkout (open) and start_session (new) for fleet move" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01E3UhJCFdxe91W8tPp1WCNJ"
```

---

### Task 3: `move_refusal`, `move --check` and `move --targets`

**Files:**
- Modify: `fleet`: new functions below `kill_local`, a new `cmd_move` stub, dispatch, usage
- Test: `test/run.sh`: new `move` section before the final summary line

**Interfaces:**
- Consumes: `host_fetch`, `gather_into`, `project_repo`, `project_for_remote`, `repo_key`, `session_name`, `sessions_in`, `host_status`.
- Produces:
  - `record_json <host> <session>`: that fleet session's record as one line of JSON. Dies if the host is unknown or down, or the session isn't there.
  - `move_refusal <record json>`: prints why the session can't move, or nothing. Checked in this order, with these texts:
    - running: `the agent is working; move it once it is done`
    - blocked: `the agent is waiting on you; answer it first`
    - detached: `detached HEAD: there is no branch to move`
    - dirty: `uncommitted changes; commit and push them first`
    - no upstream: `<branch> was never pushed`
    - ahead: `<n> commit(s) not pushed`
  - `fleet move --check <project> <remote> <name> <branch> <worktree>` prints `{"ok":bool,"project":str,"why":str}`.
  - `move_targets_json <host> <session>` prints the JSON below, where `source` carries `host, session, project, name, branch, worktree, remote, subject`:

    ```
    {source:{…}, movable:bool, why:str, targets:[{host,project,ok,why}]}
    ```
  - `fleet move --targets <host> <session> [--json]` prints that JSON with `--json`, else a table.

- [ ] **Step 1: Write the failing tests.** Append before the final summary line (after Task 1's section):

```bash
section "move"
make_origin delta main
git clone -q "$T/origins/delta.git" "$T/root/deltaL"
git -C "$T/root/deltaL" checkout -q -b feature/d; echo d > "$T/root/deltaL/d.txt"
git -C "$T/root/deltaL" add -A; git -C "$T/root/deltaL" commit -qm "delta work"; git -C "$T/root/deltaL" push -q -u origin feature/d
git clone -q "$T/origins/delta.git" "$T/rootR/deltaS"          # studio: the same repo under another name, on main
run new --local deltaL >/dev/null                               # the session to move: deltaL-main on laptop
MV=(FLEET_HOSTS="laptop studio" "FAKE_TMUX_SESSIONS=plainR-main deltaL-main" FLEET_EXIT_TIMEOUT=1 FLEET_HANDOFF_TIMEOUT=5)
mvst() { printf '{"state":"%s","ts":%s}' "$1" "$(date +%s)" > "$T/state/deltaL-main.json"; }

mvst running
assert_contains "move refuses while the agent is working" "$(renv "${MV[@]}" -- move --targets laptop deltaL-main --json | jq -r .why)" "the agent is working"
mvst blocked
assert_contains "  ...or waiting on you"                  "$(renv "${MV[@]}" -- move --targets laptop deltaL-main --json | jq -r .why)" "waiting on you"
rm -f "$T/state/deltaL-main.json"
echo x > "$T/root/deltaL/d.txt"
assert_contains "  ...with uncommitted changes"           "$(renv "${MV[@]}" -- move --targets laptop deltaL-main --json | jq -r .why)" "uncommitted changes"
git -C "$T/root/deltaL" checkout -q -- d.txt
git -C "$T/root/deltaL" commit -q --allow-empty -m local
assert_contains "  ...with commits not pushed"            "$(renv "${MV[@]}" -- move --targets laptop deltaL-main --json | jq -r .why)" "1 commit(s) not pushed"
git -C "$T/root/deltaL" reset -q --hard HEAD~1
git -C "$T/root/deltaL" checkout -q -b feature/np
assert_contains "  ...on a branch never pushed"           "$(renv "${MV[@]}" -- move --targets laptop deltaL-main --json | jq -r .why)" "feature/np was never pushed"
git -C "$T/root/deltaL" checkout -q feature/d; git -C "$T/root/deltaL" branch -q -D feature/np

TJ=$(renv "${MV[@]}" FLEET_HOSTS="laptop studio dead nofleet" -- move --targets laptop deltaL-main --json)
assert_eq "--targets: movable once clean and pushed"      "$(printf '%s' "$TJ" | jq -r '"\(.movable) [\(.why)]"')" "true []"
assert_eq "  ...source carries what move needs"           "$(printf '%s' "$TJ" | jq -r '.source | "\(.project) \(.name) \(.branch) \(.worktree) \(.subject)"')" "deltaL main feature/d false delta work"
assert_eq "  ...studio's clone under another name, same origin, qualifies" "$(printf '%s' "$TJ" | jq -r '.targets[] | select(.host=="studio") | "\(.ok) \(.project)"')" "true deltaS"
assert_eq "  ...the source host is not a target"          "$(printf '%s' "$TJ" | jq -r '[.targets[] | select(.host=="laptop")] | length')" "0"
assert_contains "  ...a dead host is listed as not ok, with why" "$(printf '%s' "$TJ" | jq -r '.targets[] | select(.host=="dead") | "\(.ok) \(.why)"')" "false ssh failed"
assert_contains "  ...so is one without fleet"            "$(printf '%s' "$TJ" | jq -r '.targets[] | select(.host=="nofleet") | "\(.ok) \(.why)"')" "false fleet not installed"
assert_contains "--targets table names the target and its clone" "$(renv "${MV[@]}" -- move --targets laptop deltaL-main)" "deltaS"

echo z > "$T/rootR/deltaS/f"
assert_eq "a target clone with uncommitted changes on another branch does not qualify" \
  "$(renv "${MV[@]}" -- move --targets laptop deltaL-main --json | jq -r '.targets[0].why')" "its clone has uncommitted changes on main"
git -C "$T/rootR/deltaS" checkout -q -- f
printf '%s\ndeltaS\n' "$T/rootR/deltaS" > "$RH/.local/state/fleet/sessions/deltaS-busy"
assert_eq "  ...nor one with a live session in it on another branch" \
  "$(renv "${MV[@]}" "FAKE_TMUX_SESSIONS=plainR-main deltaL-main deltaS-busy" -- move --targets laptop deltaL-main --json | jq -r '.targets[0].why')" "deltaS-busy works in its clone, on main"
rm -f "$RH/.local/state/fleet/sessions/deltaS-busy"
assert_eq "  ...nor one already running a session of that name" \
  "$(renv "${MV[@]}" "FAKE_TMUX_SESSIONS=plainR-main deltaL-main deltaS-main" -- move --targets laptop deltaL-main --json | jq -r '.targets[0].why')" "deltaS-main is already running here"
assert_eq "--check: no clone of the repo"                 "$(run move --check nosuch "$T/origins/nothere.git" main main false | jq -c .)" '{"ok":false,"project":"","why":"no clone of this repo under FLEET_ROOT"}'
assert_eq "--check: a same-named folder of another repo is not used; the clone with that origin is" \
  "$(run move --check plain "$T/origins/delta.git" main feature/d false | jq -r .project)" "deltaL"
```

- [ ] **Step 2: Run the tests and confirm they fail.**

Run: `env -u FLEET_TERM test/run.sh 2>&1 | grep -A2 'move$' | head; env -u FLEET_TERM test/run.sh 2>&1 | tail -1`
Expected: the `move` asserts FAIL with `unknown command "move"`.

- [ ] **Step 3: Implement.** In `fleet`, directly after `kill_local`, add:

```bash
# ---------------------------------------------------------------- move
#
# fleet move: a session goes to another Mac. Only work that is committed and
# pushed moves (git is the transport); the agent there starts with a handoff
# note from the one here. Hidden parts, each run on the Mac it concerns:
#   move --check  on each candidate: can it take the session?
#   move --ask    on the source: ask the agent for its handoff note
#   move --local  on the target: checkout at origin/<branch>, start the session

# record_json <host> <session>: that fleet session's record, one JSON line.
record_json() {
  local h="$1" sess="$2" tmp rec why=""
  case " $FLEET_HOSTS " in *" $h "*) ;; *) die "unknown host '$h'. hosts:$(hosts_line)" ;; esac
  tmp=$(mktemp -d)
  host_status "$h" "$tmp" ""
  rec=$(jq -c --arg s "$sess" 'first(.[] | select(.session == $s)) // empty' "$tmp/$h.json" 2>/dev/null || true)
  [ ! -e "$tmp/$h.down" ] || why=$(cat "$tmp/$h.down")
  rm -rf "$tmp"
  if [ -z "$rec" ]; then
    [ -z "$why" ] || die "$h: $why"
    die "no session '$sess' on $h   (fleet ls $h)"
  fi
  printf '%s\n' "$rec"
}

# move_refusal <record json>: why that session can not move yet, or nothing.
# The Mac app's Session.moveBlocker says the same, in the same order.
move_refusal() {
  printf '%s' "$1" | jq -r '
    if   .state == "running"     then "the agent is working; move it once it is done"
    elif .state == "blocked"     then "the agent is waiting on you; answer it first"
    elif .branch == "(detached)" then "detached HEAD: there is no branch to move"
    elif .dirty                  then "uncommitted changes; commit and push them first"
    elif .upstream == ""         then "\(.branch) was never pushed"
    elif .ahead > 0              then "\(.ahead) commit(s) not pushed"
    else empty end'
}

move_verdict() { jq -nc --argjson ok "$1" --arg project "$2" --arg why "$3" '{ok: $ok, project: $project, why: $why}'; }

# fleet move --check <project> <remote> <name> <branch> <worktree>: can this
# Mac take that session? The clone is the project of that name when its
# origin is the same repo, else the one clone with that origin. A session in
# the repo itself needs the clone free to switch branch: no uncommitted
# changes and no live session in it, unless it is on that branch already.
move_check() {
  local project="${1:-}" remote="${2:-}" name="${3:-}" branch="${4:-}" worktree="${5:-}" repo="" cur s
  [ -n "$worktree" ] || die "usage: fleet move --check <project> <remote> <name> <branch> <worktree>"
  if [ -n "$remote" ] && repo=$(project_repo "$project") \
     && [ "$(repo_key "$(git -C "$repo" remote get-url origin 2>/dev/null || true)")" = "$(repo_key "$remote")" ]; then :
  elif [ -n "$remote" ] && project=$(project_for_remote "$remote"); then repo=$(project_repo "$project")
  else move_verdict false "" "no clone of this repo under FLEET_ROOT"; return 0; fi
  s=$(session_name "$project" "$name")
  if tmux has-session -t "$s" 2>/dev/null; then move_verdict false "$project" "$s is already running here"; return 0; fi
  if [ "$worktree" != true ]; then
    cur=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ "$cur" != "$branch" ]; then
      if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        move_verdict false "$project" "its clone has uncommitted changes on $cur"; return 0
      fi
      for s in $(sessions_in "$repo"); do
        if tmux has-session -t "$s" 2>/dev/null; then move_verdict false "$project" "$s works in its clone, on $cur"; return 0; fi
      done
    fi
  fi
  move_verdict true "$project" ""
}
# host_fetch hands a local function its arguments as one string; for move
# --check that string is words quoted by jq's @sh in move_targets_json only.
move_check_self() { eval "set -- $1"; move_check "$@"; }
move_fetch() { host_fetch "$1" "$2" move_check_self "fleet move --check" "$3" '{}'; }

# move_targets_json <host> <session>: whether the session can move and which
# other Macs can take it, asking them all at once.
move_targets_json() {
  local src="$1" sess="$2" rec why others="" h tmp args
  rec=$(record_json "$src" "$sess") || exit 1
  why=$(move_refusal "$rec")
  for h in $FLEET_HOSTS; do [ "$h" = "$src" ] || others="$others $h"; done
  others="${others# }"
  args=$(printf '%s' "$rec" | jq -r '[.project, .remote, .name, .branch, (.worktree | tostring)] | @sh')
  tmp=$(mktemp -d)
  [ -z "$others" ] || FLEET_HOSTS="$others" gather_into "$tmp" "$args" move_fetch
  for h in $others; do
    if [ -e "$tmp/$h.down" ]; then
      jq -nc --arg host "$h" --arg why "$(cat "$tmp/$h.down")" '{host: $host, project: "", ok: false, why: $why}'
    else
      jq -c --arg host "$h" '{host: $host, project: (.project // ""), ok: (.ok == true),
        why: (if .ok == true then "" else (.why // "" | if . == "" then "no answer (is fleet up to date there?)" else . end) end)}' "$tmp/$h.json"
    fi
  done | jq -sc --argjson rec "$rec" --arg why "$why" '
    {source: ($rec | {host, session, project, name, branch, worktree, remote, subject}),
     movable: ($why == ""), why: $why, targets: .}'
  rm -rf "$tmp"
}

# fleet move --targets <host> <session> [--json]
move_targets() {
  local json=0 a rest=() tj
  for a in "$@"; do case "$a" in --json) json=1 ;; *) rest+=("$a") ;; esac; done
  set -- ${rest[@]+"${rest[@]}"}
  [ $# -ge 2 ] || die "usage: fleet move --targets <host> <session> [--json]"
  tj=$(move_targets_json "$1" "$2") || exit 1
  if [ "$json" = 1 ]; then printf '%s\n' "$tj"; return 0; fi
  printf '%s' "$tj" | jq -r '"\(.source.session) on \(.source.host): " + (if .movable then "can move" else "can not move yet: \(.why)" end)'
  printf '%s' "$tj" | jq -r '.targets[] | [.host, (if .project == "" then "-" else .project end), (if .ok then "ok" else .why end), (.ok | tostring)] | @tsv' \
    | while IFS=$'\t' read -r h p w ok; do
        if [ "$ok" = true ]; then printf '  %s  %s  %s\n' "$(pad "$h" 14)" "$(pad "$p" 24)" "$w"
        else printf '  %s%s  %s  %s%s\n' "$DIM" "$(pad "$h" 14)" "$(pad "$p" 24)" "$w" "$RESET"; fi
      done
}

# fleet move [-y] [--no-attach] [--model <m>] <host> <session> [target]
cmd_move() {
  case "${1:-}" in
    --check)   shift; move_check "$@"; return 0 ;;
    --targets) shift; move_targets "$@"; return 0 ;;
  esac
  die "usage: fleet move [-y] [--no-attach] [--model <m>] <host> <session> [target]"
}
```

Add the dispatch line after `kill|stop) cmd_kill "$@" ;;`:

```bash
  move|mv)  cmd_move "$@" ;;
```

Add to `usage()` after the `fleet kill` entry:

```
  fleet move [-y] [--no-attach] <host> <session> [target]
                                  move a session to another Mac: committed and pushed work only;
                                  the agent writes a handoff note, the new session starts with it
  fleet move --targets <host> <session> [--json]
                                  which Macs can take that session, and why not
```

Add the default near `FLEET_EXIT_TIMEOUT` (Task 4 uses it, but `MV` in the tests sets it already):

```bash
: "${FLEET_HANDOFF_TIMEOUT:=180}"                  # move: how long the agent gets to write its handoff note, seconds
```

and to `write_example_config`, after the `FLEET_EXIT_TIMEOUT` line:

```
# FLEET_HANDOFF_TIMEOUT=180             # fleet move: seconds the agent gets to write its handoff note
```

- [ ] **Step 4: Run the tests and shellcheck.**

Run: `env -u FLEET_TERM test/run.sh 2>&1 | tail -3 && shellcheck fleet test/run.sh`
Expected: `… passed, 0 failed`. If `nofleet`'s reason differs (host_fetch maps exit 127 to "fleet not installed (fleet install nofleet)"), check the output rather than loosening the assert.

- [ ] **Step 5: Commit.**

```bash
git add fleet test/run.sh
git commit -m "fleet move --targets: which Macs can take a session, and why not" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01E3UhJCFdxe91W8tPp1WCNJ"
```

---

### Task 4: `move --ask`: get the handoff note from the source agent

**Files:**
- Modify: `fleet` (new `HANDOFF_PROMPT`, `move_ask`; `cmd_move` gains `--ask`)
- Modify: `test/shims/tmux` (the `send-keys` branch)
- Test: `test/run.sh` (the `move` section)

**Interfaces:**
- Consumes: `pane_command`, and the hook's `handoff` key from Task 1.
- Produces: `fleet move --ask <session>` prints the note on stdout (exit 0). It prints nothing (exit 0) when the tmux session is gone or no agent is in its pane. It dies (exit 1) on timeout or `blocked`. `$FLEET_STATE/<session>.handoff-pending` never outlives the call.

- [ ] **Step 1: Teach the fake tmux to answer.** In `test/shims/tmux`, add to the `case`:

```bash
  send-keys)
    # FAKE_TMUX_ANSWER=<file>: play the agent answering fleet move's handoff
    # request: a done state file whose handoff is that file's text, as the
    # hook writes it while the request is pending. FAKE_TMUX_ANSWER_RUN runs
    # first: the agent doing something it was told not to. FAKE_TMUX_ANSWER=
    # blocked: the agent asks for permission instead.
    case "$*" in *"handoff note"*)
      if [ "${FAKE_TMUX_ANSWER:-}" = blocked ]; then
        printf '{"state":"blocked","ts":%s}' "$(date +%s)" > "$FLEET_STATE/$3.json"
      elif [ -n "${FAKE_TMUX_ANSWER:-}" ]; then
        [ -z "${FAKE_TMUX_ANSWER_RUN:-}" ] || sh -c "$FAKE_TMUX_ANSWER_RUN"
        jq -n --rawfile h "$FAKE_TMUX_ANSWER" --argjson ts "$(date +%s)" \
          '{state: "done", ts: $ts, said: $h[:800], handoff: $h}' > "$FLEET_STATE/$3.json"
      fi ;;
    esac ;;
```

- [ ] **Step 2: Write the failing tests.** Append to the `move` section:

```bash
printf 'Goal: ship it.\nNext: run `make` with "$HOME" set; don'\''t push.' > "$T/note.txt"
: > "$SHIM_LOG"
O=$(renv "${MV[@]}" FAKE_TMUX_COMMAND=claude FAKE_TMUX_ANSWER="$T/note.txt" -- move --ask deltaL-main 2>&1); RC=$?
assert_eq "--ask prints the agent's note verbatim"       "$O" "$(cat "$T/note.txt")"
assert_eq "  ...exit 0"                                   "$RC" "0"
assert_contains "  ...having typed the request literally" "$(cat "$SHIM_LOG")" "tmux send-keys -t deltaL-main -l This session is being moved to another Mac."
assert_false "  ...and the pending marker is gone"        test -e "$T/state/deltaL-main.handoff-pending"
rm -f "$T/state/deltaL-main.json"
: > "$SHIM_LOG"
assert_eq "--ask with no agent in the pane asks nobody"   "$(renv "${MV[@]}" -- move --ask deltaL-main 2>&1)" ""
assert_lacks "  ...types nothing"                         "$(cat "$SHIM_LOG")" "send-keys"
O=$(renv "${MV[@]}" FAKE_TMUX_COMMAND=claude FLEET_HANDOFF_TIMEOUT=1 -- move --ask deltaL-main 2>&1); RC=$?
assert_contains "--ask gives up after FLEET_HANDOFF_TIMEOUT" "$O" "no handoff note from deltaL-main after 1s"
assert_eq "  ...exit 1"                                   "$RC" "1"
assert_false "  ...the pending marker is gone"            test -e "$T/state/deltaL-main.handoff-pending"
O=$(renv "${MV[@]}" FAKE_TMUX_COMMAND=claude FAKE_TMUX_ANSWER=blocked -- move --ask deltaL-main 2>&1); RC=$?
assert_contains "--ask stops when the agent asks for something instead" "$O" "asked for something instead of writing the note"
assert_eq "  ...exit 1"                                   "$RC" "1"
assert_false "  ...the pending marker is gone"            test -e "$T/state/deltaL-main.handoff-pending"
rm -f "$T/state/deltaL-main.json"
```

- [ ] **Step 3: Run the tests and confirm they fail.**

Run: `env -u FLEET_TERM test/run.sh 2>&1 | grep -E 'FAIL.*(--ask|pending)' | head`
Expected: the `--ask` asserts FAIL (usage error from `cmd_move`).

- [ ] **Step 4: Implement.** Near the top of the move block (after the section comment), add:

```bash
# Typed into the source agent's pane by move --ask. One line: send-keys -l.
HANDOFF_PROMPT="This session is being moved to another Mac. Do not change, commit or push anything. Reply with a handoff note for the agent that continues there: the goal, what is done, what is next, and any open questions or decisions pending with the owner. Reply with the note only."
```

After `move_targets`, add:

```bash
# fleet move --ask <session>: on the session's host. Ask the agent in it for
# a handoff note and print the note once its turn is done (the hook keeps
# the whole reply as `handoff` while the marker exists). Nothing is printed
# when no agent is in the pane: nobody to ask. Fails, leaving the session as
# it was, when no note comes within FLEET_HANDOFF_TIMEOUT or the agent asks
# for something instead.
move_ask() {
  local s="${1:-}" f pending t0 i=0 st note=""
  [ -n "$s" ] || die "usage: fleet move --ask <session>"
  tmux has-session -t "$s" 2>/dev/null || return 0
  case "$(pane_command "$s")" in ""|sh|bash|zsh|fish|tmux) return 0 ;; esac
  f="$FLEET_STATE/$s.json"; pending="$FLEET_STATE/$s.handoff-pending"
  mkdir -p "$FLEET_STATE"; : > "$pending"
  # shellcheck disable=SC2064  # expanded now: $pending is local, gone by the time the trap runs
  trap "rm -f $(shq "$pending")" EXIT
  t0=$(date +%s)
  tmux send-keys -t "$s" C-u 2>/dev/null || true
  tmux send-keys -t "$s" -l "$HANDOFF_PROMPT" 2>/dev/null || die "could not type into $s"
  tmux send-keys -t "$s" Enter 2>/dev/null || true
  while [ "$i" -lt "$FLEET_HANDOFF_TIMEOUT" ]; do
    sleep 1; i=$((i + 1))
    st=$(jq -r --argjson t0 "$t0" 'select(.ts >= $t0) | .state' "$f" 2>/dev/null || true)
    case "$st" in
      done)    note=$(jq -r '.handoff // .said // ""' "$f" 2>/dev/null || true); [ -z "$note" ] || break ;;
      blocked) die "the agent in $s asked for something instead of writing the note; answer it there, then move again" ;;
    esac
  done
  [ -n "$note" ] || die "no handoff note from $s after ${FLEET_HANDOFF_TIMEOUT}s; it was left as it was"
  printf '%s\n' "$note"
}
```

In `cmd_move`'s `case`, add:

```bash
    --ask)     shift; move_ask "${1:-}"; return 0 ;;
```

- [ ] **Step 5: Run the tests and shellcheck.**

Run: `env -u FLEET_TERM test/run.sh 2>&1 | tail -3 && shellcheck fleet test/run.sh test/shims/tmux`
Expected: `… passed, 0 failed`, and shellcheck prints nothing.

- [ ] **Step 6: Commit.**

```bash
git add fleet test/run.sh test/shims/tmux
git commit -m "fleet move --ask: the source agent writes a handoff note" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01E3UhJCFdxe91W8tPp1WCNJ"
```

---

### Task 5: `move --local` and the whole `fleet move`

**Files:**
- Modify: `fleet` (`move_local`; `cmd_move` gets its full body)
- Test: `test/run.sh` (the `move` section)

**Interfaces:**
- Consumes: `prepare_checkout … strict`, `start_session` (Task 2); `move_targets_json`, `move_refusal`, `record_json` (Task 3); `move --ask` (Task 4); `launch_term`, `run_on`, `kill --local`.
- Produces:
  - `fleet move --local <project> <name> <branch> <worktree> [model]` takes the note on stdin. It prints step lines, and the checkout directory as its last line.
  - `fleet move [-y] [--no-attach] [--model <m>] <host> <session> [target]`. With `--no-attach`, the last stdout line is `<target>\t<session>\t<dir>`.

- [ ] **Step 1: Write the failing tests.** Append to the `move` section:

```bash
H="$RH/.local/state/fleet/deltaS-main.handoff"
mv_reset() {   # studio's clone back on main with no session; deltaL-main registered on laptop again
  git -C "$T/rootR/deltaS" checkout -q main 2>/dev/null
  rm -f "$RH/.local/state/fleet/sessions/deltaS-main" "$H" "$T/state/deltaL-main.json"
  run new --local deltaL >/dev/null
}
assert_contains "move without -y and no tty refuses" "$(renv "${MV[@]}" -- move laptop deltaL-main studio 2>&1 </dev/null)" "without -y"
assert_contains "move to a host that can not take it says why" \
  "$(renv "${MV[@]}" "FAKE_TMUX_SESSIONS=plainR-main deltaL-main deltaS-main" -- move -y --no-attach laptop deltaL-main studio 2>&1)" "studio can't take deltaL-main: deltaS-main is already running here"

: > "$SHIM_LOG"
O=$(renv "${MV[@]}" FAKE_TMUX_COMMAND=claude FAKE_TMUX_ANSWER="$T/note.txt" -- move -y --no-attach laptop deltaL-main studio 2>&1); RC=$?
assert_eq "move exits 0"                                  "$RC" "0"
assert_eq "  ...last line: host, session, directory"      "$(printf '%s\n' "$O" | tail -1)" "$(printf 'studio\tdeltaS-main\t%s' "$T/rootR/deltaS")"
assert_contains "  ...the agent was asked for its note"   "$(cat "$SHIM_LOG")" "send-keys -t deltaL-main -l This session is being moved"
assert_eq "  ...studio's clone is on the branch"          "$(git -C "$T/rootR/deltaS" rev-parse --abbrev-ref HEAD)" "feature/d"
assert_eq "  ...at what laptop pushed"                    "$(git -C "$T/rootR/deltaS" rev-parse HEAD)" "$(git -C "$T/root/deltaL" rev-parse HEAD)"
assert_contains "  ...the first prompt says where it came from" "$(cat "$H")" "moved from laptop to studio by fleet. Branch feature/d, last commit: delta work."
assert_contains "  ...and carries the note byte for byte" "$(cat "$H")" "$(cat "$T/note.txt")"
assert_contains "  ...claude there reads it as its first prompt" "$(cat "$SHIM_LOG")" "--remote-control \"\$(cat '$H'; rm -f '$H')\" Enter"
assert_true "  ...the new session is registered on studio" test -e "$RH/.local/state/fleet/sessions/deltaS-main"
assert_eq "  ...the source ends only after the target started" \
  "$(grep -o 'new-session -d -s deltaS-main\|kill-session -t deltaL-main' "$SHIM_LOG" | tr '\n' '|')" "new-session -d -s deltaS-main|kill-session -t deltaL-main|"
assert_false "  ...no pending marker left"                test -e "$T/state/deltaL-main.handoff-pending"

mv_reset; : > "$SHIM_LOG"
O=$(renv "${MV[@]}" -- move -y --no-attach laptop deltaL-main studio 2>&1); RC=$?
assert_eq "no agent in the pane: moves anyway"            "$RC" "0"
assert_lacks "  ...asking nobody"                         "$(cat "$SHIM_LOG")" "This session is being moved"
assert_contains "  ...the first prompt says there is no note" "$(cat "$H")" "there is no handoff note"

mv_reset; : > "$SHIM_LOG"
O=$(renv "${MV[@]}" FAKE_TMUX_COMMAND=claude FLEET_HANDOFF_TIMEOUT=1 -- move -y --no-attach laptop deltaL-main studio 2>&1); RC=$?
assert_eq "no note in time: exit 1"                       "$RC" "1"
assert_lacks "  ...the source is not ended"               "$(cat "$SHIM_LOG")" "kill-session"
assert_eq "  ...the target is untouched"                  "$(git -C "$T/rootR/deltaS" rev-parse --abbrev-ref HEAD)" "main"

mv_reset; : > "$SHIM_LOG"
O=$(renv "${MV[@]}" FAKE_TMUX_COMMAND=claude FAKE_TMUX_ANSWER="$T/note.txt" FAKE_TMUX_ANSWER_RUN="echo oops >> '$T/root/deltaL/d.txt'" -- move -y --no-attach laptop deltaL-main studio 2>&1); RC=$?
assert_contains "the agent changed files while writing the note: not moved" "$O" "uncommitted changes"
assert_eq "  ...exit 1"                                   "$RC" "1"
assert_lacks "  ...the source is not ended"               "$(cat "$SHIM_LOG")" "kill-session"
git -C "$T/root/deltaL" checkout -q -- d.txt

mv_reset
run convert deltaL >/dev/null
run new --local deltaL wt1 >/dev/null
WT="$T/root/deltaL/.claude/worktrees/wt1"
git -C "$WT" commit -q --allow-empty -m "wt1 work"; git -C "$WT" push -q -u origin agent/wt1
O=$(renv "${MV[@]}" -- move -y --no-attach laptop deltaL-wt1 studio 2>&1); RC=$?
assert_eq "a worktree session moves"                      "$RC" "0"
assert_eq "  ...into a worktree on studio, converting its plain clone" \
  "$(printf '%s\n' "$O" | tail -1)" "$(printf 'studio\tdeltaS-wt1\t%s' "$T/rootR/deltaS/.claude/worktrees/wt1")"
assert_eq "  ...on the branch"                            "$(git -C "$T/rootR/deltaS/.claude/worktrees/wt1" rev-parse --abbrev-ref HEAD)" "agent/wt1"
assert_true "  ...the clone is marked converted"          test -e "$T/rootR/deltaS/.git/fleet-worktrees"

# The other direction: a session on studio comes to this Mac (the common case).
git -C "$T/rootR/deltaS" checkout -q feature/d
printf '%s\ndeltaS\n' "$T/rootR/deltaS" > "$RH/.local/state/fleet/sessions/deltaS-main"
git -C "$T/root/deltaL" checkout -q main
rm -f "$T/state/sessions/deltaL-main"
O=$(renv "${MV[@]}" "FAKE_TMUX_SESSIONS=plainR-main deltaS-main" -- move -y --no-attach studio deltaS-main laptop 2>&1); RC=$?
assert_eq "studio to laptop: exit 0"                      "$RC" "0"
assert_eq "  ...laptop's clone is on the branch"          "$(git -C "$T/root/deltaL" rev-parse --abbrev-ref HEAD)" "feature/d"
assert_eq "  ...the new session is laptop's deltaL-main"  "$(printf '%s\n' "$O" | tail -1 | cut -f1,2)" "$(printf 'laptop\tdeltaL-main')"
assert_contains "  ...its first prompt came over stdin"   "$(cat "$T/state/deltaL-main.handoff")" "moved from studio to laptop by fleet"
```

- [ ] **Step 2: Run the tests and confirm they fail.**

Run: `env -u FLEET_TERM test/run.sh 2>&1 | grep -c FAIL`
Expected: a non-zero count, with the Task 5 asserts failing on the usage error.

- [ ] **Step 3: Implement.** After `move_ask`, add:

```bash
# fleet move --local <project> <name> <branch> <worktree> [model]: on the
# target, the first prompt (header and handoff note) on stdin. The checkout
# must end up exactly at origin/<branch>; then the session starts with that
# prompt. Step lines, then the directory as the last line.
move_local() {
  local project="${1:-}" name="${2:-}" branch="${3:-}" worktree="${4:-}" model="${5:-}" session f
  [ -n "$worktree" ] || die "usage: fleet move --local <project> <name> <branch> <worktree> [model]"
  need git; need tmux; need claude
  session=$(session_name "$project" "$name")
  if tmux has-session -t "$session" 2>/dev/null; then die "$session is already running on $FLEET_SELF"; fi
  prepare_checkout "$project" "$name" "$branch" "$worktree" strict
  mkdir -p "$FLEET_STATE"; f="$FLEET_STATE/$session.handoff"
  cat > "$f"
  rm -f "$FLEET_STATE/$session.json"         # an earlier session's state is not this one's
  start_session "$session" "$CHECKOUT_DIR" "$project" "$model" "$f"
  printf '%s  started %s on %s%s\n' "$DIM" "$session" "$FLEET_SELF" "$RESET"
  printf '%s\n' "$CHECKOUT_DIR"
}
```

Replace `cmd_move` with:

```bash
# fleet move [-y] [--no-attach] [--model <m>] <host> <session> [target]
# Refuses unless the work is committed and pushed and the agent is not busy;
# picks among the Macs that can take it (move --targets) unless named; asks
# the agent for a handoff note; checks again; starts the session on the
# target with the note; only then ends it here. Anything failing before that
# leaves the source as it was.
cmd_move() {
  case "${1:-}" in
    --local)   shift; move_local "$@"; return 0 ;;
    --check)   shift; move_check "$@"; return 0 ;;
    --ask)     shift; move_ask "${1:-}"; return 0 ;;
    --targets) shift; move_targets "$@"; return 0 ;;
  esac
  local yes=0 noattach=0 model="" want=0 a rest=()
  for a in "$@"; do
    if [ "$want" = 1 ]; then model="$a"; want=0; continue; fi
    case "$a" in
      -y|--yes) yes=1 ;; --no-attach) noattach=1 ;;
      --model) want=1 ;; --model=*) model="${a#--model=}" ;;
      *) rest+=("$a") ;;
    esac
  done
  [ "$want" = 0 ] || die "--model needs a value (fleet models lists them)"
  set -- ${rest[@]+"${rest[@]}"}
  [ $# -ge 2 ] || die "usage: fleet move [-y] [--no-attach] [--model <m>] <host> <session> [target]"
  local src="$1" sess="$2" target="${3:-}" tj why line ok tproject name branch worktree rec subject note out dir tsess
  tj=$(move_targets_json "$src" "$sess") || exit 1
  why=$(printf '%s' "$tj" | jq -r .why)
  [ -z "$why" ] || die "can't move $sess from $src: $why"
  if [ -z "$target" ]; then
    need fzf
    line=$(printf '%s' "$tj" | jq -r '.targets[] | select(.ok) | [.host, .project] | @tsv')
    [ -n "$line" ] || die "no other Mac can take $sess:$(printf '%s' "$tj" | jq -r '.targets[] | "\n  \(.host): \(.why)"')"
    line=$(printf '%s\n' "$line" | fzf --select-1 --exit-0 --height=40% --reverse --header="move $sess from $src to") || return 1
    [ -n "$line" ] || return 1
    target=$(printf '%s' "$line" | cut -f1)
  fi
  line=$(printf '%s' "$tj" | jq -r --arg t "$target" '.targets[] | select(.host == $t)
           | [(.ok | tostring), (if .project == "" then "-" else .project end), .why] | @tsv')
  [ -n "$line" ] || die "$target is not a Mac to move to (not in the host list, or the session's own)"
  IFS=$'\t' read -r ok tproject why <<< "$line"
  [ "$ok" = true ] || die "$target can't take $sess: $why"
  name=$(printf '%s' "$tj" | jq -r .source.name)
  branch=$(printf '%s' "$tj" | jq -r .source.branch)
  worktree=$(printf '%s' "$tj" | jq -r .source.worktree)
  if [ "$yes" != 1 ]; then
    [ -t 0 ] || die "refusing to move $sess without -y"
    printf 'move %s from %s to %s? the agent writes a handoff note, this session ends, a new one starts there. [y/N] ' "$sess" "$src" "$target"
    read -r a </dev/tty
    case "$a" in y|Y) ;; *) die "left as is" ;; esac
  fi

  printf '%s  asking the agent in %s for a handoff note%s\n' "$DIM" "$sess" "$RESET"
  note=$(run_on "$src" "fleet move --ask $(shq "$sess")") || exit 1
  if [ -n "$note" ]; then printf '%s  got the handoff note%s\n' "$DIM" "$RESET"
  else printf '%s  no agent running in %s, moving without a note%s\n' "$DIM" "$sess" "$RESET"; fi
  # The agent was told not to touch anything; make sure.
  rec=$(record_json "$src" "$sess") || exit 1
  why=$(move_refusal "$rec")
  [ -z "$why" ] || die "not moved: $sess on $src changed while writing the note: $why"
  subject=$(printf '%s' "$rec" | jq -r .subject)
  local header="This session was moved from $src to $target by fleet. Branch $branch, last commit: $subject."
  if [ -n "$note" ]; then
    note="$header The previous agent's handoff:

$note"
  else
    note="$header There was no agent running in it, so there is no handoff note: the branch's recent commits say where the work stands."
  fi

  printf '%s  preparing %s on %s%s\n' "$DIM" "$tproject" "$target" "$RESET"
  out=$(mktemp)
  # shellcheck disable=SC2016  # the single quotes are for the remote shell
  if ! printf '%s\n' "$note" | run_on "$target" "fleet move --local $(shq "$tproject") $(shq "$name") $(shq "$branch") $worktree${model:+ $(shq "$model")}" > "$out"; then
    cat "$out"; rm -f "$out"
    die "not moved: $sess is still on $src, as it was"
  fi
  sed '$d' "$out"; dir=$(tail -n 1 "$out"); rm -f "$out"
  tsess=$(session_name "$tproject" "$name")

  printf '%s  ending %s on %s%s\n' "$DIM" "$sess" "$src" "$RESET"
  run_on "$src" "fleet kill --local $(shq "$sess")" \
    || printf '%s  could not end %s on %s: fleet kill %s %s%s\n' "$YELLOW" "$sess" "$src" "$src" "$sess" "$RESET"
  if [ "$noattach" = 1 ]; then printf '%s\t%s\t%s\n' "$target" "$tsess" "$dir"; return 0; fi
  launch_term "$target" "$tsess" "$dir"
}
```

- [ ] **Step 4: Run the tests and shellcheck.**

Run: `env -u FLEET_TERM test/run.sh 2>&1 | tail -3 && shellcheck fleet test/run.sh test/shims/*`
Expected: `… passed, 0 failed`, and shellcheck prints nothing. If the `--remote-control "$(cat …` assert fails, print `cat "$SHIM_LOG"` and compare the quoting. `shq` of a path without quotes is `'path'`.

- [ ] **Step 5: Smoke-test under Homebrew bash too.** The suite covers `/bin/bash` 3.2. If `/opt/homebrew/bin/bash` exists, run:

`/opt/homebrew/bin/bash -n fleet && XDG_CONFIG_HOME=/nonexistent FLEET_HOSTS=x FLEET_SELF=x /opt/homebrew/bin/bash fleet move 2>&1 | head -1`
Expected: `fleet: usage: fleet move [-y] [--no-attach] [--model <m>] <host> <session> [target]`

- [ ] **Step 6: Commit.**

```bash
git add fleet test/run.sh
git commit -m "fleet move: take a session to another Mac with a handoff note" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01E3UhJCFdxe91W8tPp1WCNJ"
```

---

### Task 6: `docs/demo-fleet` answers move

**Files:**
- Modify: `docs/demo-fleet` (the `case` near line 93)
- Test: `test/run.sh` (the `demo-fleet (the app's stand-in)` section, around line 757)

**Interfaces:**
- Produces: `demo-fleet move --targets <host> <session> --json` follows the Task 3 shape, with made-up hosts: one ok target, one without the repo, one down. `demo-fleet move -y --no-attach <host> <session> <target>` prints four step lines with a short sleep, then `<target>\t<session>\t/Users/you/code/<project>`.

- [ ] **Step 1: Write the failing tests.** In the demo-fleet section of `test/run.sh`, after the `claude rm` cases:

```bash
O=$(PATH="/usr/bin:/bin" "$DEMO" move --targets studio Website-main --json)
assert_eq "demo-fleet move --targets has the CLI's shape" \
  "$(printf '%s' "$O" | jq -r '[(.movable | type == "boolean"), (.source.session == "Website-main"), all(.targets[]; (.ok | type) == "boolean" and (.why | type) == "string")] | all')" "true"
O=$(PATH="/usr/bin:/bin" "$DEMO" move -y --no-attach studio Website-main mbp16)
assert_eq "demo-fleet move ends with host, session, dir" "$(printf '%s\n' "$O" | tail -1 | cut -f1,2)" "$(printf 'mbp16\tWebsite-main')"
```

- [ ] **Step 2: Run the tests and confirm they fail.**

Run: `env -u FLEET_TERM test/run.sh 2>&1 | grep 'demo-fleet move'`
Expected: FAIL (demo-fleet prints nothing for unknown commands).

- [ ] **Step 3: Implement.** In `docs/demo-fleet`, before the `*) : ;;` catch-all:

```bash
  "move --targets") jq -n --arg h "$3" --arg s "$4" '
                     ($s | sub("-[^-]*$"; "")) as $p
                     | {source: {host: $h, session: $s, project: $p, name: "main", branch: "main", worktree: false,
                                 remote: "", subject: "demo"},
                        movable: true, why: "",
                        targets: ([{host: "studio", project: $p, ok: true, why: ""},
                                   {host: "mbp16", project: $p, ok: true, why: ""},
                                   {host: "mini", project: "", ok: false, why: "no clone of this repo under FLEET_ROOT"},
                                   {host: "air", project: "", ok: false, why: "offline according to Tailscale"}]
                                  | map(select(.host != $h)))}' ;;
  "move -y")       sess="$5"; target="$6"; proj="${sess%-*}"
                   for step in "asking the agent in $sess for a handoff note" "got the handoff note" \
                               "preparing $proj on $target" "ending $sess on $4"; do
                     sleep 1; printf '  %s\n' "$step"
                   done
                   printf '%s\t%s\t/Users/you/code/%s\n' "$target" "$proj-main" "$proj" ;;
```

(`move -y --no-attach <host> <session> <target>`: `$3` is `--no-attach`, `$4` host, `$5` session, `$6` target.)

- [ ] **Step 4: Run the tests.**

Run: `env -u FLEET_TERM test/run.sh 2>&1 | tail -1 && shellcheck docs/demo-fleet`
Expected: `0 failed`, and shellcheck prints nothing.

- [ ] **Step 5: Commit.**

```bash
git add docs/demo-fleet test/run.sh
git commit -m "demo-fleet: answer move --targets and move" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01E3UhJCFdxe91W8tPp1WCNJ"
```

---

### Task 7: Mac app: Move menu, context menu, confirmation

**Files:**
- Modify: `app/Shared/Models.swift` (after `Session`'s helpers)
- Modify: `app/Fleet/Fleet.swift` (in `FleetCLI`, after `kill`)
- Modify: `app/Fleet/Model.swift` (published state next to `busy` and `confirmEnd`)
- Modify: `app/Fleet/ModelActions.swift` (after `endSession`)
- Modify: `app/Fleet/SessionView.swift` (the action row, before `Spacer()`; a `.task` on the view)
- Modify: `app/Fleet/ContentView.swift` (`SessionMenu`; a second `.confirmationDialog`)

**Interfaces:**
- Consumes: `fleet move --targets <host> <session> --json` and `fleet move -y --no-attach <host> <session> <target>` (Tasks 3 and 5).
- Produces:
  - `MoveTargets`, `MoveTargets.Target`
  - `Session.moveBlocker: String?`
  - `FleetCLI.moveTargets(host:session:)`, `FleetCLI.move(host:session:to:progress:)`
  - `FleetModel.moveTargets: [String: MoveTargets]`, `FleetModel.confirmMove: PendingMove?`, `FleetModel.loadMoveTargets(_:)`, `FleetModel.moveSession(_:to:)`

- [ ] **Step 1: Models.** In `app/Shared/Models.swift`, after the `Session` extension that holds `badge` (or at the end of `Session`'s helpers), add:

```swift
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
        if state == "blocked" { return "The agent is waiting on you; answer it first" }
        if branch == "(detached)" { return "Detached HEAD: there is no branch to move" }
        if dirty { return "Uncommitted changes; commit and push them first" }
        if upstream.isEmpty { return "\(branch) was never pushed" }
        if ahead > 0 { return "\(ahead) commit\(ahead == 1 ? "" : "s") not pushed" }
        return nil
    }
}
```

- [ ] **Step 2: CLI bridge.** In `FleetCLI` (`app/Fleet/Fleet.swift`), after `kill`:

```swift
    /// `fleet move --targets <host> <session> --json`.
    static func moveTargets(host: String, session: String) async throws -> MoveTargets {
        try await decode(MoveTargets.self, from: run(["move", "--targets", host, session, "--json"], timeout: pollTimeout))
    }
    /// `fleet move -y --no-attach` (the app has asked already): the agent
    /// writes its note (up to FLEET_HANDOFF_TIMEOUT, 180s by default), the
    /// target starts the session, the source ends. Returns (host, session,
    /// dir) of the new session. fleet prints its steps as it goes.
    static func move(host: String, session: String, to target: String,
                     progress: @escaping @Sendable (String) -> Void) async throws -> (String, String, String) {
        let out = try await runStreaming(["move", "-y", "--no-attach", host, session, target], timeout: 600, onLine: progress)
        let parts = (out.split(separator: "\n").last ?? "").split(separator: "\t").map(String.init)
        guard parts.count == 3 else { throw FleetError.failed(command: "fleet move", status: 1, stderr: "unexpected output") }
        return (parts[0], parts[1], parts[2])
    }
```

- [ ] **Step 3: Model state.** In `app/Fleet/Model.swift`, add next to `confirmEnd`:

```swift
    @Published var moveTargets: [String: MoveTargets] = [:]   // session id -> fleet move --targets
    @Published var confirmMove: PendingMove?                 // the Move dialog is up for this
```

and at file scope (next to the other small types there):

```swift
/// A move the owner picked from a Move menu, waiting on the confirmation.
struct PendingMove: Identifiable {
    let session: Session
    let target: String
    var id: String { session.id + "→" + target }
}
```

- [ ] **Step 4: Actions.** In `app/Fleet/ModelActions.swift`, after `endSession`:

```swift
    /// Which Macs can take a session; the Move menus show the answer.
    func loadMoveTargets(_ s: Session) {
        let id = s.id
        Task {
            do { moveTargets[id] = try await FleetCLI.moveTargets(host: s.host, session: s.session) }
            catch { moveTargets[id] = nil; actionError = "move targets for \(s.title): \(Self.reason(error))" }
        }
    }
    /// After the confirmation: fleet asks the agent for its handoff note,
    /// starts the session on the target with it, then ends this one. The
    /// steps show in the busy row; the new session is selected and attached.
    func moveSession(_ s: Session, to target: String) {
        let id = s.id, t = Terminal.preferred
        actionError = nil
        busy[id] = "Asking the agent for a handoff note…"
        Task {
            do {
                let (h, sess, _) = try await FleetCLI.move(host: s.host, session: s.session, to: target) { line in
                    Task { @MainActor in self.busy[id] = line }
                }
                busy[id] = nil
                moveTargets[id] = nil
                selected = .session("\(h)/\(sess)")
                refresh()
                try await FleetCLI.attach(host: h, session: sess, terminal: t)
            } catch { actionError = "move \(s.title) to \(target): \(Self.reason(error))" }
            busy[id] = nil
            refresh()
        }
    }
```

- [ ] **Step 5: The Move button.** In `app/Fleet/SessionView.swift`, directly before `Spacer()` in the action row:

```swift
                Menu {
                    if let mt = model.moveTargets[session.id] {
                        ForEach(mt.targets) { t in
                            Button(t.ok ? t.host : "\(t.host): \(t.why)") {
                                model.confirmMove = PendingMove(session: session, target: t.host)
                            }
                            .disabled(!t.ok)
                        }
                    } else {
                        Text("Finding Macs that have this repo…")
                    }
                } label: {
                    VStack(spacing: 5) {   // same shape as the GitHub menu
                        Image(systemName: "arrow.right.circle").font(.title2).frame(height: 24)
                        HStack(spacing: 3) {
                            Text("Move")
                            Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.85)
                        }.font(.caption.weight(.semibold))
                    }
                }
                .menuStyle(.button).buttonStyle(FilledStyle(tint: .teal)).menuIndicator(.hidden)
                .disabled(session.moveBlocker != nil || model.busy[session.id] != nil
                          || model.moveTargets[session.id]?.targets.contains(where: \.ok) == false)
                .help(moveHelp)
```

and add to `SessionView`, next to its other helpers (or after `body`):

```swift
    /// The Move button's tooltip: why it is disabled, else what it does.
    private var moveHelp: String {
        if let b = session.moveBlocker { return b }
        if let mt = model.moveTargets[session.id], !mt.targets.contains(where: \.ok) {
            return "No other Mac can take this session: " + mt.targets.map { "\($0.host): \($0.why)" }.joined(separator: "; ")
        }
        return "Move this session to another Mac: the agent writes a handoff note, this session ends, and a new one starts there with the note"
    }
```

On the view's outermost container in `SessionView.body` (where the other modifiers sit), add:

```swift
        .task(id: "\(session.id)|\(session.moveBlocker ?? "")") {
            if session.moveBlocker == nil { model.loadMoveTargets(session) }
        }
```

- [ ] **Step 6: Context menu and confirmation.** In `SessionMenu` (`app/Fleet/ContentView.swift`), before the `Divider()`:

```swift
        if let mt = model.moveTargets[session.id], session.moveBlocker == nil {
            Menu("Move To") {
                ForEach(mt.targets) { t in
                    Button(t.ok ? t.host : "\(t.host): \(t.why)") { model.confirmMove = PendingMove(session: session, target: t.host) }
                        .disabled(!t.ok)
                }
            }
        } else {
            Button("Move To…") { model.selected = .session(session.id) }   // its screen loads the targets
                .disabled(session.moveBlocker != nil)
        }
```

After the End-session `.confirmationDialog(…)` block in `ContentView.body`, add:

```swift
        .confirmationDialog(
            "Move \(model.confirmMove?.session.title ?? "") to \(model.confirmMove?.target ?? "")?",
            isPresented: Binding(get: { model.confirmMove != nil }, set: { if !$0 { model.confirmMove = nil } }),
            presenting: model.confirmMove
        ) { m in
            Button("Move Session") { model.moveSession(m.session, to: m.target) }
        } message: { m in
            Text("The agent writes a handoff note, this session on \(m.session.host) ends, and a new one starts on \(m.target) with the note, on \(m.session.branch) as pushed.")
        }
```

- [ ] **Step 7: Build both apps.**

Run: `xcodebuild -project app/Fleet.xcodeproj -scheme Fleet -derivedDataPath app/.build build 2>&1 | tail -3 && xcodebuild -project app/Fleet.xcodeproj -scheme FleetMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath app/.build build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **` twice.

- [ ] **Step 8: Try it with the stand-in.**

Run: `FLEET_BIN="$PWD/docs/demo-fleet" FLEET_SELECT=studio/Website-main app/.build/Build/Products/Debug/Fleet.app/Contents/MacOS/Fleet &`
Check:
- The Move menu lists mbp16 (enabled), and mini and air (disabled, with reasons). If the demo's sessions don't include `Website-main` on studio, pick any session `ls --json` lists and adjust `FLEET_SELECT`.
- Choosing mbp16 asks to confirm, then the busy row shows the four steps.
- A session whose `state` is `running` in the demo shows Move disabled with the "agent is working" help.

Take a screenshot (`screencapture -l` or ⌘⇧4), check it, then quit the app.

- [ ] **Step 9: Commit.**

```bash
git add app/Shared/Models.swift app/Fleet/Fleet.swift app/Fleet/Model.swift app/Fleet/ModelActions.swift app/Fleet/SessionView.swift app/Fleet/ContentView.swift
git commit -m "Mac app: Move a session to another Mac" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01E3UhJCFdxe91W8tPp1WCNJ"
```

---

### Task 8: Docs

**Files:**
- Modify: `CLAUDE.md`, `README.md`, `SECURITY.md`, `docs/superpowers/specs/2026-09-24-session-move-design.md` (Status line)

- [ ] **Step 1: CLAUDE.md.** Make these edits:

1. In the config list under Constraints, after `FLEET_CMD_TIMEOUT (10, whole remote status),`, insert `FLEET_HANDOFF_TIMEOUT (180, move's wait for the note),`.
2. In "Commands:", add `move|mv` after `kill|stop`.
3. After the `kill [-y] <host> <session>` sentence group (ending "Only sessions `fleet status` lists can be killed."), add:

```
  `move [-y] [--no-attach] [--model m] <host> <session> [target]` moves a
  fleet session to another Mac (spec
  `docs/superpowers/specs/2026-09-24-session-move-design.md`). It is refused
  while `running`/`blocked`, dirty, never pushed or ahead (`move_refusal`,
  mirrored by the app's `Session.moveBlocker`). Targets are the other hosts
  with a clone of the same repo (the project of that name when its origin is
  the same repo, else `project_for_remote`) that can take it: `move --check`
  there, fanned out through `host_fetch`, answers `{ok, project, why}`;
  `move --targets [--json]` shows them. Then `move --ask` on the source
  types `HANDOFF_PROMPT` into the pane and waits up to FLEET_HANDOFF_TIMEOUT
  for a `done` whose state file has `handoff` (the hook writes it only while
  `<session>.handoff-pending` exists); no agent in the pane = no note. The
  record is checked again, then `move --local` on the target gets header +
  note on stdin: `prepare_checkout … strict` (shared with `open`, which only
  warns), the note into `<session>.handoff`, and `start_session` (shared
  with `new`) types `claude … "$(cat f; rm -f f)"`. Only after that does
  `kill --local` end the source; then it attaches like `new`.
```

4. Under "Load-bearing interfaces", after the `fleet ls` bullet, add:

```
- `fleet move --targets <host> <session> --json` (the Mac app's Move menu):
  `{source: {host, session, project, name, branch, worktree, remote,
  subject}, movable, why, targets: [{host, project, ok, why}]}`; a down
  host is a target with `ok: false` and its down reason. `fleet move -y
  --no-attach …` ends with `<host>\t<session>\t<dir>` like `new`.
```

5. In the hook state contract bullet, after the sentence about `prompt`, `note` and `said`, add: `While `$FLEET_STATE/<session>.handoff-pending` exists (fleet move waiting for a note), done also stores the whole `last_assistant_message` as `handoff` (newlines kept, 20000 max); the record never carries it.`
6. In "The apps" section, after the paragraph on the End button (`A session's End button (and menu items) confirm, then `fleet kill -y`.`), add:

```
  A session's Move menu (and "Move To" in its context menu) lists `fleet
  move --targets` for it, loaded when its screen shows and when its
  movability changes; it is disabled with the reason when
  `Session.moveBlocker` says so or no Mac qualifies. Picking a Mac confirms,
  then `FleetModel.moveSession` streams `fleet move -y --no-attach` into
  the busy row, selects the new session and attaches it. The context menu
  without loaded targets offers "Move To…", which selects the session.
  Not on iOS: a move needs one Mac to drive two others.
```

- [ ] **Step 2: README.md.** In the command list near line 15, after the `fleet kill` line, add:

```
fleet move [host session [target]]    move a session to another Mac with a handoff note (pushed work only)
```

After the "## Opening a checkout" section (before "### If you use Xcode" belongs to it, so after that subsection, before "## Verify"), add:

```markdown
## Moving a session

`fleet move <host> <session> [target]` hands a session to another Mac, for
when you started an agent on the desktop and are leaving with the laptop.
It only moves work that is committed and pushed, and only while the agent
is not working or waiting on you. The Macs offered are the ones with a
clone of the same repo (under any folder name) that can switch to the
branch. The agent writes a handoff note (goal, what is done, what is
next, open questions); the target checks out the branch at what was
pushed and starts a new session whose first prompt is that note; only then
does the old session end. `fleet move --targets <host> <session>` shows
which Macs qualify and why the others do not. In the Mac app it is the
Move button on a session.
```

- [ ] **Step 3: SECURITY.md.** In "## What fleet does", add a paragraph:

```markdown
`fleet move` carries one piece of agent-written text between Macs: the
handoff note. It travels as the stdin of the ssh command that starts the
session on the target, is written to `~/.local/state/fleet/<session>.handoff`
there, and reaches claude as a double-quoted argument (`"$(cat file)"`),
which the shell does not evaluate further; the file is removed as it is
read. Nothing new is executed and no new ssh direction exists: the machine
you run `fleet move` on talks to the source and the target, as `open` and
`kill` already do.
```

- [ ] **Step 4: Spec status.** In the spec, change `Status: design approved in conversation, awaiting spec review.` to `Status: implemented.`

- [ ] **Step 5: Check the docs against the code.**

Run: `grep -n 'handoff\|move' CLAUDE.md | head -20; env -u FLEET_TERM test/run.sh 2>&1 | tail -1; git diff --stat`
Expected: `0 failed`. Also check that every function name the docs mention exists: `grep -c 'move_refusal\|start_session\|prepare_checkout\|move_check\|move_ask\|move_local' fleet` should give a count above 6.

- [ ] **Step 6: Commit.**

```bash
git add CLAUDE.md README.md SECURITY.md docs/superpowers/specs/2026-09-24-session-move-design.md
git commit -m "Docs: fleet move" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01E3UhJCFdxe91W8tPp1WCNJ"
```
