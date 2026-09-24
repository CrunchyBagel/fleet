#!/bin/bash
#
# fleet test suite. Builds throwaway repos in a temp dir, runs `fleet` under
# /bin/bash (stock macOS 3.2) against them with stand-ins for ssh, tmux,
# claude, fzf, open and xed on PATH, and asserts on the output.
#
#   test/run.sh            run everything
#   test/run.sh -v         also print each passing assertion
#
# Two fake hosts: "laptop" is this machine (FLEET_SELF); "studio" is reached
# through the fake ssh, which runs the same fleet script with its own HOME,
# config and FLEET_ROOT. "dead", "nofleet", "slow" and "fresh" fail in specific ways.
# Needs: git, jq, expect (all on stock macOS or already required by fleet).

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
FLEET="$HERE/../fleet"
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1

T=$(mktemp -d); export T
TR=$(cd "$T" && pwd -P)          # git prints resolved paths (/private/var/...), $T may be the /var symlink
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); [ "$VERBOSE" = 1 ] && printf '  ok   %s\n' "$1"; return 0; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }
assert_eq()       { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }
assert_contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing [$3] in: $(printf '%s' "$2" | head -c 300)" ;; esac; }
assert_lacks()    { case "$2" in *"$3"*) fail "$1" "unexpected [$3]" ;; *) pass "$1" ;; esac; }
assert_true()     { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d" "$*"; fi; }
assert_false()    { local d="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$d" "expected failure: $*"; else pass "$d"; fi; }
section() { printf '\n%s\n' "$1"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset TMUX   # run from inside tmux, attach would switch-client instead of new-session

# ---------------------------------------------------------------- fixtures

# make_origin <name> <default-branch>: a bare origin with one commit.
make_origin() {
  git init -q --bare -b "$2" "$T/origins/$1.git"
  local w; w=$(mktemp -d)
  git -C "$w" init -q -b "$2"; echo hi > "$w/f"; git -C "$w" add f; git -C "$w" commit -qm "initial $1"
  git -C "$w" remote add origin "$T/origins/$1.git"; git -C "$w" push -q origin "$2"; rm -rf "$w"
}

# build_root <dir>: the laptop's FLEET_ROOT, covering every layout and git edge.
build_root() {
  local R="$1"; mkdir -p "$R"
  # alpha: container layout (<project>/main + sibling worktrees), lots of git states
  git clone -q "$T/origins/alpha.git" "$R/alpha/main"; local M="$R/alpha/main"
  git -C "$M" worktree add -q -b agent/feat "$R/alpha/feat"
  git -C "$R/alpha/feat" commit -q --allow-empty -m "feat work"; git -C "$R/alpha/feat" push -q -u origin agent/feat
  git -C "$R/alpha/feat" commit -q --allow-empty -m "feat work 2"                       # ahead 1
  git -C "$M" worktree add -q -b agent/nopush "$R/alpha/nopush"                        # no upstream
  git -C "$M" worktree add -q -b agent/gone "$R/alpha/gone"
  git -C "$R/alpha/gone" commit -q --allow-empty -m "gone"; git -C "$R/alpha/gone" push -q -u origin agent/gone
  git -C "$M" push -q origin --delete agent/gone; git -C "$M" fetch -q --prune            # upstream pruned
  git -C "$M" worktree add -q --detach "$R/alpha/det"                                  # detached HEAD
  git -C "$M" worktree add -q -b agent/fresh "$R/alpha/fresh"
  echo "hours of uncommitted agent work" > "$R/alpha/fresh/important.swift"            # unstarted + dirty
  git -C "$M" worktree add -q -b agent/merged "$R/alpha/merged"
  git -C "$R/alpha/merged" commit -q --allow-empty -m "merged work"
  git -C "$M" merge -q --no-ff agent/merged -m "merge agent/merged"; git -C "$M" push -q origin main
  git -C "$M" worktree add -q -b agent/zombie "$R/alpha/zombie"; rm -rf "$R/alpha/zombie"  # registered, dir gone
  # plain clones
  git clone -q "$T/origins/alpha.git" "$R/plain"; echo "# notes" > "$R/plain/CLAUDE.md"
  git clone -q "$T/origins/alpha.git" "$R/plainB"; mkdir -p "$R/plainB/.claude/worktrees"  # Claude Code's own dir, NOT converted
  mkdir -p "$R/plainB/PlainB.xcodeproj"
  # legacy: default branch master, so origin/main does not exist
  git clone -q "$T/origins/legacy.git" "$R/legacy/main"
  git -C "$R/legacy/main" worktree add -q -b agent/old "$R/legacy/old"
  # noremote: a repo with no origin at all
  git init -q -b main "$R/noremote"; echo x > "$R/noremote/x"; git -C "$R/noremote" add x; git -C "$R/noremote" commit -qm x
  # non-repos
  mkdir -p "$R/justdir" "$R/nomain/task"
}

make_origin alpha main
make_origin legacy master
make_origin gamma main
build_root "$T/root"
mkdir -p "$T/root with space"; build_root "$T/root with space"

# The fake remote "studio": its own HOME, config, root, and fleet on ~/bin.
RH="$T/rhome"; export FLEET_TEST_RHOME="$RH"
mkdir -p "$RH/bin" "$RH/.config/fleet" "$RH/.local/state/fleet/sessions" "$T/rootR/plainR"
ln -s "$FLEET" "$RH/bin/fleet"; cp "$HERE/shims/tmux" "$HERE/shims/claude" "$RH/bin/"
git clone -q "$T/origins/alpha.git" "$T/rootR/plainR"
git -C "$T/rootR/plainR" checkout -q -b feature/x; echo work > "$T/rootR/plainR/work.txt"
git -C "$T/rootR/plainR" add -A; git -C "$T/rootR/plainR" commit -qm "remote work"; git -C "$T/rootR/plainR" push -q -u origin feature/x
printf 'FLEET_HOSTS="laptop studio"\nFLEET_SELF="studio"\nFLEET_ROOT="%s"\nFLEET_STATE="%s"\n' "$T/rootR" "$RH/.local/state/fleet" > "$RH/.config/fleet/config"
printf '%s\nplainR\n' "$T/rootR/plainR" > "$RH/.local/state/fleet/sessions/plainR-main"   # a session running there
git clone -q "$T/origins/alpha.git" "$T/root/plainR"                                     # laptop has the same project, on main
# The same repo under different directory names: rowingR on studio, simulatorL here.
git clone -q "$T/origins/gamma.git" "$T/rootR/rowingR"
git -C "$T/rootR/rowingR" checkout -q -b feature/oars; echo oars > "$T/rootR/rowingR/oars.txt"
git -C "$T/rootR/rowingR" add -A; git -C "$T/rootR/rowingR" commit -qm "oars"; git -C "$T/rootR/rowingR" push -q -u origin feature/oars
printf '%s\nrowingR\n' "$T/rootR/rowingR" > "$RH/.local/state/fleet/sessions/rowingR-main"
git clone -q "$T/origins/gamma.git" "$T/root/simulatorL"

mkdir -p "$T/noconf" "$T/home" "$T/state"
export SHIM_LOG="$T/shim.log"
# Environment every fleet invocation runs with. FLEET_PATH puts the shims first
# here and on the fake remote ($HOME/bin there is where its fleet/tmux live).
FENV=(XDG_CONFIG_HOME="$T/noconf" HOME="$T/home" PATH="$HERE/shims:/usr/bin:/bin" FLEET_PATH="$HERE/shims:\$HOME/bin"
      FLEET_ROOT="$T/root" FLEET_STATE="$T/state" FLEET_SELF=laptop FLEET_HOSTS="laptop" SHIM_LOG="$SHIM_LOG"
      FLEET_SSH_TIMEOUT=2 FLEET_CMD_TIMEOUT=2 FLEET_NO_SPINNER=1 FAKE_TMUX_SESSIONS=plainR-main)
run()  { env "${FENV[@]}" /bin/bash "$FLEET" "$@"; }
renv() { local extra=(); while [ "$1" != "--" ]; do extra+=("$1"); shift; done; shift; env "${FENV[@]}" ${extra[@]+"${extra[@]}"} /bin/bash "$FLEET" "$@"; }

# ---------------------------------------------------------------- status

section "status"
J=$(run status --json --all)
assert_eq "status is a JSON array" "$(printf '%s' "$J" | jq -r 'type')" "array"
assert_eq "record schema" \
  "$(printf '%s' "$J" | jq -r '.[0] | keys | join(",")')" \
  "activity,ahead,attached_from,behind,branch,claude_session,context_pct,cost_usd,dirty,host,limit_5h,limit_5h_reset,limit_7d,limit_7d_reset,managed,model,name,note,path,project,prompt,remote,said,session,state,stats_ts,subject,ts,upstream,worktree"
assert_eq "container layout: primary is 'main'"   "$(printf '%s' "$J" | jq -r '.[] | select(.project=="alpha" and (.path|endswith("/alpha/main"))) | .name')" "main"
assert_eq "feat ahead 1 of its upstream"          "$(printf '%s' "$J" | jq -r '.[] | select(.name=="feat") | "\(.ahead) \(.behind) \(.upstream)"')" "1 0 origin/agent/feat"
assert_eq "never pushed: upstream empty"          "$(printf '%s' "$J" | jq -r '.[] | select(.name=="nopush") | .upstream')" ""
assert_eq "pruned upstream reads as none"         "$(printf '%s' "$J" | jq -r '.[] | select(.name=="gone") | .upstream')" ""
assert_eq "detached worktree reported"            "$(printf '%s' "$J" | jq -r '.[] | select(.name=="det") | .branch')" "(detached)"
assert_eq "dirty flag"                            "$(printf '%s' "$J" | jq -r '.[] | select(.name=="fresh") | .dirty')" "true"
assert_eq "deleted worktree dir is skipped"       "$(printf '%s' "$J" | jq -r '[.[] | select(.name=="zombie")] | length')" "0"
assert_eq "plain clone is one 'main' row"         "$(printf '%s' "$J" | jq -r '[.[] | select(.project=="plain")] | map(.name) | join(",")')" "main"
assert_eq "plain row is not a worktree"           "$(printf '%s' "$J" | jq -r '.[] | select(.project=="plain") | .worktree')" "false"
assert_eq "non-repos are not projects"            "$(printf '%s' "$J" | jq -r '[.[] | select(.project=="justdir" or .project=="nomain")] | length')" "0"
assert_eq "legacy (master) still enumerates"      "$(printf '%s' "$J" | jq -r '[.[] | select(.project=="legacy")] | length')" "2"
J2=$(renv FLEET_ROOT="$T/root with space" -- status --json --all)
assert_eq "paths with spaces: right count"        "$(printf '%s' "$J2" | jq -r '[.[] | select(.project=="alpha")] | length')" "$(printf '%s' "$J" | jq -r '[.[] | select(.project=="alpha")] | length')"
assert_true "paths with spaces: paths intact"     printf '%s' "$J2" | jq -e 'all(.path | startswith("'"$T/root with space"'"))'
assert_eq "status --json with nothing registered is []" "$(run status --json)" "[]"
assert_contains "status without --json is the table"    "$(run status)" "no fleet sessions on laptop"

# ---------------------------------------------------------------- layouts, new, convert

section "layouts and new"
assert_eq "projects layout column" "alpha:worktrees justdir:dir plain:plain plainB:plain " "$(run projects --local | awk -F'\t' '$1=="plain"||$1=="alpha"||$1=="plainB"||$1=="justdir"{print $1":"$2}' | sort | tr '\n' ' ')"
assert_eq "projects ranks Claude-used first" "$(run projects --local | head -1 | cut -f1)" "plain"
assert_contains "projects --json shape" "$(run projects --json)" '"project":"plain","layout":"plain","claude":true'
: > "$SHIM_LOG"
D=$(run new --local plain)
assert_eq "new --local plain: runs in the repo"            "$D" "$T/root/plain"
assert_contains "new types claude with name, auto mode, remote control" "$(cat "$SHIM_LOG")" "send-keys -t plain-main claude -n 'laptop-plain-main' --permission-mode auto --remote-control"
assert_true "registers the session"                         test -e "$T/state/sessions/plain-main"
assert_eq "registry records dir and project"                "$(cat "$T/state/sessions/plain-main" | tr '\n' ' ')" "$T/root/plain plain "
D=$(run new --local plain review)
assert_eq "plain + name: second session, same repo"        "$D" "$T/root/plain"
assert_true "plain-review registered"                       test -e "$T/state/sessions/plain-review"
assert_eq "plainB with Claude's own .claude/worktrees is still plain" "$(run projects --local | awk -F'\t' '$1=="plainB"{print $2}')" "plain"
run convert plainB >/dev/null
assert_eq "convert marks worktrees layout"                  "$(run projects --local | awk -F'\t' '$1=="plainB"{print $2}')" "worktrees"
assert_true "convert excludes .claude/worktrees from git status" grep -qx '.claude/worktrees/' "$T/root/plainB/.git/info/exclude"
D=$(run new --local plainB t1)
assert_eq "converted + task: worktree under .claude/worktrees" "$D" "$T/root/plainB/.claude/worktrees/t1"
assert_eq "worktree is on agent/<task>"                     "$(git -C "$D" rev-parse --abbrev-ref HEAD)" "agent/t1"
assert_eq "worktree branched from origin's default branch"  "$(git -C "$D" rev-parse HEAD)" "$(git -C "$T/root/plainB" rev-parse origin/main)"
assert_eq "clone's git status stays clean"                  "$(git -C "$T/root/plainB" status --porcelain)" ""
assert_eq "same task again reuses the worktree"             "$(run new --local plainB t1)" "$D"
assert_contains "new refuses a non-repo"                    "$(run new --local justdir 2>&1)" "no clone"
assert_lacks    "projects hides folders that are not repos" "$(run projects)" "justdir"
assert_contains "projects --all shows them"                 "$(run projects --all)" "justdir"
assert_eq "projects --json hides them too"                  "$(run projects --json | jq -r '[.projects[] | select(.layout=="dir")] | length')" "0"
D=$(run new --local justdir --init)
assert_eq "new --local --init makes a folder a repo and starts there" "$D" "$T/root/justdir"
assert_true "the folder is now a git repo"                  test -e "$T/root/justdir/.git"
assert_contains "and shows by default from then on"         "$(run projects)" "justdir"
assert_contains "status without --json is the table"        "$(renv "FAKE_TMUX_SESSIONS=plainR-main plain-main plain-review plainB-t1" -- status --all)" "alpha"

# ---------------------------------------------------------------- registry, ls

section "ls and the session registry"
ALIVE="FAKE_TMUX_SESSIONS=plainR-main plain-main plain-review plainB-t1"
L=$(renv "$ALIVE" -- ls)
assert_contains "ls lists registered plain sessions"  "$L" "review"
assert_contains "ls lists registered worktree session" "$L" "t1"
assert_lacks    "ls hides unregistered worktrees"      "$L" "feat"
assert_eq "status --json only visits registered projects" "$(renv "$ALIVE" -- status --json | jq -r '[.[].project] | unique | join(",")')" "plain,plainB"
L=$(renv "FAKE_TMUX_SESSIONS=plainR-main plainB-t1" -- ls)
assert_lacks "plain session forgotten when its tmux is gone" "$L" "review"
assert_false "registry entry removed" test -e "$T/state/sessions/plain-review"
assert_contains "worktree session stays without tmux"  "$L" "t1"
assert_contains "ls --all shows unmanaged rows"        "$(run ls --all)" "feat"
assert_contains "empty ls says so and hints"           "$(renv FLEET_STATE="$T/emptystate" -- ls)" "start one:  fleet new"
mkdir -p "$T/state"; echo '{"state":"blocked","ts":1}' > "$T/state/plainB-t1.json"
assert_contains "hook state file drives the badge"     "$(run ls)" "needs you"
run new --local plain >/dev/null           # re-register plain-main (forgotten above when its tmux was "gone")
assert_contains "ls badge for tmux-only session"       "$(renv "FAKE_TMUX_SESSIONS=plainR-main plain-main" -- ls)" "◦ alive"
assert_contains "ls: time column for a state file is its ts" "$(run ls)" "ago"
rm -f "$T/state/plainB-t1.json"

# ---------------------------------------------------------------- fan-out, hosts

section "fan-out and hosts"
L=$(renv FLEET_HOSTS="laptop studio dead nofleet slow" -- ls --all)
assert_contains "remote rows arrive over the fake ssh"  "$L" "studio"
assert_contains "dead host: ssh failed"                 "$L" "dead: ssh failed"
assert_contains "host without fleet says so"            "$L" "nofleet: fleet not installed (fleet install nofleet)"
assert_contains "hung host is cut off at the timeout"   "$L" "slow: no answer in 2s"
assert_contains "a host Tailscale says is offline is skipped without ssh" "$(renv FLEET_HOSTS="laptop asleep" -- ls --all)" "asleep: offline according to Tailscale"
T0=$(date +%s); L=$(renv FAKE_TAILSCALE=hang FLEET_HOSTS="laptop studio" -- ls --all); T1=$(date +%s)
assert_contains "a hung tailscale CLI does not stop the fan-out"  "$L" "studio"
assert_true     "a hung tailscale CLI is cut off at FLEET_SSH_TIMEOUT" [ $((T1 - T0)) -lt 8 ]
assert_eq       "FLEET_SELF falls back to the hostname when tailscale hangs" \
  "$(FLEET_SELF= T0=$(date +%s); renv FAKE_TAILSCALE=hang FLEET_SELF= -- status --json >/dev/null; echo $(( $(date +%s) - T0 < 8 )))" "1"
assert_contains "ls <host> restricts the fan-out"       "$(renv FLEET_HOSTS="laptop studio" -- ls --all studio | grep -c 'studio' | sed 's/^/n=/')" "n="
assert_lacks    "ls <host> restricts the fan-out (no laptop rows)" "$(renv FLEET_HOSTS="laptop studio" -- ls --all studio)" " laptop "
assert_contains "ls rejects an unknown host"            "$(renv FLEET_HOSTS="laptop" -- ls nosuch 2>&1)" "unknown host"
assert_eq "ls --all --json is the unfiltered merge"     "$(renv FLEET_HOSTS="laptop studio" -- ls --all --json | jq -r '[.[].host] | unique | join(",")')" "laptop,studio"
mkdir -p "$T/home/.config/fleet"; printf 'laptop\n' > "$T/home/.config/fleet/hosts"
HENV=(XDG_CONFIG_HOME="$T/home/.config" FLEET_HOSTS=)
O=$(renv "${HENV[@]}" -- hosts add studio 2>&1)
assert_contains "hosts add pushes to the new host"     "$O" "hosts -> studio"
assert_eq "hosts file updated locally"                  "$(grep -v '^#' "$T/home/.config/fleet/hosts" | tr '\n' ' ')" "laptop studio "
assert_eq "hosts file pushed to the remote"             "$(cat "$RH/.config/fleet/hosts")" "$(cat "$T/home/.config/fleet/hosts")"
O=$(renv "${HENV[@]}" -- hosts add dead 2>&1)
assert_contains "unreachable host reported with fix"    "$O" "when dead is back: fleet hosts push dead"
renv "${HENV[@]}" -- hosts rm dead >/dev/null 2>&1
assert_lacks "hosts rm removes it"                      "$(cat "$T/home/.config/fleet/hosts")" "dead"
assert_contains "hosts info --json shape"               "$(renv FLEET_HOSTS="laptop nofleet" -- hosts info --json)" '"down":[{"host":"nofleet"'
assert_eq "hosts info --json has this machine"          "$(renv FLEET_HOSTS="laptop" -- hosts info --json | jq -r '.hosts[0].host')" "laptop"
assert_eq "hosts info --json marks self"                "$(renv FLEET_HOSTS="laptop" -- hosts info --json | jq -r '.hosts[0].self')" "true"
assert_eq "hosts info --json names the model"           "$(renv FLEET_HOSTS="laptop" -- hosts info --json | jq -r '.hosts[0].model_name | type')" "string"
assert_eq "hosts info --json carries the LAN name, ip and link"  "$(renv FLEET_HOSTS="laptop" -- hosts info --json | jq -r '.hosts[0] | [.lan_name, .lan_ip, .lan_link] | map(type) | join(",")')" "string,string,string"
LN=$(renv FLEET_HOSTS="laptop" -- hosts info --json | jq -r '.hosts[0].lan_name'); LL=$(renv FLEET_HOSTS="laptop" -- hosts info --json | jq -r '.hosts[0].lan_link')
assert_true "hosts info --json lan_name is a Bonjour name or empty" [ -z "$LN" -o "${LN%.local}" != "$LN" ]
assert_true "hosts info --json lan_link is ethernet, wifi or empty" [ "$LL" = ethernet -o "$LL" = wifi -o -z "$LL" ]
assert_eq "hosts info <host> --json asks only that host"  "$(renv FLEET_HOSTS="laptop nofleet" -- hosts info laptop --json | jq -c '[.hosts[].host, .down]')" '["laptop",[]]'
assert_contains "hosts info <unknown> dies"               "$(renv FLEET_HOSTS="laptop" -- hosts info nope --json 2>&1)" "unknown host 'nope'"
assert_eq "status records carry the origin URL"         "$(run status --json --all | jq -r '.[] | select(.project=="plain") | .remote')" "$T/origins/alpha.git"

# ---------------------------------------------------------------- attach / open

section "attach and open"
run new --local plain >/dev/null            # re-register: an earlier test let plain-main be forgotten
: > "$SHIM_LOG"
renv FLEET_HOSTS="laptop studio" -- attach studio plainR-main >/dev/null 2>&1
assert_contains "attach <host> <session> runs tmux on the remote via ssh -t" "$(cat "$SHIM_LOG")" "tmux new-session -A -s plainR-main"
assert_contains "  ...titling the window with the session and its machine" "$(cat "$SHIM_LOG")" "#S · studio · fleet"
assert_contains "attach unknown session errors"         "$(renv FLEET_HOSTS="laptop studio" -- attach studio nosuch 2>&1)" "no session 'nosuch' on studio"
assert_contains "attach unknown host errors"            "$(renv FLEET_HOSTS="laptop" -- attach nosuch x 2>&1)" "unknown host"
: > "$SHIM_LOG"; renv FLEET_HOSTS="laptop studio" FLEET_TERM=terminal -- attach studio plainR-main >/dev/null 2>&1
assert_contains "FLEET_TERM=terminal looks for an existing Terminal window first" "$(cat "$SHIM_LOG")" 'tell application "Terminal"'
assert_contains "  ...then opens a new one with do script"   "$(cat "$SHIM_LOG")" "do script"
assert_contains "  ...whose title marks the session"         "$(cat "$SHIM_LOG")" "set-titles-string"
assert_contains "  ...and the machine: the same session name on another Mac is another window" "$(cat "$SHIM_LOG")" "plainR-main · studio · fleet"
: > "$SHIM_LOG"; renv FLEET_HOSTS="laptop studio" FLEET_TERM=ghostty -- attach studio plainR-main >/dev/null 2>&1
assert_contains "FLEET_TERM=ghostty opens a Ghostty surface"  "$(cat "$SHIM_LOG")" "new surface configuration"
assert_contains "FLEET_TERM=bogus is rejected"                "$(renv FLEET_HOSTS="laptop studio" FLEET_TERM=bogus -- attach studio plainR-main 2>&1)" "expected inline, ghostty, terminal or iterm"
: > "$SHIM_LOG"
renv "FAKE_TMUX_SESSIONS=plainR-main plain-main" -- attach laptop plain-main >/dev/null 2>&1
assert_contains "attach on self execs tmux new-session -A" "$(cat "$SHIM_LOG")" "new-session -A -s plain-main"
: > "$SHIM_LOG"
renv "FAKE_TMUX_SESSIONS=plainR-main plain-main" -- attach 'plain ' >/dev/null 2>&1
assert_contains "attach via picker query"               "$(cat "$SHIM_LOG")" "new-session -A -s plain-main"
assert_contains "attach with nothing to attach says so" "$(renv FLEET_STATE="$T/emptystate" -- attach 2>&1)" "no fleet sessions"
: > "$SHIM_LOG"
O=$(renv FLEET_HOSTS="laptop studio" -- open studio plainR-main 2>&1)
assert_contains "open: local plain repo switched to the remote's branch" "$O" "switched plainR from main to feature/x"
assert_eq "open: local now on feature/x"                "$(git -C "$T/root/plainR" rev-parse --abbrev-ref HEAD)" "feature/x"
assert_true "open: remote commit pulled"                test -e "$T/root/plainR/work.txt"
echo more >> "$T/rootR/plainR/work.txt"; git -C "$T/rootR/plainR" commit -qam more; git -C "$T/rootR/plainR" push -q
renv FLEET_HOSTS="laptop studio" -- open studio plainR-main >/dev/null 2>&1
assert_eq "open again fast-forwards"                    "$(git -C "$T/root/plainR" log -1 --format=%s)" "more"
git -C "$T/root/plainR" checkout -q main; echo stray > "$T/root/plainR/dirty.txt"
assert_true "open switches despite an untracked file"   renv FLEET_HOSTS="laptop studio" -- open studio plainR-main
assert_eq "  ...which rides along"                       "$(cat "$T/root/plainR/dirty.txt")" "stray"
rm -f "$T/root/plainR/dirty.txt"
git -C "$T/root/plainR" checkout -q main; echo edit >> "$T/root/plainR/f"
O=$(renv FLEET_HOSTS="laptop studio" -- open studio plainR-main 2>&1)
assert_contains "open refuses a modified tracked file"  "$O" "uncommitted changes"
assert_contains "  ...and names it"                     "$O" " M f"
git -C "$T/root/plainR" checkout -q -- f
: > "$SHIM_LOG"; renv "FAKE_TMUX_SESSIONS=plainR-main plainB-t1" -- open laptop plainB-main >/dev/null 2>&1
assert_contains "open picks the .xcodeproj for Xcode"   "$(cat "$SHIM_LOG")" "xed $T/root/plainB/PlainB.xcodeproj"
mkdir -p "$T/root/plain/App/Plain.xcodeproj" "$T/root/plain/.build/x.xcodeproj"; : > "$SHIM_LOG"
run new --local plain >/dev/null; renv "FAKE_TMUX_SESSIONS=plainR-main plain-main" -- open laptop plain-main >/dev/null 2>&1
assert_contains "open finds a project one level down, not in .build" "$(cat "$SHIM_LOG")" "xed $T/root/plain/App/Plain.xcodeproj"
: > "$SHIM_LOG"; renv "FAKE_TMUX_SESSIONS=plainR-main plain-main" FLEET_OPEN=code -- open laptop plain-main >/dev/null 2>&1
assert_contains "FLEET_OPEN=<app> with no such command uses open -a" "$(cat "$SHIM_LOG")" "open -a code $T/root/plain"
assert_lacks    "  ...and not Xcode"                                  "$(cat "$SHIM_LOG")" "xed "
: > "$SHIM_LOG"; renv "FAKE_TMUX_SESSIONS=plainR-main plain-main" FLEET_OPEN=finder -- open laptop plain-main >/dev/null 2>&1
assert_contains "FLEET_OPEN=finder opens the folder"                   "$(cat "$SHIM_LOG")" "open $T/root/plain"
: > "$SHIM_LOG"; renv "FAKE_TMUX_SESSIONS=plainR-main plainR-main2" -- open laptop plainR-main >/dev/null 2>&1 || true
assert_contains "auto with no Xcode project falls back to Finder"      "$(cat "$SHIM_LOG")" "open $T/root/plainR"
mkdir -p "$T/root/plain/Plain.xcworkspace"; : > "$SHIM_LOG"; renv "FAKE_TMUX_SESSIONS=plainR-main plain-main" -- open laptop plain-main >/dev/null 2>&1
assert_contains "a workspace at the root wins over a nested project" "$(cat "$SHIM_LOG")" "xed $T/root/plain/Plain.xcworkspace"
O=$(renv FLEET_HOSTS="laptop studio" "FAKE_TMUX_SESSIONS=plainR-main rowingR-main" -- open studio rowingR-main 2>&1)
assert_contains "open finds the local clone by origin when the directory name differs" "$O" "no rowingR here, using simulatorL"
assert_eq "  ...and switches it to the remote's branch"  "$(git -C "$T/root/simulatorL" rev-parse --abbrev-ref HEAD)" "feature/oars"
assert_contains "open refuses a detached row"           "$(run open laptop alpha-det 2>&1 || true)" "detached"

# ---------------------------------------------------------------- reap

section "reap"
printf '#!/bin/bash\nexec env' > "$T/reap.sh"; for e in "${FENV[@]}"; do printf " '%s'" "$e" >> "$T/reap.sh"; done
printf " FAKE_TMUX_SESSIONS= /bin/bash '%s' reap\n" "$FLEET" >> "$T/reap.sh"; chmod +x "$T/reap.sh"
cat > "$T/reap.exp" <<EOF
set timeout 30
set stty_init {cols 500 rows 50}
spawn $T/reap.sh
expect {
  -re {\\[y/N\\] } { send "y\\r"; exp_continue }
  eof
}
EOF
O=$(expect -f "$T/reap.exp" 2>&1 | tr -d '\r')
assert_contains "reap keeps a dirty worktree"           "$O" "keep $TR/root/alpha/fresh"
assert_true  "reap: dirty worktree still there"         test -e "$T/root/alpha/fresh/important.swift"
assert_false "reap removed the merged worktree"         test -d "$T/root/alpha/merged"
assert_false "reap removed the unstarted, clean worktree (t1)" test -d "$T/root/plainB/.claude/worktrees/t1"
assert_false "reap forgot the worktree session"         test -e "$T/state/sessions/plainB-t1"
assert_true  "reap never touches the primary clone"     test -e "$T/root/alpha/main/.git"
assert_contains "reap skips a project with no remote"   "$O" "noremote: no origin/main, skipping"
assert_contains "reap resolves origin/HEAD for a master-default repo" "$O" "nothing beyond origin/master"
assert_false "reap removed legacy's unstarted worktree" test -d "$T/root/legacy/old"
assert_lacks "reap never offers the still-ahead branch" "$O" "alpha/feat (agent/feat"

# ---------------------------------------------------------------- hosts names / self-update

section "host names and self-update"
HC="$T/hostconf"; mkdir -p "$HC/fleet"; printf 'laptop\n' > "$HC/fleet/hosts"
assert_contains "hosts add refuses an ssh option as a name" "$(renv XDG_CONFIG_HOME="$HC" FLEET_HOSTS= -- hosts add -oProxyCommand=evil 2>&1)" "not a host name"
assert_contains "hosts add refuses spaces and shell characters" "$(renv XDG_CONFIG_HOME="$HC" FLEET_HOSTS= -- hosts add 'a;b' 2>&1)" "not a host name"
printf 'laptop\n-oProxyCommand=evil\n' > "$HC/fleet/hosts"
assert_eq "a bad line in the hosts file is skipped on load" "$(renv XDG_CONFIG_HOME="$HC" FLEET_HOSTS= -- hosts 2>/dev/null | head -1)" "laptop"

# fleet update = update_checkout: fetch, list, fast-forward; refuse unsigned tips once allowed_signers exists.
UC="$T/upconf"; mkdir -p "$UC/fleet" "$T/origins"; git init -q --bare "$T/origins/fleetco.git"
git clone -q "$T/origins/fleetco.git" "$T/fleetwork" 2>/dev/null; cp "$FLEET" "$T/fleetwork/fleet"
git -C "$T/fleetwork" add -A; git -C "$T/fleetwork" commit -qm "v1"; git -C "$T/fleetwork" push -q -u origin HEAD 2>/dev/null
git clone -q "$T/origins/fleetco.git" "$T/fleetco" 2>/dev/null
# Run the checkout's own copy: a script inside a git checkout updates that checkout (checkout_dir).
mkdir -p "$T/uphome"   # its own HOME: install --local writes hooks and ~/bin there
upd() { env "${FENV[@]}" XDG_CONFIG_HOME="$UC" HOME="$T/uphome" /bin/bash "$T/fleetco/fleet" install --local 2>&1; }
assert_contains "install --local: checkout up to date" "$(upd)" "is up to date"
echo "# v2" >> "$T/fleetwork/fleet"; git -C "$T/fleetwork" commit -qam "v2 unsigned"; git -C "$T/fleetwork" push -q 2>/dev/null
out=$(upd)
assert_contains "update lists what is coming"      "$out" "v2 unsigned"
assert_contains "update fast-forwards"             "$out" "1 new commit"
assert_eq       "checkout is now at v2"            "$(git -C "$T/fleetco" log -1 --format=%s)" "v2 unsigned"
ssh-keygen -q -t ed25519 -N '' -f "$T/sigkey" >/dev/null 2>&1
printf 'signer@example.com %s\n' "$(cat "$T/sigkey.pub")" > "$UC/fleet/allowed_signers"
echo "# v3" >> "$T/fleetwork/fleet"; git -C "$T/fleetwork" commit -qam "v3 unsigned"; git -C "$T/fleetwork" push -q 2>/dev/null
out=$(upd)
assert_contains "unsigned tip refused when allowed_signers exists" "$out" "NOT signed"
assert_eq       "checkout stays at v2"             "$(git -C "$T/fleetco" log -1 --format=%s)" "v2 unsigned"
echo "# v4" >> "$T/fleetwork/fleet"
git -C "$T/fleetwork" -c gpg.format=ssh -c user.signingkey="$T/sigkey" -c user.email=signer@example.com -c user.name=Signer commit -q -S -am "v4 signed"
git -C "$T/fleetwork" push -q 2>/dev/null
out=$(upd)
assert_contains "signed tip accepted"              "$out" "is signed by a key"
assert_eq       "checkout is now at v4"            "$(git -C "$T/fleetco" log -1 --format=%s)" "v4 signed"
# fleet install <host> on a Mac without fleet: the bootstrap clone there once
# died silently (its git is Xcode's shim, license unaccepted) because the
# remote's first output line is dropped as its header. Errors have spaces.
inst() { env "${FENV[@]}" XDG_CONFIG_HOME="$UC" HOME="$T/uphome" /bin/bash "$T/fleetco/fleet" install "$@" 2>&1; }
O=$(inst fresh); RC=$?
assert_contains "remote install shows why the bootstrap failed" "$O" "You have not agreed to the Xcode license"
assert_contains "  ...as a FAIL with the retry"          "$O" "FAIL  fleet never got installed on fresh"
assert_eq       "  ...and exits 1"                       "$RC" "1"
mkdir -p "$T/freshhome/bin"; printf '#!/bin/sh\necho fresh\necho "  ok    pretend"\n' > "$T/freshhome/bin/fleet"; chmod +x "$T/freshhome/bin/fleet"
O=$(inst fresh)
assert_eq       "remote install drops the remote's own header" "$(printf '%s\n' "$O" | grep -cx fresh | tr -d ' ')" "1"
assert_contains "  ...and keeps the rest"                "$O" "ok    pretend"
assert_lacks    "  ...with no FAIL"                      "$O" "FAIL"

# ---------------------------------------------------------------- doctor, misc

section "doctor and misc"
O=$(run doctor --local 2>&1); RC=$?
assert_eq "doctor --local exits non-zero with failures" "$RC" "1"
assert_contains "doctor reports missing hooks with a fix" "$O" "fix: fleet install   (merges them in"
assert_contains "doctor names the host first"           "$(printf '%s' "$O" | head -1)" "laptop"
# The project count is every layout (plain clones included), not only <project>/main.
NP=$(run projects --local | awk -F '\t' '$2 != "dir"' | wc -l | tr -d ' ')
assert_contains "doctor counts projects of every layout"    "$O" "ok    $NP project(s) under FLEET_ROOT"
mkdir -p "$T/home/src/one/.git" "$T/home/src/two/.git" "$T/home/misc/three/.git"     # where this "Mac" keeps clones
assert_contains "doctor: no FLEET_ROOT points at the config and the folder with the clones" "$(renv FLEET_ROOT="$T/nowhere" -- doctor --local 2>&1)" \
  "to the folder holding your clones (on this Mac that looks like $T/home/src), or mkdir -p '$T/nowhere'"
# ~/bin on PATH is judged on the caller's PATH. Over ssh, with_path prepends
# $HOME/bin before fleet starts, so it sends the PATH it found as
# FLEET_ORIG_PATH; without that, remote install never wrote ~/.zprofile.
assert_contains "doctor: ~/bin on the caller's PATH is ok"  "$(renv PATH="$T/home/bin:$HERE/shims:/usr/bin:/bin" -- doctor --local 2>&1)" "ok    ~/bin on your shell's PATH"
assert_contains "doctor: with_path's PATH does not count"   "$(renv PATH="$T/home/bin:$HERE/shims:/usr/bin:/bin" FLEET_ORIG_PATH=/usr/bin:/bin -- doctor --local 2>&1)" "FAIL  ~/bin on your shell's PATH"
assert_contains "doctor over ssh sees the remote's own PATH" "$(run doctor studio 2>&1)" "FAIL  ~/bin on your shell's PATH"
assert_contains "plain fleet with no args runs ls"      "$(renv FLEET_STATE="$T/emptystate" -- 2>&1)" "no fleet sessions"
assert_contains "ls --json (default) has only managed rows" "$(renv "$ALIVE" -- ls --json | jq -r 'all(.managed)')" "true"
assert_eq "new --no-attach creates, prints host/session/dir, never prompts" \
  "$(renv "FAKE_TMUX_SESSIONS=plainR-main plain-main" -- new laptop plain --no-attach)" "$(printf 'laptop\tplain-main\t%s' "$T/root/plain")"
assert_eq "new --no-attach with a name"                 "$(run new laptop plain triage --no-attach | cut -f2)" "plain-triage"
: > "$SHIM_LOG"
assert_eq "a name with a quote in it is a session too"   "$(run new laptop plain "won't-fix" --no-attach | cut -f2)" "plain-won't-fix"
assert_contains "  ...typed into the pane correctly quoted" "$(cat "$SHIM_LOG")" "claude -n 'laptop-plain-won'\''t-fix'"
printf '%s\nplainR\n' "$T/rootR/plainR" > "$RH/.local/state/fleet/sessions/plainR-won't-fix"
: > "$SHIM_LOG"; renv FLEET_HOSTS="laptop studio" "FAKE_TMUX_SESSIONS=plainR-main plainR-won't-fix" -- attach studio "plainR-won't-fix" >/dev/null 2>&1
assert_contains "  ...and attached over ssh, the remote shell parsing the quoted name" "$(cat "$SHIM_LOG")" "tmux new-session -A -s plainR-won't-fix"
rm -f "$RH/.local/state/fleet/sessions/plainR-won't-fix"
: > "$SHIM_LOG"; renv "FAKE_TMUX_SESSIONS=plainR-main plain-main plain-won't-fix" -- kill -y laptop "plain-won't-fix" >/dev/null 2>&1
assert_contains "  ...and killed by that name"             "$(cat "$SHIM_LOG")" "tmux kill-session -t plain-won't-fix"
assert_contains "new --no-attach refuses an inexact project" "$(run new laptop plai --no-attach 2>&1)" "no project 'plai'"

section "models"
assert_eq "models --local without a catalog: unknown" "$(run models --local)" '{"default":"","models":[]}'
mkdir -p "$T/home/.claude/cache/model-catalog"
printf '{"fetchedAt":1,"catalog":{"surface":"ccd","config":{"models":[{"id":"claude-old","name":"Old","short_name":"Old","section":"main"}]}}}' > "$T/home/.claude/cache/model-catalog/tok-a-ccd.json"
printf '{"fetchedAt":2,"catalog":{"surface":"ccd","config":{"models":[{"id":"claude-fable-5-1","name":"Fable 5.1","short_name":"Fable","section":"main"},{"id":"claude-opus-4-8","name":"Opus 4.8","short_name":"Opus","section":"overflow"}]}}}' > "$T/home/.claude/cache/model-catalog/tok-b-ccd.json"
printf '{"fetchedAt":3,"catalog":{"surface":"web","config":{"models":[{"id":"not-for-claude-code"}]}}}' > "$T/home/.claude/cache/model-catalog/other.json"
printf 'garbage' > "$T/home/.claude/cache/model-catalog/broken.json"
assert_eq "models --local: freshest ccd catalog, other surfaces and garbage ignored" \
  "$(run models --local | jq -c '[.models[].id]')" '["claude-fable-5-1","claude-opus-4-8"]'
printf '{"fetchedAt":4,"catalog":{"surface":"cc","config":{"models":[{"id":"claude-opus-5-5","name":"Opus 5.5","short_name":"Opus","section":"main"}]}}}' > "$T/home/.claude/cache/model-catalog/org-cc.json"
assert_eq "models --local: the CLI's cc catalog counts too (no desktop app)" \
  "$(run models --local | jq -c '[.models[].id]')" '["claude-opus-5-5"]'
assert_eq "models: no model in settings = no default"  "$(run models --local | jq -r .default)" ""
printf '{"model":"claude-fable-5-1[1m]"}' > "$T/home/.claude/settings.json"
assert_eq "models: settings model without its [1m] suffix" "$(run models --local | jq -r .default)" "claude-fable-5-1"
printf '{"model":"opus"}' > "$T/home/.claude/settings.local.json"
assert_eq "models: settings.local wins"                 "$(run models --local | jq -r .default)" "opus"
assert_eq "models --json carries the host"              "$(run models --json | jq -r .host)" "laptop"
assert_contains "models table marks the default"        "$(run models)" "default: opus"
assert_contains "models on the remote"                  "$(run models studio --json)" '"host":"studio"'
rm -f "$T/home/.claude/settings.local.json" "$T/home/.claude/settings.json"
: > "$SHIM_LOG"
run new laptop plain triage --no-attach --model claude-sonnet-5 >/dev/null
assert_contains "new --model reaches the claude command line, last" "$(cat "$SHIM_LOG")" "--permission-mode auto --remote-control --model 'claude-sonnet-5'"
: > "$SHIM_LOG"
run new --local plain triage >/dev/null
assert_lacks "without --model claude gets no --model"   "$(cat "$SHIM_LOG")" "--model"
assert_contains "--model without a value is an error"   "$(run new --local plain --model 2>&1)" "needs a value"
assert_contains "projects --json carries path and remote" "$(run projects --json | jq -c '.projects[] | select(.project=="plain") | {path, remote}')" "\"remote\":\"$T/origins/alpha.git\""
mkdir -p "$T/home/.claude"; printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"$HOME/bin/fleet hook done"}]}]},"model":"x"}\n' > "$T/home/.claude/settings.json"
assert_contains "doctor names the hook events still missing" "$(run doctor --local 2>&1)" "missing in $T/home/.claude/settings.json for: UserPromptSubmit PostToolUse Notification SessionEnd"
assert_contains "unknown command shows usage"           "$(run bogus 2>&1)" 'unknown command "bogus"'
assert_eq "unknown command exits 1"                     "$(run bogus >/dev/null 2>&1; echo $?)" "1"
assert_eq "hook writes the state file for the tmux session" \
  "$(renv FAKE_TMUX_SESSION=plain-main -- hook running </dev/null >/dev/null; jq -r .state "$T/state/plain-main.json")" "running"
assert_eq "hook keeps Claude's session_id from stdin" \
  "$(echo '{"session_id":"abc-123","hook_event_name":"Stop"}' | renv FAKE_TMUX_SESSION=plain-main -- hook done >/dev/null; jq -r .session_id "$T/state/plain-main.json")" "abc-123"
assert_eq "hook without an id keeps the earlier one" \
  "$(renv FAKE_TMUX_SESSION=plain-main -- hook running </dev/null >/dev/null; jq -r .session_id "$T/state/plain-main.json")" "abc-123"
assert_eq "status carries claude_session from the hook"  "$(renv "FAKE_TMUX_SESSIONS=plainR-main plain-main" -- status --json | jq -r '.[] | select(.session=="plain-main") | .claude_session')" "abc-123"
mkdir -p "$T/home/.claude/sessions"; printf '{"pid":1,"sessionId":"local-uuid","bridgeSessionId":"session_01BRIDGE","tmux":"plain-main:@0.%%0","name":"plain-main"}\n' > "$T/home/.claude/sessions/1.json"
assert_eq "Claude Code's registry wins: bridge id for the tmux session" "$(renv "FAKE_TMUX_SESSIONS=plainR-main plain-main" -- status --json | jq -r '.[] | select(.session=="plain-main") | .claude_session')" "session_01BRIDGE"

section "keys"
K="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGxvbmdlbm91Z2h0b2xvb2tsaWtlYWtleQAAAAAAAAA fleet-iphone"
assert_contains "keys add authorizes here and on every host" "$(renv FLEET_HOSTS="laptop studio" -- keys add "$K" 2>&1)" "add fleet-iphone on studio"
assert_eq "  ...the line is in this Mac's authorized_keys"   "$(grep -c "fleet-iphone" "$T/home/.ssh/authorized_keys")" "1"
assert_eq "  ...and in the remote's"                          "$(grep -c "fleet-iphone" "$RH/.ssh/authorized_keys")" "1"
assert_eq "  ...with mode 600"                                "$(stat -f %Lp "$T/home/.ssh/authorized_keys")" "600"
renv FLEET_HOSTS="laptop studio" -- keys add "$K" >/dev/null 2>&1
assert_eq "keys add is idempotent"                            "$(grep -c "fleet-iphone" "$RH/.ssh/authorized_keys")" "1"
assert_contains "keys lists fleet-tagged keys"                "$(run keys)" "fleet-iphone  (ssh-ed25519)"
assert_contains "keys add rejects a non-key"                  "$(run keys add 'echo pwned; ssh-ed25519 AAAA x' 2>&1)" "one OpenSSH public key line"
assert_contains "keys add rejects a second line"              "$(run keys add "$(printf 'ssh-ed25519 AAAA a\ncommand=x')" 2>&1)" "one OpenSSH public key line"
assert_contains "keys add --local stays here"                 "$(renv FLEET_HOSTS="laptop studio" -- keys add "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGxvbmdlbm91Z2h0b2xvb2tsaWtlYWtleQAAAAAAAAB fleet-sim" --local 2>&1)" "on laptop"
assert_eq "  ...not on the remote"                            "$(grep -c "fleet-sim" "$RH/.ssh/authorized_keys")" "0"
renv FLEET_HOSTS="laptop studio" -- keys rm fleet-iphone >/dev/null 2>&1
assert_eq "keys rm revokes everywhere"                        "$(grep -c "fleet-iphone" "$T/home/.ssh/authorized_keys" "$RH/.ssh/authorized_keys" | awk -F: '{s+=$2} END {print s}')" "0"
assert_eq "  ...leaving other keys alone"                     "$(grep -c "fleet-sim" "$T/home/.ssh/authorized_keys")" "1"

section "shell and kill"
: > "$SHIM_LOG"; renv FLEET_HOSTS="laptop studio" FLEET_TERM=terminal -- shell studio >/dev/null 2>&1
assert_contains "shell <host> opens a terminal window running ssh" "$(cat "$SHIM_LOG")" "ssh -t studio"
: > "$SHIM_LOG"; renv FLEET_HOSTS="laptop studio" FLEET_TERM=ghostty -- shell laptop >/dev/null 2>&1
assert_contains "shell on self opens a login shell there"      "$(cat "$SHIM_LOG")" "bash -l"
assert_contains "shell rejects an unknown host"                 "$(renv FLEET_HOSTS="laptop" -- shell nosuch 2>&1)" "unknown host"
: > "$SHIM_LOG"; renv FLEET_HOSTS="laptop studio" FLEET_TERM=terminal -- shell studio "/tmp/a b" >/dev/null 2>&1
assert_contains "shell <host> <dir> starts in that directory over ssh" "$(cat "$SHIM_LOG")" "ssh -t studio 'cd '\''/tmp/a b'\'' 2>/dev/null; exec \${SHELL:-/bin/zsh} -l'"
: > "$SHIM_LOG"; renv FLEET_HOSTS="laptop studio" FLEET_TERM=ghostty -- shell laptop /tmp >/dev/null 2>&1
assert_contains "shell on self with a dir cds there first"      "$(cat "$SHIM_LOG")" "bash -c 'cd '\''/tmp'\'' 2>/dev/null; exec \${SHELL:-/bin/zsh} -l'"
assert_contains "kill without -y and no tty refuses"            "$(renv FLEET_HOSTS="laptop studio" -- kill studio plainR-main 2>&1 </dev/null)" "without -y"
assert_true  "  ...and the session is still registered"         test -e "$RH/.local/state/fleet/sessions/plainR-main"
: > "$SHIM_LOG"
assert_contains "kill -y on a remote ends the session there"    "$(renv FLEET_HOSTS="laptop studio" -- kill -y studio plainR-main 2>&1)" "ended plainR-main"
assert_contains "  ...via tmux kill-session on that host"       "$(cat "$SHIM_LOG")" "tmux kill-session -t plainR-main"
assert_false "  ...and a session in the repo itself is forgotten" test -e "$RH/.local/state/fleet/sessions/plainR-main"
assert_contains "kill of an unknown session errors"             "$(renv FLEET_HOSTS="laptop studio" -- kill -y studio nosuch 2>&1)" "no session 'nosuch'"
mkdir -p "$T/state/sessions"; printf '%s\nalpha\n' "$T/root/alpha/feat" > "$T/state/sessions/alpha-feat"; echo '{"state":"running"}' > "$T/state/alpha-feat.json"
: > "$SHIM_LOG"; renv "FAKE_TMUX_SESSIONS=alpha-feat plainR-main plain-main" -- kill -y laptop alpha-feat >/dev/null 2>&1   # plain-main stays alive, so it stays registered
assert_contains "kill on self kills the tmux session"           "$(cat "$SHIM_LOG")" "tmux kill-session -t alpha-feat"
assert_lacks    "  ...without typing /exit when only a shell runs there" "$(cat "$SHIM_LOG")" "send-keys"
: > "$SHIM_LOG"; O=$(renv "FAKE_TMUX_SESSIONS=alpha-feat plainR-main plain-main" FAKE_TMUX_COMMAND=claude FLEET_EXIT_TIMEOUT=1 -- kill -y laptop alpha-feat 2>&1)
assert_contains "kill with claude in the pane asks it to /exit first"  "$(cat "$SHIM_LOG")" "tmux send-keys -t alpha-feat Escape"
assert_contains "  ...then /exit"                                  "$(cat "$SHIM_LOG")" "tmux send-keys -t alpha-feat C-u /exit Enter"
assert_eq       "  ...and kill-session comes after the wait"       "$(grep -o 'send-keys.*exit\|kill-session' "$SHIM_LOG" | tr '\n' ' ')" "send-keys -t alpha-feat C-u /exit kill-session "
assert_contains "  ...saying claude was still there at the timeout" "$O" "still running after 1s, killed"
assert_false "  ...and drops the state file"                    test -e "$T/state/alpha-feat.json"
assert_true  "  ...but a worktree session stays registered for reap" test -e "$T/state/sessions/alpha-feat"

section "what the agent is doing (hook payloads) and its stats (status line)"
echo '{"session_id":"abc-123","hook_event_name":"UserPromptSubmit","user_input":"fix the   music\nplayback bug"}' | renv FAKE_TMUX_SESSION=plain-main -- hook running >/dev/null
assert_eq "UserPromptSubmit keeps the prompt, whitespace collapsed" "$(jq -r .prompt "$T/state/plain-main.json")" "fix the music playback bug"
assert_eq "  ...and the session id"                                  "$(jq -r .session_id "$T/state/plain-main.json")" "abc-123"
echo '{"hook_event_name":"UserPromptSubmit","user_input":"<task-notification>\n<task-id>abc</task-id>"}' | renv FAKE_TMUX_SESSION=plain-main -- hook running >/dev/null
assert_eq "an injected tagged prompt (task notification) keeps the real one" "$(jq -r .prompt "$T/state/plain-main.json")" "fix the music playback bug"
echo '{"hook_event_name":"UserPromptSubmit","user_input":"<agent-message from=\"abc\">\n[Subagent hand-back] report"}' | renv FAKE_TMUX_SESSION=plain-main -- hook running >/dev/null
assert_eq "  ...also a tag with attributes (agent message)"           "$(jq -r .prompt "$T/state/plain-main.json")" "fix the music playback bug"
echo '{"hook_event_name":"UserPromptSubmit","user_input":"<5 items left, then ship"}' | renv FAKE_TMUX_SESSION=plain-main -- hook running >/dev/null
assert_eq "  ...but a prompt merely starting with < is kept"          "$(jq -r .prompt "$T/state/plain-main.json")" "<5 items left, then ship"
echo '{"hook_event_name":"UserPromptSubmit","user_input":"fix the music playback bug"}' | renv FAKE_TMUX_SESSION=plain-main -- hook running >/dev/null
echo '{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}' | renv FAKE_TMUX_SESSION=plain-main -- hook blocked >/dev/null
assert_eq "Notification keeps its message as the note"    "$(jq -r .note "$T/state/plain-main.json")" "Claude needs your permission to use Bash"
assert_eq "  ...the prompt survives"                       "$(jq -r .prompt "$T/state/plain-main.json")" "fix the music playback bug"
echo '{"hook_event_name":"Notification","notification_type":"idle_prompt"}' | renv FAKE_TMUX_SESSION=plain-main -- hook blocked >/dev/null
assert_eq "a Notification without a message names its type" "$(jq -r .note "$T/state/plain-main.json")" "waiting for input"
echo '{"hook_event_name":"PostToolUse","tool_name":"Bash"}' | renv FAKE_TMUX_SESSION=plain-main -- hook running >/dev/null
assert_eq "running clears the note"                        "$(jq -r .note "$T/state/plain-main.json")" ""
echo '{"hook_event_name":"Stop","last_assistant_message":"**All done.**\n\nTests pass (`swift test`)."}' | renv FAKE_TMUX_SESSION=plain-main -- hook done >/dev/null
assert_eq "Stop keeps what the agent said, as plain text"  "$(jq -r .said "$T/state/plain-main.json")" "All done. Tests pass (swift test)."
echo '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input"}' | renv FAKE_TMUX_SESSION=plain-main -- hook blocked >/dev/null
assert_eq "idle after done: the note is what it last said, not the generic message" "$(jq -r .note "$T/state/plain-main.json")" "All done. Tests pass (swift test)."
assert_eq "  ...and said survives blocked"                 "$(jq -r .said "$T/state/plain-main.json")" "All done. Tests pass (swift test)."
printf '{"state":"running","ts":1,"prompt":"<task-notification> <task-id>x</task-id>"}' > "$T/state/plain-main.json"
assert_eq "status drops a tag prompt recorded before the filter" "$(renv "FAKE_TMUX_SESSIONS=plainR-main plain-main" -- status --json | jq -r '.[] | select(.session=="plain-main") | .prompt')" ""
echo '{"hook_event_name":"Stop","last_assistant_message":"**All done.**\n\nTests pass (`swift test`)."}' | renv FAKE_TMUX_SESSION=plain-main -- hook done >/dev/null
assert_eq "control characters in a reply are dropped (no terminal escapes into ls)" \
  "$(printf '{"last_assistant_message":"done\\u001b[31m red\\u0007"}' | renv FAKE_TMUX_SESSION=cc -- hook done >/dev/null; jq -r .said "$T/state/cc.json")" "done [31m red"
assert_eq "hook payload without a trailing newline is still read" \
  "$(printf '%s' '{"session_id":"no-newline"}' | renv FAKE_TMUX_SESSION=nonl -- hook running >/dev/null; jq -r .session_id "$T/state/nonl.json")" "no-newline"
assert_eq "hook with garbage on stdin still writes the state" "$(echo 'not json' | renv FAKE_TMUX_SESSION=plain-main -- hook idle >/dev/null; jq -r .state "$T/state/plain-main.json")" "idle"
assert_eq "  ...keeping what it had"                       "$(jq -r .said "$T/state/plain-main.json")" "All done. Tests pass (swift test)."
SL='{"model":{"id":"claude-opus-5","display_name":"Opus"},"context_window":{"used_percentage":34.6,"context_window_size":200000},"cost":{"total_cost_usd":1.25},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1800000000},"seven_day":{"used_percentage":41.2,"resets_at":1800500000}}}'
assert_eq "statusline prints a short line by default"      "$(echo "$SL" | renv FAKE_TMUX_SESSION=plain-main -- statusline)" "Opus · ctx 34% · 5h 23% · 7d 41%"
assert_eq "  ...and records the numbers"                   "$(jq -c '[.model,.context_pct,.cost_usd,.limit_5h,.limit_7d,.limit_7d_reset]' "$T/state/plain-main.stats.json")" '["Opus",34,1.25,23,41,1800500000]'
assert_eq "statusline -- runs the previous command with the same JSON" "$(echo "$SL" | renv FAKE_TMUX_SESSION=plain-main -- statusline -- 'jq -r .model.display_name')" "Opus"
assert_eq "statusline without limits records -1"           "$(echo '{"model":{"display_name":"Opus"}}' | renv FAKE_TMUX_SESSION=other -- statusline >/dev/null; jq -c '[.limit_5h,.context_pct]' "$T/state/other.stats.json")" '[-1,-1]'
echo '{"user_input":"fix the music playback bug"}' | renv FAKE_TMUX_SESSION=plain-main -- hook running >/dev/null
echo "$SL" | renv FAKE_TMUX_SESSION=plain-main -- statusline >/dev/null
J=$(renv "FAKE_TMUX_SESSIONS=plainR-main plain-main" -- status --json | jq -c '.[] | select(.session=="plain-main") | [.prompt,.note,.model,.context_pct,.limit_5h,(.stats_ts>0)]')
assert_eq "status carries prompt, model, context and limits" "$J" '["fix the music playback bug","","Opus",34,23,true]'
assert_contains "ls shows what the agent is doing"          "$(renv "FAKE_TMUX_SESSIONS=plainR-main plain-main" -- ls)" "· fix the music playback bug"
assert_contains "ls shows the account's usage limits"       "$(renv "FAKE_TMUX_SESSIONS=plainR-main plain-main" -- ls)" "usage: 5-hour 23%  ·  7-day 41%"
assert_contains "doctor wants the status line wrapped"      "$(run doctor --local 2>&1)" "status line in $T/home/.claude/settings.json does not run fleet statusline"

section "claude setup"
# Two different Claude setups: laptop ($T/home) and studio ($RH).
mkdir -p "$T/home/.claude/scripts" "$T/home/.claude/plugins" "$RH/.claude/scripts" "$RH/.claude/plugins"
cat > "$T/home/.claude/settings.json" <<'EOF'
{"enabledPlugins": {"superpowers@official": true, "swift-lsp@official": true, "off@official": false, "t@tools": true},
 "effortLevel": "high", "env": {"API_TOKEN": "sekrit-laptop"},
 "permissions": {"allow": ["Bash(git log:*)", "Bash(echo 'it''s')"], "defaultMode": "auto"},
 "hooks": {"Stop": []}, "statusLine": {"type": "command", "command": "x"}, "feedbackSurveyState": {"n": 1}, "tipsCache": 1}
EOF
cat > "$RH/.claude/settings.json" <<'EOF'
{"enabledPlugins": {"swift-lsp@official": true, "only-studio@official": true},
 "effortLevel": "medium", "permissions": {"allow": ["Bash(ls:*)"]}}
EOF
printf '{"official":{"source":{"source":"github","repo":"acme/official"}},"tools":{"source":{"source":"github","repo":"acme/tools"}}}' > "$T/home/.claude/plugins/known_marketplaces.json"
printf '{"official":{"source":{"source":"github","repo":"acme/official"}}}' > "$RH/.claude/plugins/known_marketplaces.json"
printf '{"mcpServers":{"sentry":{"type":"http","url":"https://mcp.sentry.dev/mcp"}},"projects":{"/x":{"mcpServers":{"proj":{}}}}}' > "$T/home/.claude.json"
printf '{"mcpServers":{"sentry":{"type":"http","url":"https://mcp.sentry.dev/mcp"},"xcode":{"type":"stdio","command":"/usr/bin/xcrun","args":["mcpbridge"],"env":{"TOKEN":"sekrit-studio"}}}}' > "$RH/.claude.json"
echo "# laptop rules" > "$T/home/.claude/CLAUDE.md"; echo "# studio rules" > "$RH/.claude/CLAUDE.md"
printf 'print("hi")\n' > "$T/home/.claude/scripts/render.py"; chmod 755 "$T/home/.claude/scripts/render.py"

S=$(run claude --local)
assert_eq "claude --local is a version 1 snapshot"     "$(printf '%s' "$S" | jq -r .version)" "1"
assert_eq "  ...settings rows skip fleet's own keys, bookkeeping and permissions" \
  "$(printf '%s' "$S" | jq -r '[.items[] | select(.kind=="setting") | .name] | sort | join(",")')" "effortLevel,env,permissions.defaultMode"
assert_eq "  ...one perm row per rule"                 "$(printf '%s' "$S" | jq -r '[.items[] | select(.kind=="perm") | .name] | sort | join(",")')" "allow:Bash(echo 'it''s'),allow:Bash(git log:*)"
assert_eq "  ...a disabled plugin is disabled, not absent" "$(printf '%s' "$S" | jq -r '.items[] | select(.name=="off@official") | .summary')" "disabled"
assert_eq "  ...marketplaces with their source"        "$(printf '%s' "$S" | jq -r '.items[] | select(.kind=="marketplace" and .name=="tools") | .value.repo')" "acme/tools"
assert_eq "  ...mcp summary is transport and host"     "$(printf '%s' "$S" | jq -r '.items[] | select(.kind=="mcp") | .summary')" "http mcp.sentry.dev"
assert_eq "  ...project-scope mcp servers are not rows" "$(printf '%s' "$S" | jq -r '[.items[] | select(.name=="proj")] | length')" "0"
assert_eq "  ...files: CLAUDE.md and scripts, exec kept" "$(printf '%s' "$S" | jq -r '[.items[] | select(.kind=="file") | "\(.name):\(.exec)"] | join(",")')" "CLAUDE.md:false,scripts/render.py:true"
assert_lacks "  ...never carries a secret"             "$S" "sekrit"
assert_eq "  ...every item has a 64-hex digest"        "$(printf '%s' "$S" | jq -r 'all(.items[]; .digest | test("^[0-9a-f]{64}$"))')" "true"
assert_eq "equal values have equal digests across Macs" \
  "$(printf '%s' "$S" | jq -r '.items[] | select(.kind=="mcp" and .name=="sentry") | .digest')" \
  "$(renv HOME="$RH" -- claude --local | jq -r '.items[] | select(.kind=="mcp" and .name=="sentry") | .digest')"
assert_eq "no ~/.claude at all is an empty snapshot"   "$(renv HOME="$T/emptyhome" -- claude --local)" '{"version":1,"items":[]}'
mkdir -p "$T/badhome/.claude"; echo 'not json {' > "$T/badhome/.claude/settings.json"
assert_eq "a settings.json that is not JSON is an error row" \
  "$(renv HOME="$T/badhome" -- claude --local | jq -c '[.items[] | [.kind, .name, .summary]]')" '[["error",".claude/settings.json","not JSON"]]'

M=$(renv FLEET_HOSTS="laptop studio" -- claude --json)
assert_eq "claude --json names the Macs that answered" "$(printf '%s' "$M" | jq -c .hosts)" '["laptop","studio"]'
assert_eq "  ...rows in kind order, marketplace first" "$(printf '%s' "$M" | jq -r '.items[0].kind')" "marketplace"
assert_eq "  ...the same mcp entry does not differ"    "$(printf '%s' "$M" | jq -r '.items[] | select(.kind=="mcp" and .name=="sentry") | .differs')" "false"
assert_eq "  ...a setting that differs"                "$(printf '%s' "$M" | jq -c '.items[] | select(.name=="effortLevel") | [.differs, .cells.laptop.summary, .cells.studio.summary]')" '[true,"high","medium"]'
assert_eq "  ...absent is null"                        "$(printf '%s' "$M" | jq -c '.items[] | select(.name=="xcode") | .cells.laptop')" "null"
assert_lacks "  ...no secrets in the matrix"           "$M" "sekrit"
assert_eq "claude --diff drops the rows that agree"    "$(renv FLEET_HOSTS="laptop studio" -- claude --json --diff | jq -r '[.items[] | select(.name=="sentry" or .name=="swift-lsp@official")] | length')" "0"
TB=$(renv FLEET_HOSTS="laptop studio" -- claude)
assert_contains "the table has a column per Mac"       "$(printf '%s' "$TB" | head -1)" "laptop"
assert_contains "  ...and shows both values of a setting" "$(printf '%s' "$TB" | grep effortLevel)" "high"
assert_contains "  ...(studio's too)"                  "$(printf '%s' "$TB" | grep effortLevel)" "medium"
assert_contains "  ...a disabled plugin is an open dot" "$(printf '%s' "$TB" | grep 'off@official')" "○"
assert_lacks "  ...no secrets in the table"            "$TB" "sekrit"
assert_contains "a dead host is reported under the table" "$(renv FLEET_HOSTS="laptop studio dead" -- claude 2>&1)" "dead: ssh failed"
assert_lacks "  ...and gets no column"                 "$(renv FLEET_HOSTS="laptop studio dead" -- claude 2>&1 | head -1)" "dead"
assert_lacks "claude <host> asks that host only"       "$(renv FLEET_HOSTS="laptop studio" -- claude studio | head -1)" "laptop"
assert_contains "claude rejects an unknown host"       "$(renv FLEET_HOSTS="laptop studio" -- claude nosuch 2>&1)" "unknown host"

C="$T/home/.claude"
assert_eq "get --local: a setting's value"             "$(run claude get --local setting effortLevel)" '"high"'
assert_eq "get --local: a disabled plugin"             "$(run claude get --local plugin off@official)" '"disabled"'
assert_false "get --local: absent is exit 1"           run claude get --local mcp nope
: > "$SHIM_LOG"
assert_contains "set marketplace adds it through claude" "$(printf '{"source":"github","repo":"acme/extras"}' | run claude set --local marketplace extras)" "added marketplace extras"
assert_contains "  ...via claude plugin marketplace add" "$(cat "$SHIM_LOG")" "claude plugin marketplace add acme/extras"
: > "$SHIM_LOG"
assert_contains "set marketplace already known is a no-op" "$(printf '{"source":"github","repo":"acme/extras"}' | run claude set --local marketplace extras)" "already known"
assert_eq "  ...without calling claude"                "$(cat "$SHIM_LOG")" ""
assert_contains "set marketplace from a local path is refused" "$(printf '{"source":"directory","path":"/x"}' | run claude set --local marketplace localmk 2>&1)" "by hand"
: > "$SHIM_LOG"
printf '"enabled"' | run claude set --local plugin new@official >/dev/null
assert_eq "set plugin installs it enabled"             "$(jq -r '.enabledPlugins["new@official"]' "$C/settings.json")" "true"
assert_contains "  ...via claude plugin install --scope user" "$(cat "$SHIM_LOG")" "claude plugin install new@official --scope user"
printf '"disabled"' | run claude set --local plugin new@official >/dev/null
assert_eq "set plugin disabled keeps it installed, disabled" "$(jq -r '.enabledPlugins["new@official"]' "$C/settings.json")" "false"
O=$(printf '"enabled"' | renv FAKE_CLAUDE_REFUSE=bad@official -- claude set --local plugin bad@official 2>&1); RC=$?
assert_eq "a plugin claude will not install unattended fails" "$RC" "1"
assert_contains "  ...and says to install it by hand"  "$O" "install it on laptop by hand"
O=$(printf '{"type":"http","url":"https://mcp.example.com/mcp","headers":{"Authorization":"Bearer sekrit"}}' | run claude set --local mcp example)
assert_eq "set mcp writes the whole entry"             "$(jq -r '.mcpServers.example.headers.Authorization' "$T/home/.claude.json")" "Bearer sekrit"
assert_contains "  ...and reminds to sign in for http" "$O" "/mcp"
assert_lacks "  ...without echoing the secret"         "$O" "sekrit"
rm -f "$C/settings.json.fleet-backup"
printf '"low"' | run claude set --local setting effortLevel >/dev/null
assert_eq "set setting"                                "$(jq -r .effortLevel "$C/settings.json")" "low"
assert_true "  ...backing settings.json up first"      test -e "$C/settings.json.fleet-backup"
printf '"plan"' | run claude set --local setting permissions.defaultMode >/dev/null
assert_eq "set a permissions.* setting"                "$(jq -r .permissions.defaultMode "$C/settings.json")" "plan"
assert_contains "set refuses fleet's own keys"         "$(printf '{}' | run claude set --local setting hooks 2>&1)" "not a setting fleet compares"
assert_contains "set refuses the permission lists as a whole" "$(printf '[]' | run claude set --local setting permissions.allow 2>&1)" "not a setting fleet compares"
assert_contains "set refuses input that is not JSON"   "$(printf 'nope' | run claude set --local setting effortLevel 2>&1)" "not JSON"
cp "$C/settings.json" "$T/settings.good"; echo 'half {' > "$C/settings.json"
assert_contains "set refuses to rewrite a settings.json that is not JSON" "$(printf '"x"' | run claude set --local setting effortLevel 2>&1)" "not valid JSON"
assert_eq "  ...leaving it as it was"                  "$(cat "$C/settings.json")" "half {"
cp "$T/settings.good" "$C/settings.json"
R="Bash(say 'a:b' \"c\")"
run claude set --local perm "allow:$R" </dev/null >/dev/null; run claude set --local perm "allow:$R" </dev/null >/dev/null
assert_eq "set perm adds a rule once, quotes and colons intact" "$(jq --arg r "$R" '[.permissions.allow[] | select(. == $r)] | length' "$C/settings.json")" "1"
assert_contains "set perm needs allow:, deny: or ask:" "$(run claude set --local perm "maybe:x" </dev/null 2>&1)" "allow:<rule>"
printf '#!/bin/sh\necho x\n' | run claude set --local file scripts/new.sh --exec >/dev/null
assert_eq "set file writes it, executable when asked"  "$(stat -f %Lp "$C/scripts/new.sh")" "755"
echo "# first" > "$C/CLAUDE.md"; rm -f "$C/CLAUDE.md.fleet-backup"
echo "# second" | run claude set --local file CLAUDE.md >/dev/null
echo "# third" | run claude set --local file CLAUDE.md >/dev/null
assert_eq "set file replaces the content"              "$(cat "$C/CLAUDE.md")" "# third"
assert_eq "  ...backing up the original once"          "$(cat "$C/CLAUDE.md.fleet-backup")" "# first"
echo x | run claude set --local file scripts/new.sh >/dev/null; echo y | run claude set --local file scripts/new.sh >/dev/null
assert_eq "a script's backup is not a file row"        "$(run claude --local | jq -r '[.items[] | select(.name | endswith(".fleet-backup"))] | length')" "0"
assert_contains "set file refuses paths out of ~/.claude" "$(echo x | run claude set --local file ../evil 2>&1)" "CLAUDE.md or scripts/<name>"
assert_contains "  ...and into subfolders"             "$(echo x | run claude set --local file scripts/a/b 2>&1)" "CLAUDE.md or scripts/<name>"
assert_contains "set refuses an unknown kind"          "$(echo x | run claude set --local skill foo 2>&1)" "unknown kind"
: > "$SHIM_LOG"; run claude unset --local plugin new@official >/dev/null
assert_eq "unset plugin uninstalls it"                 "$(jq -r '.enabledPlugins | has("new@official")' "$C/settings.json")" "false"
assert_contains "  ...via claude plugin uninstall"     "$(cat "$SHIM_LOG")" "claude plugin uninstall new@official --scope user"
assert_contains "unset marketplace with plugins enabled is refused" "$(run claude unset --local marketplace official 2>&1)" "remove them first"
run claude unset --local marketplace extras >/dev/null
assert_eq "unset marketplace"                          "$(jq -r 'has("extras")' "$C/plugins/known_marketplaces.json")" "false"
run claude unset --local mcp example >/dev/null
assert_eq "unset mcp"                                  "$(jq -r '.mcpServers | has("example")' "$T/home/.claude.json")" "false"
run claude unset --local setting permissions.defaultMode >/dev/null
assert_eq "unset setting"                              "$(jq -r '.permissions | has("defaultMode")' "$C/settings.json")" "false"
assert_contains "unset refuses fleet's own keys"       "$(run claude unset --local setting statusLine 2>&1)" "not a setting fleet compares"
assert_eq "  ...and statusLine is still there"         "$(jq -r '.statusLine.command' "$C/settings.json")" "x"
run claude unset --local perm "allow:$R" >/dev/null
assert_eq "unset perm removes that rule only"          "$(jq -r '.permissions.allow | length' "$C/settings.json")" "2"
run claude unset --local file scripts/new.sh >/dev/null
assert_false "unset file removes it"                   test -e "$C/scripts/new.sh"
# Put the laptop back the way Task 4's tests expect it.
jq '.effortLevel = "high" | .permissions.defaultMode = "auto"' "$C/settings.json" > "$C/s.tmp" && mv "$C/s.tmp" "$C/settings.json"
echo "# laptop rules" > "$C/CLAUDE.md"

H2=(FLEET_HOSTS="laptop studio")
O=$(renv "${H2[@]}" -- claude copy plugin superpowers@official --from this --to studio 2>&1)
assert_contains "copy plugin reports each target"      "$O" "ok    plugin superpowers@official -> studio"
assert_eq "  ...and studio has it enabled"             "$(jq -r '.enabledPlugins["superpowers@official"]' "$RH/.claude/settings.json")" "true"
renv "${H2[@]}" -- claude copy plugin t@tools --from laptop --to studio >/dev/null 2>&1
assert_eq "copy plugin brings its marketplace along"   "$(jq -r '.tools.source.repo' "$RH/.claude/plugins/known_marketplaces.json")" "acme/tools"
assert_eq "  ...then the plugin"                       "$(jq -r '.enabledPlugins["t@tools"]' "$RH/.claude/settings.json")" "true"
O=$(renv "${H2[@]}" -- claude copy mcp xcode --from studio --to this 2>&1)
assert_eq "copy mcp moves the entry verbatim, secret included" "$(jq -c .mcpServers.xcode "$T/home/.claude.json")" '{"type":"stdio","command":"/usr/bin/xcrun","args":["mcpbridge"],"env":{"TOKEN":"sekrit-studio"}}'
assert_lacks "  ...without printing it"                "$O" "sekrit"
renv "${H2[@]}" -- claude copy setting effortLevel --from studio --to all >/dev/null 2>&1
assert_eq "copy setting --to all"                      "$(jq -r .effortLevel "$T/home/.claude/settings.json")" "medium"
renv "${H2[@]}" -- claude copy perm "allow:Bash(echo 'it''s')" --from laptop --to studio >/dev/null 2>&1
assert_eq "copy perm over ssh keeps the quotes"        "$(jq -r --arg r "Bash(echo 'it''s')" 'any(.permissions.allow[]; . == $r)' "$RH/.claude/settings.json")" "true"
assert_eq "  ...added to studio's own rules"           "$(jq -r '.permissions.allow | length' "$RH/.claude/settings.json")" "2"
renv "${H2[@]}" -- claude copy file scripts/render.py --from this --to studio >/dev/null 2>&1
assert_true "copy file: same content"                  cmp "$T/home/.claude/scripts/render.py" "$RH/.claude/scripts/render.py"
assert_eq "  ...still executable"                      "$(stat -f %Lp "$RH/.claude/scripts/render.py")" "755"
O=$(renv "${H2[@]}" -- claude copy mcp nope --from laptop --to studio 2>&1); RC=$?
assert_contains "copy of something the source lacks"   "$O" "no mcp 'nope' on laptop"
assert_eq "  ...exits 1"                               "$RC" "1"
O=$(renv "${H2[@]}" FAKE_CLAUDE_REFUSE=only-studio@official -- claude copy plugin only-studio@official --from studio --to this 2>&1); RC=$?
assert_contains "a refused plugin install fails that target" "$O" "FAIL  plugin only-studio@official -> laptop"
assert_contains "  ...saying to do it by hand"         "$O" "by hand"
assert_eq "  ...and exits 1"                           "$RC" "1"
assert_contains "copy needs --from and --to"           "$(renv "${H2[@]}" -- claude copy plugin x 2>&1)" "usage: fleet claude copy"
assert_contains "copy rejects an unknown host"         "$(renv "${H2[@]}" -- claude copy plugin x --from laptop --to nosuch 2>&1)" "unknown host"
assert_eq "after copying, those rows agree"            "$(renv "${H2[@]}" -- claude --json | jq -r '[.items[] | select(.name == "effortLevel" or .name == "t@tools" or .name == "xcode") | .differs] | unique | join(",")')" "false"
assert_contains "rm without -y and no tty refuses"     "$(renv "${H2[@]}" -- claude rm setting effortLevel all 2>&1 </dev/null)" "without -y"
assert_eq "  ...and leaves it"                         "$(jq -r .effortLevel "$RH/.claude/settings.json")" "medium"
O=$(renv "${H2[@]}" -- claude rm -y setting effortLevel all 2>&1)
assert_contains "rm -y all removes it everywhere"      "$O" "ok    removed setting effortLevel on studio"
assert_eq "  ...here"                                  "$(jq -r 'has("effortLevel")' "$T/home/.claude/settings.json")" "false"
assert_eq "  ...and there"                             "$(jq -r 'has("effortLevel")' "$RH/.claude/settings.json")" "false"
assert_contains "rm of a marketplace in use fails that host" "$(renv "${H2[@]}" -- claude rm -y marketplace tools studio 2>&1)" "remove them first"
assert_contains "rm rejects an unknown kind"           "$(renv "${H2[@]}" -- claude rm -y skill x studio 2>&1)" "unknown kind"

O=$(renv FLEET_HOSTS="laptop studio" -- doctor 2>&1)
assert_contains "doctor across Macs says the Claude setups differ" "$O" "claude setup differs on"
assert_contains "  ...pointing at fleet claude --diff" "$O" "(fleet claude --diff)"
assert_lacks "doctor <host> does not"                   "$(renv FLEET_HOSTS="laptop studio" -- doctor studio 2>&1)" "claude setup"

# Review fixes.
mkdir -p "$T/leak"; printf '{"mcpServers":{"s":{"type":"http","url":"https://user:tok999@mcp.x.dev:8443/p?key=abc"},"q":{"type":"http","url":"https://h.dev?token=qqq"},"n":{"type":"http","url":5}}}' > "$T/leak/.claude.json"
L=$(renv HOME="$T/leak" -- claude --local)
assert_eq "an mcp summary is only the URL's host"      "$(printf '%s' "$L" | jq -r '[.items[] | select(.name=="s" or .name=="q") | .summary] | sort | join(",")')" "http h.dev,http mcp.x.dev"
assert_lacks "  ...no userinfo token"                  "$L" "tok999"
assert_lacks "  ...no query token"                     "$L" "qqq"
assert_eq "  ...and a url that is not a string does not break the snapshot" "$(printf '%s' "$L" | jq -r '.items[] | select(.name=="n") | .kind')" "mcp"
cp "$RH/.claude/plugins/known_marketplaces.json" "$T/km.bak"
jq '.tools = {source: {source: "github", repo: "other/tools"}}' "$T/km.bak" > "$RH/.claude/plugins/known_marketplaces.json"
O=$(renv "${H2[@]}" -- claude copy marketplace tools --from this --to studio 2>&1); RC=$?
assert_contains "copy marketplace onto a different source fails" "$O" "tools on studio comes from other/tools"
assert_eq "  ...exits 1"                               "$RC" "1"
assert_contains "  ...but copying a plugin still uses the marketplace that is there" "$(renv "${H2[@]}" -- claude copy plugin t@tools --from this --to studio 2>&1)" "ok    plugin t@tools -> studio"
cp "$T/km.bak" "$RH/.claude/plugins/known_marketplaces.json"
assert_contains "copy marketplace with the same source is ok" "$(renv "${H2[@]}" -- claude copy marketplace tools --from this --to studio 2>&1)" "ok    marketplace tools -> studio"
mkdir -p "$T/corrupt/.claude/plugins"; printf '{"enabledPlugins":{"a@m":tr' > "$T/corrupt/.claude/settings.json"
printf '{"m":{"source":{"source":"github","repo":"acme/m"}}}' > "$T/corrupt/.claude/plugins/known_marketplaces.json"
assert_contains "unset marketplace refuses while settings.json is not JSON" "$(renv HOME="$T/corrupt" -- claude unset --local marketplace m 2>&1)" "not valid JSON"
assert_eq "  ...and keeps the marketplace"             "$(jq -r 'has("m")' "$T/corrupt/.claude/plugins/known_marketplaces.json")" "true"
mkdir -p "$T/lnk/.claude" "$T/dotfiles"; echo "# dotfiles" > "$T/dotfiles/CLAUDE.md"; ln -s "$T/dotfiles/CLAUDE.md" "$T/lnk/.claude/CLAUDE.md"
assert_contains "set file refuses to replace a symlink" "$(echo new | renv HOME="$T/lnk" -- claude set --local file CLAUDE.md 2>&1)" "symlink"
assert_true "  ...which is still a link"               test -L "$T/lnk/.claude/CLAUDE.md"
assert_eq "  ...to the unchanged file"                 "$(cat "$T/dotfiles/CLAUDE.md")" "# dotfiles"
O=$(renv "${H2[@]}" -- claude rm -y mcp nowhere all 2>&1); RC=$?
assert_contains "rm of something a Mac does not have is not a failure" "$O" "ok    mcp nowhere not on studio"
assert_eq "  ...exit 0"                                "$RC" "0"
: > "$SHIM_LOG"
assert_contains "names starting with - are refused"   "$(run claude unset --local plugin -y 2>&1)" "cannot start with -"
assert_lacks "  ...and never reach claude"             "$(cat "$SHIM_LOG")" "uninstall"
assert_contains "  ...in copy too"                     "$(renv "${H2[@]}" -- claude copy plugin --yes --from this --to studio 2>&1)" "cannot start with -"

# Permission rules are many and matter less: hidden unless asked for.
TB=$(renv "${H2[@]}" -- claude)
assert_lacks "the table hides permission rules"        "$TB" "allow:"
assert_contains "  ...summing them up in one line"     "$TB" "2 rules differ, 1 the same (fleet claude --kind perm)"
assert_contains "--diff sums up the rules that differ" "$(renv "${H2[@]}" -- claude --diff)" "2 rules differ (fleet claude --diff --kind perm)"
TK=$(renv "${H2[@]}" -- claude --kind perm)
assert_contains "--kind perm shows the rules"          "$TK" "allow:Bash(ls:*)"
assert_lacks "  ...and nothing else"                   "$TK" "plugin"
assert_eq "--kind takes a list and filters --json too" "$(renv "${H2[@]}" -- claude --json --kind plugin,mcp | jq -r '[.items[].kind] | unique | join(",")')" "mcp,plugin"
assert_eq "--json alone still carries the rules"      "$(renv "${H2[@]}" -- claude --json | jq '[.items[] | select(.kind=="perm")] | length')" "3"
assert_contains "--kind rejects an unknown kind"       "$(renv "${H2[@]}" -- claude --kind skill 2>&1)" "unknown kind"
assert_contains "--kind needs a value"                 "$(renv "${H2[@]}" -- claude --kind 2>&1)" "usage: fleet claude"
assert_contains "doctor counts rules apart"            "$(renv "${H2[@]}" -- doctor 2>&1)" "and 2 permission rule(s) (fleet claude --diff)"

section "demo-fleet (the app's stand-in)"
DEMO="$HERE/../docs/demo-fleet"
D=$(PATH="/usr/bin:/bin" "$DEMO" claude --json)
assert_eq "demo-fleet claude --json has the CLI's shape" \
  "$(printf '%s' "$D" | jq -r '[(.hosts | length > 1), (.down | type == "object"), all(.items[]; (.kind | type) == "string" and (.name | type) == "string" and (.differs | type) == "boolean" and (.cells | type) == "object")] | all')" "true"
assert_eq "  ...a cell is null or {digest, summary}"  "$(printf '%s' "$D" | jq -r '[.items[].cells[] | select(. != null) | (.digest | length >= 4) and (.summary | type) == "string"] | all')" "true"
assert_eq "  ...never a value field"                   "$(printf '%s' "$D" | jq -r '[.. | objects | has("value")] | any')" "false"
assert_eq "  ...differs agrees with the cells"        "$(printf '%s' "$D" | jq -r 'all(.items[]; .differs == ([.cells[] | if . == null then null else .digest end] | unique | length > 1))')" "true"
assert_eq "  ...with every kind"                      "$(printf '%s' "$D" | jq -r '[.items[].kind] | unique | join(",")')" "file,marketplace,mcp,perm,plugin,setting"

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

section "MCP servers that plugins provide"
PH="$T/ph/.claude"; mkdir -p "$PH/plugins/cache/sp/.claude-plugin" "$PH/plugins/cache/mp" "$PH/plugins/cache/offp/.claude-plugin"
printf '{"enabledPlugins":{"sp@official":true,"mp@official":true,"offp@official":false}}' > "$PH/settings.json"
printf '{"version":2,"plugins":{"sp@official":[{"installPath":"%s"}],"mp@official":[{"installPath":"%s"}],"offp@official":[{"installPath":"%s"}]}}' \
  "$PH/plugins/cache/sp" "$PH/plugins/cache/mp" "$PH/plugins/cache/offp" > "$PH/plugins/installed_plugins.json"
printf '{"name":"sp","mcpServers":{"sentry":{"type":"http","url":"https://mcp.sentry.dev/mcp?utm_source=plugin","headers":{"Authorization":"Bearer sekrit-plugin"}}}}' > "$PH/plugins/cache/sp/.claude-plugin/plugin.json"
printf '{"mcpServers":{"linear":{"type":"http","url":"https://mcp.linear.app/mcp"}}}' > "$PH/plugins/cache/mp/.mcp.json"
printf '{"name":"offp","mcpServers":{"offsrv":{"type":"stdio","command":"x"}}}' > "$PH/plugins/cache/offp/.claude-plugin/plugin.json"
printf '{"mcpServers":{"linear":{"type":"http","url":"https://mcp.linear.app/mcp"}}}' > "$T/ph/.claude.json"
PS=$(renv HOME="$T/ph" -- claude --local)
assert_eq "an enabled plugin's MCP server is a row, marked with its plugin" \
  "$(printf '%s' "$PS" | jq -r '.items[] | select(.kind=="mcp" and .name=="sentry") | "\(.plugin) / \(.summary)"')" "sp@official / via sp plugin"
assert_eq "  ...read from .mcp.json too; a standalone entry of the same name wins" \
  "$(printf '%s' "$PS" | jq -r '.items[] | select(.kind=="mcp" and .name=="linear") | "\(.plugin) / \(.summary)"')" "null / http mcp.linear.app (also via mp plugin)"
assert_eq "  ...a disabled plugin's servers are not"     "$(printf '%s' "$PS" | jq -r '[.items[] | select(.name=="offsrv")] | length')" "0"
assert_lacks "  ...and its secrets stay home"           "$PS" "sekrit-plugin"
PM=$(renv HOME="$T/ph" FLEET_HOSTS="laptop studio" -- claude --json)
assert_eq "via a plugin here, standalone there: the row differs and the cell names the plugin" \
  "$(printf '%s' "$PM" | jq -r '.items[] | select(.kind=="mcp" and .name=="sentry") | "\(.differs) \(.cells.laptop.plugin) \(.cells.studio.plugin)"')" "true sp@official null"
O=$(renv HOME="$T/ph" FLEET_HOSTS="laptop studio" -- claude copy mcp sentry --from laptop --to studio 2>&1); RC=$?
assert_contains "copying a plugin's server says to copy the plugin" "$O" "sentry on laptop comes from the sp@official plugin"
assert_contains "  ...with the command"                  "$O" "fleet claude copy plugin sp@official"
assert_eq "  ...and exits 1"                             "$RC" "1"
assert_contains "rm of a server a Mac has only through a plugin is 'not on'" \
  "$(renv HOME="$T/ph" FLEET_HOSTS="laptop studio" -- claude rm -y mcp sentry laptop 2>&1)" "ok    mcp sentry not on laptop"

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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
