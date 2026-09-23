# `fleet claude` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `fleet claude` shows how the Claude Code setup (plugins, marketplaces, MCP servers, settings, permission rules, global files) differs across the Macs, and `fleet claude copy|rm` reconciles one item at a time.

**Architecture:** Each Mac reports a normalized snapshot (`fleet claude --local`, JSON, secrets only as digests). The control Mac fans out with the existing `gather_into`/`host_fetch` and merges the snapshots into a matrix. `copy` reads one item's full value from the source Mac (`claude get --local`) and pipes it into `claude set --local` on each target. `set`/`unset` apply it through Claude Code's own CLI (`claude plugin …`, `claude mcp …`) or a jq edit of `settings.json`, or by writing the file.

**Tech Stack:** bash 3.2 (single file `fleet`), jq 1.7, `/usr/bin/perl` Digest::SHA (what `shasum` is built on), `claude` CLI on the target.

**Spec:** `docs/superpowers/specs/2026-09-23-claude-setup-alignment-design.md`

## Global Constraints

- One file, `fleet`, runs under `/bin/bash` 3.2 and Homebrew bash 5. No `mapfile`, `declare -A`, `${var,,}`, `&>`, `|&`, `;&`, `printf -v`, `readlink -f`. No `case` inside `$(...)` inside double quotes.
- `set -euo pipefail` is on. `shellcheck fleet` stays clean; every suppression carries a reason on the same line.
- Padding goes through `pad` (bash 3.2 `printf %-Ns` pads by bytes).
- Colours only when stdout is a tty (`$DIM`, `$BOLD`, `$YELLOW`, `$RESET` are already empty otherwise).
- Every value embedded in a shell string goes through `shq`. Item values travel on stdin, never on the ssh command line.
- Remote commands go through `run_on` (which uses `with_path`); never `ssh host 'fleet …'` directly.
- Secrets (`mcp` entries, the `env` setting) never appear in `--local`, `--json` or table output; only a digest does.
- Nothing is applied automatically, and fleet never passes `-y`/`--yes`/`--accept-command` to `claude plugin install`.
- No real machine or project names in the repo (it is going public): tests and docs use laptop/studio/mini/air.
- Run `test/run.sh` before every commit; it must end `0 failed`.

## Review Focus

1. **A settings.json or ~/.claude.json that is not JSON** (half-written by Claude Code): the snapshot must still print valid JSON with an `error` item, and `set`/`unset` must refuse rather than overwrite. Tests are in Task 1 (snapshot) and Task 3 (set refuses).
2. **Permission rules full of quotes, parentheses and colons** (`Bash(echo 'it''s')`, `Bash(git log:*)`): they must survive `shq`, the `allow:` split on the first colon only, ssh, and jq. Tests are in Task 3 (local) and Task 4 (over ssh).
3. **`rm`/`unset` of something fleet owns or that holds other things**: `hooks`, `statusLine`, `permissions` as a whole, and a marketplace whose plugins are still enabled must be refused. Tests are in Task 3.
4. **A plugin value `false`** (disabled): jq's `//` treats `false` as missing. Get, snapshot and set must keep "disabled" distinct from "absent". Tests are in Task 1 and Task 3.
5. **Backups written next to scripts** (`scripts/x.fleet-backup`) must not show up as new `file` rows and then be copied around. Test is in Task 3.

---

## File Structure

- Modify `fleet`:
  - `gather_into` (line ~462) takes an optional third argument, the per-host fetch function (default `host_status`).
  - A new section `# ---- claude setup` goes directly after `cmd_models` (line ~1050). It holds every `claude_*` function and `cmd_claude`.
  - `cmd_doctor` (line ~1545) gains the drift line.
  - `usage` and the dispatch `case` at the bottom each gain a `claude` entry.
- Modify `test/shims/claude`: the fake now edits the fake HOME's files for `plugin`/`mcp` subcommands.
- Modify `test/run.sh`: a new `section "claude setup"` just before the final `printf '\n%d passed…'`, so it runs after every other section and cannot disturb their `$T/home/.claude/settings.json`.
- Modify `CLAUDE.md`, `README.md`, `SECURITY.md`: document the command (Task 5).

---

### Task 1: The snapshot, `fleet claude --local`

**Files:**
- Modify: `fleet` (new section after `cmd_models`; dispatch and usage at the bottom)
- Modify: `test/run.sh` (new section before the final summary)

**Interfaces:**
- Produces:
  - `CLAUDE_KINDS="marketplace plugin mcp setting perm file"`
  - `CLAUDE_SKIP_KEYS` (space-separated settings keys never compared)
  - `claude_src <file>`: prints the path if it is a JSON object, else `/dev/null`
  - `claude_sha`: stdin lines to sha256 hex lines
  - `claude_snapshot_local`: prints `{"version":1,"items":[{kind,name,value,summary,digest[,exec]}]}`
  - `cmd_claude`, which for now handles only `--local`

- [ ] **Step 1: Write the failing tests**

Add this section to `test/run.sh` directly before the final `printf '\n%d passed, %d failed\n'` line:

```bash
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
```

- [ ] **Step 2: Run the tests and check they fail**

Run: `test/run.sh 2>&1 | tail -20`
Expected: the new assertions FAIL (`fleet: unknown command "claude"`), and every older assertion still passes.

- [ ] **Step 3: Implement the snapshot**

In `fleet`, directly after the closing `}` of `cmd_models`, add:

```bash
# ---------------------------------------------------------------- claude setup
#
# `fleet claude`: how the Claude Code setup differs across the Macs, item by
# item, and `copy`/`rm` to reconcile one item (see
# docs/superpowers/specs/2026-09-23-claude-setup-alignment-design.md). There
# is no reference setup: every Mac is a peer and the owner picks per item.
# Each Mac reports its own snapshot (`claude --local`); mcp entries and the
# env setting may hold tokens, so they leave a Mac only as a digest, except
# when `copy` moves one on request. Kinds, in display order:
#   marketplace  known_marketplaces.json    plugin  enabledPlugins
#   mcp          ~/.claude.json mcpServers  setting settings.json keys
#   perm         one permissions rule       file    CLAUDE.md, scripts/*

CLAUDE_KINDS="marketplace plugin mcp setting perm file"
# settings.json keys that are not compared: fleet's own (install sets them),
# the ones plugin/marketplace/perm rows cover, and bookkeeping Claude Code
# writes itself (so is any key ending in State, Cache or Timestamp).
CLAUDE_SKIP_KEYS="hooks statusLine \$schema enabledPlugins extraKnownMarketplaces permissions feedbackSurveyState"

claude_valid_kind() { [ -n "$1" ] && case " $CLAUDE_KINDS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# claude_src <file>: the file if it holds a JSON object, else /dev/null, so
# jq --slurpfile never fails on a missing or half-written file.
claude_src() { if [ -f "$1" ] && jq -e 'type == "object"' "$1" >/dev/null 2>&1; then printf '%s' "$1"; else printf /dev/null; fi; }

# One sha256 per stdin line, in one process (shasum is this same perl module).
claude_sha() { /usr/bin/perl -MDigest::SHA=sha256_hex -ne 'chomp; print sha256_hex($_), "\n"'; }

# The jq behind the snapshot. canon = sorted-keys JSON text, what the digest is of.
# shellcheck disable=SC2016  # $s, $u, $m, $skip, $bad are jq variables
CLAUDE_SNAPSHOT_JQ='
def canon: walk(if type == "object" then to_entries | sort_by(.key) | from_entries else . end) | tojson;
def clip($n): if length > $n then .[0:$n - 1] + "…" else . end;
def shown: if type == "string" then . else tojson end | clip(12);
($s[0] // {}) as $s | ($u[0] // {}) as $u | ($m[0] // {}) as $m | ($skip | split(" ")) as $skip
| [ ($m | to_entries[] | {kind: "marketplace", name: .key, value: .value.source,
        summary: (.value.source | (.repo // .url // .path // .source // "") | tostring)}),
    ($s.enabledPlugins // {} | to_entries[]
      | {kind: "plugin", name: .key, value: (if .value == true then "enabled" else "disabled" end)} | .summary = .value),
    ($u.mcpServers // {} | to_entries[]
      | {kind: "mcp", name: .key, value: null, secret: .value,
         summary: ((.value.type // "stdio") + " "
           + (if .value.url then (.value.url | sub("^[a-z]+://"; "") | sub("/.*$"; ""))
              else (.value.command // "" | sub("^.*/"; "")) end))}),
    ($s | to_entries[] | select(.key as $k | ($skip | index([$k]) | not) and ($k | test("(State|Cache|Timestamp)$") | not))
      | if .key == "env" then {kind: "setting", name: "env", value: null, secret: .value, summary: ""}
        else {kind: "setting", name: .key, value: .value, summary: (.value | shown)} end),
    ($s.permissions // {} | to_entries[]
      | if (.key == "allow" or .key == "deny" or .key == "ask") and (.value | type) == "array"
        then .key as $l | .value[] | select(type == "string") | {kind: "perm", name: "\($l):\(.)", value: true, summary: ""}
        else {kind: "setting", name: "permissions.\(.key)", value: .value, summary: (.value | shown)} end),
    ($bad | split("\n")[] | select(length > 0) | {kind: "error", name: ., value: null, summary: "not JSON"})
  ]
| map(.canon = ((if has("secret") then .secret else .value end) | canon) | del(.secret))'

# This Mac's Claude setup as {"version":1,"items":[...]}: the wire format
# `fleet claude` asks every host for. Needs only jq and perl, like status.
claude_snapshot_local() {
  local s="$HOME/.claude/settings.json" u="$HOME/.claude.json" m="$HOME/.claude/plugins/known_marketplaces.json"
  local f bad="" items digests files='[]' x
  for f in "$s" "$u" "$m"; do
    if [ -f "$f" ] && ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then bad="$bad${f#"$HOME"/}
"; fi
  done
  items=$(jq -nc --slurpfile s "$(claude_src "$s")" --slurpfile u "$(claude_src "$u")" --slurpfile m "$(claude_src "$m")" \
            --arg skip "$CLAUDE_SKIP_KEYS" --arg bad "$bad" "$CLAUDE_SNAPSHOT_JQ")
  digests=$(printf '%s' "$items" | jq -r '.[].canon' | claude_sha)
  for f in "$HOME/.claude/CLAUDE.md" "$HOME/.claude/scripts"/*; do
    [ -f "$f" ] || continue
    case "$f" in *.fleet-backup) continue ;; esac   # copy's own backups are not setup
    if [ -x "$f" ]; then x=true; else x=false; fi
    files=$(printf '%s' "$files" | jq -c --arg n "${f#"$HOME"/.claude/}" --arg d "$(shasum -a 256 < "$f" | cut -c1-64)" \
              --argjson size "$(wc -c < "$f" | tr -d ' ')" --argjson x "$x" \
              '. + [{kind: "file", name: $n, value: null, summary: "\($size) bytes", digest: $d, exec: $x}]')
  done
  jq -nc --argjson items "$items" --arg d "$digests" --argjson files "$files" \
    '($d | split("\n")) as $ds | {version: 1, items: ([$items | to_entries[] | .value + {digest: $ds[.key]} | del(.canon)] + $files)}'
}
```

`claude_sha` is only for the one-line canon strings; whole files are hashed with `shasum -a 256`.

Then add the command entry point below it:

```bash
cmd_claude() {
  case "${1:-}" in
    --local) claude_snapshot_local; return 0 ;;
  esac
  die "usage: fleet claude [--json] [--diff] [host...]"
}
```

In the dispatch `case` at the bottom of `fleet`, after `models)   cmd_models "$@" ;;`, add:

```bash
  claude)   cmd_claude "$@" ;;
```

- [ ] **Step 4: Run the tests and check they pass**

Run: `test/run.sh 2>&1 | tail -5` then `shellcheck fleet`
Expected: `0 failed`, and no shellcheck output. If shellcheck flags `A && B || die` (SC2015), rewrite it as `if ! { A && B; }; then die …; fi`; the same applies in later tasks.

- [ ] **Step 5: Commit**

```bash
git add fleet test/run.sh
git commit -m "claude --local: this Mac's Claude setup as a snapshot, secrets as digests"
```

---

### Task 2: The matrix, `fleet claude [--json] [--diff] [host...]`

**Files:**
- Modify: `fleet` (`gather_into`; the claude section; `usage`)
- Modify: `test/run.sh` (claude setup section)

**Interfaces:**
- Consumes: `claude_snapshot_local`, `CLAUDE_KINDS` (Task 1); `host_fetch`, `down_hosts`, `down_reasons`, `pad`, `hosts_line` (existing).
- Produces:
  - `gather_into <dir> <mode> [fetch-fn]`: `fetch-fn` is called as `fn <host> <dir> <mode>`.
  - `claude_fetch <host> <dir>`
  - `claude_host <name>`: prints the host (`this` becomes FLEET_SELF), dies if the name is not in FLEET_HOSTS
  - `claude_matrix <dir>`: prints `{hosts:[up hosts], down:{host:reason}, items:[{kind,name,differs,cells:{host: null|{digest,summary[,value][,exec]}}}]}`
  - `claude_table <json>`

- [ ] **Step 1: Write the failing tests**

Append to the claude setup section of `test/run.sh`:

```bash
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
```

- [ ] **Step 2: Run the tests and check they fail**

Run: `test/run.sh 2>&1 | tail -20`
Expected: the new assertions FAIL with `usage: fleet claude`.

- [ ] **Step 3: Implement**

Change `gather_into` in `fleet` so the fetch function is a parameter:

```bash
gather_into() {   # <dir> [--managed] [fetch-fn]: fetch-fn <host> <dir> <mode> (default host_status)
  local h pids="" spin="" fn="${3:-host_status}"
  [ -n "${FLEET_HOSTS// /}" ] || die "no hosts yet: fleet hosts add   (see fleet doctor)"
  for h in $FLEET_HOSTS; do
    "$fn" "$h" "$1" "${2:-}" & pids="$pids $!"
  done
```

(Leave the rest of the function as it is.)

In the claude section, after `claude_snapshot_local`, add:

```bash
claude_fetch() { host_fetch "$1" "$2" claude_snapshot_local "fleet claude --local" "" '{}'; }

claude_host() {   # <name>: `this` is FLEET_SELF; anything else must be in the host list
  local h="$1"; [ "$h" = this ] && h="$FLEET_SELF"
  case " $FLEET_HOSTS " in *" $h "*) [ -n "$h" ] && printf '%s' "$h" && return 0 ;; esac
  die "unknown host '$1'. hosts:$(hosts_line)"
}

# claude_matrix <dir>: the gathered snapshots (<host>.json, <host>.down) as the
# `fleet claude --json` object. Hosts that did not answer get no column.
claude_matrix() {
  local h up="" down
  for h in $FLEET_HOSTS; do [ -e "$1/$h.down" ] || up="$up $h"; done
  down=$(for h in $FLEET_HOSTS; do
      if [ -e "$1/$h.down" ]; then jq -nc --arg h "$h" --arg r "$(cat "$1/$h.down")" '{($h): $r}'; fi
    done | jq -sc 'add // {}')
  for h in $up; do jq -c --arg h "$h" '{host: $h, items: (.items // [])}' "$1/$h.json"; done \
    | jq -sc --argjson down "$down" --arg order "$CLAUDE_KINDS error" '
        ($order | split(" ")) as $order
        | map(.host) as $hosts
        | [ map(.host as $h | .items[] | . + {host: $h}) | group_by([.kind, .name])[]
            | {kind: .[0].kind, name: .[0].name,
               cells: (reduce .[] as $c ({}; .[$c.host] = ($c | {digest, summary}
                        + (if .value != null then {value} else {} end)
                        + (if .exec != null then {exec} else {} end))))}
            | .cells as $c | .cells = (reduce $hosts[] as $h ({}; .[$h] = ($c[$h] // null)))
            | .differs = ([.cells[] | if . == null then null else .digest end] | unique | length > 1) ]
        | sort_by(.kind as $k | [($order | index([$k])), .name]) as $items
        | {hosts: $hosts, down: $down, items: $items}'
}

# claude_table <json>: the matrix for a person. Cells: ● present (plugin
# enabled), ○ plugin disabled, · absent, a setting's value, else the first 4
# of the digest (so equal values look equal). Padding by characters (pad).
claude_table() {
  local tsv i h
  local -a w r
  tsv=$(printf '%s' "$1" | jq -r '
    def clip($n): if length > $n then .[0:$n - 1] + "…" else . end;
    def cell($k; $n): if . == null then "·"
      elif $k == "plugin" then (if .summary == "disabled" then "○" else "●" end)
      elif $k == "perm" then "●"
      elif $k == "error" then "!"
      elif $k == "setting" and $n != "env" then (.summary | if . == "" then "\"\"" else . end)
      else .digest[0:4] end;
    .hosts as $hosts
    | [.items[] | . as $i | [.kind, (.name | clip(40))] + [$hosts[] as $h | $i.cells[$h] | cell($i.kind; $i.name)]] as $rows
    | ([[$rows[] | .[1] | length] | max // 4, 4] | max | tostring) as $nw
    | ([$nw] + [range(0; $hosts | length) as $j | [$hosts[$j], ($rows[] | .[$j + 2])] | map(length) | max | tostring] | @tsv),
      ($rows[] | @tsv)')
  if [ "$(printf '%s' "$1" | jq '.items | length')" -eq 0 ]; then
    printf 'nothing to show on%s\n' "$(printf '%s' "$1" | jq -r '.hosts | map(" " + .) | join("")')"
    return 0
  fi
  {
    IFS=$'\t' read -r -a w
    pad '' 11; printf '  '; pad '' "${w[0]}"
    i=1; for h in $(printf '%s' "$1" | jq -r '.hosts[]'); do printf '  %s' "$BOLD"; pad "$h" "${w[$i]}"; printf '%s' "$RESET"; i=$((i + 1)); done
    echo
    while IFS=$'\t' read -r -a r; do
      pad "${r[0]}" 11; printf '  '; pad "${r[1]}" "${w[0]}"
      i=2; while [ "$i" -lt "${#r[@]}" ]; do printf '  '; pad "${r[$i]}" "${w[$((i - 1))]}"; i=$((i + 1)); done
      echo
    done
  } <<< "$tsv"
}

claude_matrix_cmd() {   # [--json] [--diff] [host...]
  local a h asjson=0 diff=0 hosts="" tmp json
  for a in "$@"; do
    case "$a" in
      --json) asjson=1 ;;
      --diff) diff=1 ;;
      -*) die "usage: fleet claude [--json] [--diff] [host...]" ;;
      *) h=$(claude_host "$a") || exit 1; hosts="$hosts $h" ;;
    esac
  done
  [ -z "$hosts" ] || FLEET_HOSTS="${hosts# }"
  tmp=$(mktemp -d)
  trap 'rm -rf "${tmp:-}"' RETURN
  gather_into "$tmp" "" claude_fetch
  json=$(claude_matrix "$tmp")
  [ "$diff" = 0 ] || json=$(printf '%s' "$json" | jq -c '.items |= map(select(.differs))')
  if [ "$asjson" = 1 ]; then printf '%s\n' "$json"; return 0; fi
  claude_table "$json"
  if [ -n "$(down_hosts "$tmp")" ]; then printf '%snot answering:\n%s%s\n' "$YELLOW" "$(down_reasons "$tmp")" "$RESET"; fi
}
```

A row whose cells are never empty (`·` at least) and whose name is never empty keeps `IFS=$'\t'` safe: no field collapses.

Replace `cmd_claude` with:

```bash
cmd_claude() {
  case "${1:-}" in
    --local) claude_snapshot_local; return 0 ;;
  esac
  claude_matrix_cmd "$@"
}
```

In `usage`, after the `fleet models` line, add:

```
  fleet claude [--json] [--diff] [host...]
                                  how the Claude Code setup (plugins, MCP servers, settings,
                                  permission rules, CLAUDE.md, scripts) differs across the Macs
```

- [ ] **Step 4: Run the tests and check they pass**

Run: `test/run.sh 2>&1 | tail -5` and `shellcheck fleet`
Expected: `0 failed`, and shellcheck is clean. Also run `renv`-free by hand: `FLEET_HOSTS="$(hostname -s)" /bin/bash fleet claude` shows a table of this Mac.

- [ ] **Step 5: Commit**

```bash
git add fleet test/run.sh
git commit -m "fleet claude: the Claude setup matrix across Macs (--json, --diff)"
```

---

### Task 3: Applying one item on this Mac: `claude get|set|unset --local`

**Files:**
- Modify: `test/shims/claude`
- Modify: `fleet` (claude section)
- Modify: `test/run.sh` (claude setup section)

**Interfaces:**
- Consumes: `claude_src`, `claude_valid_kind`, `CLAUDE_SKIP_KEYS` (Task 1).
- Produces:
  - `claude_valid_file <name>`: true for `CLAUDE.md` or `scripts/<n>` (no `/`, no leading `.`)
  - `claude_setting_ok <name>`: false for skipped keys
  - `claude_perm_split <name>`: prints `<list>\t<rule>` or dies
  - `claude_settings_edit <jq args…>`
  - `claude_get_local <kind> <name>`: the value as JSON (file: raw content); exit 1 when absent
  - `claude_set_local <kind> <name> [--exec]`: value on stdin
  - `claude_unset_local <kind> <name>`
  - `cmd_claude get|set|unset --local <kind> <name> [--exec]`

- [ ] **Step 1: Make the fake `claude` act on the fake HOME**

Replace `test/shims/claude` with:

```bash
#!/bin/bash
# Fake claude: logs every call. The `plugin` and `mcp` subcommands fleet uses
# edit $HOME's settings.json, ~/.claude.json and known_marketplaces.json the
# way the real CLI does, so `fleet claude --local` sees the result.
# FAKE_CLAUDE_REFUSE=<plugin>: installing it fails the way a marketplace-
# declared command does when nobody is there to accept it.
echo "claude $*" >> "${SHIM_LOG:-/dev/null}"
S="$HOME/.claude/settings.json" U="$HOME/.claude.json" M="$HOME/.claude/plugins/known_marketplaces.json"
edit() {   # <file> <jq args...>
  local f="$1"; shift
  mkdir -p "$(dirname "$f")"; [ -s "$f" ] || echo '{}' > "$f"
  jq "$@" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
case "${1:-} ${2:-}" in
  "plugin install")
    if [ "$3" = "${FAKE_CLAUDE_REFUSE:-}" ]; then echo "Error: this plugin runs a marketplace-declared command; rerun with --accept-command <sha256>" >&2; exit 1; fi
    edit "$S" --arg p "$3" '.enabledPlugins[$p] = true' ;;
  "plugin uninstall") edit "$S" --arg p "$3" 'del(.enabledPlugins[$p])' ;;
  "plugin enable")    edit "$S" --arg p "$3" '.enabledPlugins[$p] = true' ;;
  "plugin disable")   edit "$S" --arg p "$3" '.enabledPlugins[$p] = false' ;;
  "plugin marketplace")
    case "$3" in
      add)    edit "$M" --arg r "$4" '.[$r | sub("^.*/"; "")] = {source: {source: "github", repo: $r}}' ;;
      remove) edit "$M" --arg n "$4" 'del(.[$n])' ;;
    esac ;;
  # fleet calls: claude mcp add-json -s user <name> <json> / claude mcp remove -s user <name>
  "mcp add-json") edit "$U" --arg n "$5" --argjson v "$6" '.mcpServers[$n] = $v' ;;
  "mcp remove")   edit "$U" --arg n "$5" 'if (.mcpServers // {} | has($n)) then del(.mcpServers[$n]) else error("no MCP server \($n)") end' || exit 1 ;;
esac
exit 0
```

The test setup copies this shim into studio's `$RH/bin` (`cp "$HERE/shims/tmux" "$HERE/shims/claude" "$RH/bin/"`), so studio gets the same behaviour.

- [ ] **Step 2: Write the failing tests**

Append to the claude setup section of `test/run.sh`. These run on the laptop only, against `$T/home`:

```bash
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
```

- [ ] **Step 3: Run the tests and check they fail**

Run: `test/run.sh 2>&1 | tail -30`
Expected: the new assertions FAIL (`get`/`set`/`unset` land in `claude_matrix_cmd`, which calls them unknown hosts).

- [ ] **Step 4: Implement**

Add to the claude section of `fleet`, after `claude_matrix_cmd`:

```bash
claude_valid_file() {   # CLAUDE.md or scripts/<name>: nothing that climbs out of ~/.claude
  case "$1" in
    CLAUDE.md) return 0 ;;
    scripts/*) case "${1#scripts/}" in ''|*/*|.*) return 1 ;; *) return 0 ;; esac ;;
    *) return 1 ;;
  esac
}

claude_setting_ok() {   # a settings key the matrix compares (never fleet's own, never a whole permission list)
  case " $CLAUDE_SKIP_KEYS permissions.allow permissions.deny permissions.ask " in *" $1 "*) return 1 ;; esac
  case "$1" in ''|*State|*Cache|*Timestamp) return 1 ;; *) return 0 ;; esac
}

claude_perm_split() {   # allow:<rule> -> "allow<TAB><rule>" (split on the first colon only)
  local l="${1%%:*}" r="${1#*:}"
  case "$l" in allow|deny|ask) ;; *) die "perm names are allow:<rule>, deny:<rule> or ask:<rule>" ;; esac
  [ "$r" != "$1" ] && [ -n "$r" ] || die "perm names are allow:<rule>, deny:<rule> or ask:<rule>"
  printf '%s\t%s' "$l" "$r"
}

# jq path of a setting name: permissions.<k> is that subkey, anything else top level.
# shellcheck disable=SC2016  # $n is a jq variable
CLAUDE_SETTING_PATH='(if ($n | startswith("permissions.")) then ["permissions", $n[12:]] else [$n] end)'

# claude_settings_edit <jq args...>: rewrite ~/.claude/settings.json through
# jq, the way install_hooks does: refuse a file that is not JSON, back it up
# once (settings.json.fleet-backup), write a temp file and move it in place.
claude_settings_edit() {
  local f="$HOME/.claude/settings.json" tmp
  mkdir -p "$(dirname "$f")"
  [ -s "$f" ] || echo '{}' > "$f"
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || die "$f is not valid JSON; fix it by hand first"
  [ -e "$f.fleet-backup" ] || cp "$f" "$f.fleet-backup"
  tmp=$(mktemp "$f.XXXXXX")
  jq "$@" "$f" > "$tmp" || { rm -f "$tmp"; die "could not edit $f"; }
  mv "$tmp" "$f"
}

# claude_get_local <kind> <name>: the item's full value as JSON (a file: its
# content), secrets included: this is what `copy` sends. Exit 1 when absent.
claude_get_local() {
  local k="$1" n="$2" s="$HOME/.claude/settings.json" out="" lr
  case "$k" in
    file)
      claude_valid_file "$n" && [ -f "$HOME/.claude/$n" ] || return 1
      cat "$HOME/.claude/$n"; return 0 ;;
    marketplace)
      out=$(jq -c --arg n "$n" 'if has($n) then .[$n].source else empty end' "$(claude_src "$HOME/.claude/plugins/known_marketplaces.json")") ;;
    plugin)   # false is "disabled", not absent: no // here
      out=$(jq -c --arg n "$n" '(.enabledPlugins // {}) | if has($n) then (if .[$n] == true then "enabled" else "disabled" end) else empty end' "$(claude_src "$s")") ;;
    mcp)
      out=$(jq -c --arg n "$n" '(.mcpServers // {}) | if has($n) then .[$n] else empty end' "$(claude_src "$HOME/.claude.json")") ;;
    setting)
      claude_setting_ok "$n" || return 1
      out=$(jq -c --arg n "$n" "$CLAUDE_SETTING_PATH as \$p | getpath(\$p) | if . == null then empty else . end" "$(claude_src "$s")") ;;
    perm)
      lr=$(claude_perm_split "$n") || return 1
      out=$(jq -c --arg l "${lr%%	*}" --arg r "${lr#*	}" 'if any(.permissions[$l]? // [] | .[]; . == $r) then true else empty end' "$(claude_src "$s")") ;;
  esac
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

claude_file_put() {   # <name> [--exec]: content on stdin -> ~/.claude/<name>
  local f="$HOME/.claude/$1" tmp
  claude_valid_file "$1" || die "files are CLAUDE.md or scripts/<name>"
  mkdir -p "$(dirname "$f")"
  [ ! -e "$f" ] || [ -e "$f.fleet-backup" ] || cp -p "$f" "$f.fleet-backup"
  tmp=$(mktemp "$f.XXXXXX")
  cat > "$tmp"
  if [ "${2:-}" = --exec ]; then chmod 755 "$tmp"; else chmod 644 "$tmp"; fi
  mv "$tmp" "$f"
  echo "wrote ~/.claude/$1"
}

# claude_run <what> <cmd...>: run a claude CLI command, dying with its last line.
claude_run() {
  local what="$1" out; shift
  command -v claude >/dev/null 2>&1 || die "claude not found on $FLEET_SELF (PATH=$PATH)"
  out=$("$@" 2>&1) || die "$what: $(printf '%s\n' "$out" | tail -1)"
}

# claude_set_local <kind> <name> [--exec]: make this Mac's item equal to the
# value on stdin (JSON; a file's raw content). Plugins, marketplaces and MCP
# servers go through Claude Code's own CLI; settings and rules through jq.
claude_set_local() {
  local k="$1" n="$2" v src cur lr
  if [ "$k" = file ]; then claude_file_put "$n" "${3:-}"; return 0; fi
  v=$(cat)
  [ "$k" = perm ] && v=true   # a rule's value is its presence
  printf '%s' "$v" | jq -e . >/dev/null 2>&1 || die "not JSON on stdin"
  case "$k" in
    marketplace)
      if claude_get_local marketplace "$n" >/dev/null; then echo "marketplace $n already known"; return 0; fi
      src=$(printf '%s' "$v" | jq -r 'if .source == "github" then .repo elif .source == "git" or .source == "url" then .url else "" end // ""')
      [ -n "$src" ] || die "marketplace $n comes from a local path; add it on $FLEET_SELF by hand (claude plugin marketplace add <path>)"
      claude_run "claude plugin marketplace add $src" claude plugin marketplace add "$src"
      echo "added marketplace $n" ;;
    plugin)
      case "$v" in '"enabled"'|'"disabled"') ;; *) die "a plugin's value is \"enabled\" or \"disabled\"" ;; esac
      if ! claude_get_local plugin "$n" >/dev/null; then
        claude_run "claude plugin install $n (install it on $FLEET_SELF by hand)" claude plugin install "$n" --scope user
      fi
      cur=$(claude_get_local plugin "$n" || true)
      if [ "$cur" != "$v" ]; then
        if [ "$v" = '"disabled"' ]; then claude_run "claude plugin disable $n" claude plugin disable "$n" --scope user
        else claude_run "claude plugin enable $n" claude plugin enable "$n" --scope user; fi
      fi
      echo "plugin $n ${v//\"/}" ;;
    mcp)
      claude mcp remove -s user "$n" >/dev/null 2>&1 || true
      claude_run "claude mcp add-json $n" claude mcp add-json -s user "$n" "$v"
      echo "added MCP server $n"
      case "$(printf '%s' "$v" | jq -r '.type // "stdio"')" in
        http|sse) echo "if it signs in (OAuth), authenticate it on $FLEET_SELF with /mcp" ;;
      esac ;;
    setting)
      claude_setting_ok "$n" || die "$n is not a setting fleet compares"
      claude_settings_edit --arg n "$n" --argjson v "$v" "$CLAUDE_SETTING_PATH as \$p | setpath(\$p; \$v)"
      echo "set $n" ;;
    perm)
      lr=$(claude_perm_split "$n") || exit 1
      claude_settings_edit --arg l "${lr%%	*}" --arg r "${lr#*	}" \
        '.permissions[$l] = ((.permissions[$l] // []) | if any(.[]; . == $r) then . else . + [$r] end)'
      echo "added $n" ;;
  esac
}

claude_unset_local() {   # <kind> <name>: remove the item from this Mac
  local k="$1" n="$2" lr f
  case "$k" in
    marketplace)
      if jq -e --arg n "$n" '(.enabledPlugins // {}) | any(to_entries[]; .value == true and (.key | endswith("@" + $n)))' \
           "$(claude_src "$HOME/.claude/settings.json")" >/dev/null 2>&1; then
        die "plugins from $n are enabled on $FLEET_SELF; remove them first"
      fi
      claude_run "claude plugin marketplace remove $n" claude plugin marketplace remove "$n"
      echo "removed marketplace $n" ;;
    plugin)
      claude_run "claude plugin uninstall $n" claude plugin uninstall "$n" --scope user
      echo "removed plugin $n" ;;
    mcp)
      claude_run "claude mcp remove $n" claude mcp remove -s user "$n"
      echo "removed MCP server $n" ;;
    setting)
      claude_setting_ok "$n" || die "$n is not a setting fleet compares"
      claude_settings_edit --arg n "$n" "$CLAUDE_SETTING_PATH as \$p | delpaths([\$p])"
      echo "removed $n" ;;
    perm)
      lr=$(claude_perm_split "$n") || exit 1
      claude_settings_edit --arg l "${lr%%	*}" --arg r "${lr#*	}" \
        'if .permissions[$l] then .permissions[$l] |= map(select(. != $r)) else . end'
      echo "removed $n" ;;
    file)
      claude_valid_file "$n" || die "files are CLAUDE.md or scripts/<name>"
      f="$HOME/.claude/$n"
      [ -e "$f" ] || { echo "no ~/.claude/$n"; return 0; }
      [ -e "$f.fleet-backup" ] || cp -p "$f" "$f.fleet-backup"
      rm -f "$f"
      echo "removed ~/.claude/$n" ;;
  esac
}
```

Note: `"${lr%%	*}"` and `"${lr#*	}"` contain a literal TAB character between `%%`/`#*` and `*`/`}`. Type a real tab there, not spaces.

Replace `cmd_claude` with:

```bash
cmd_claude() {
  case "${1:-}" in
    --local) claude_snapshot_local; return 0 ;;
    get|set|unset)
      [ "${2:-}" = --local ] && [ -n "${4:-}" ] || die "usage: fleet claude $1 --local <kind> <name>"
      claude_valid_kind "$3" || die "unknown kind '$3' (kinds: $CLAUDE_KINDS)"
      "claude_$1_local" "$3" "$4" "${5:-}"; return ;;
  esac
  claude_matrix_cmd "$@"
}
```

- [ ] **Step 5: Run the tests and check they pass**

Run: `test/run.sh 2>&1 | tail -5` and `shellcheck fleet`
Expected: `0 failed`; shellcheck clean.

- [ ] **Step 6: Commit**

```bash
git add fleet test/run.sh test/shims/claude
git commit -m "claude get|set|unset --local: apply one Claude setup item on this Mac"
```

---

### Task 4: `fleet claude copy` and `fleet claude rm`

**Files:**
- Modify: `fleet` (claude section, `usage`)
- Modify: `test/run.sh` (claude setup section)

**Interfaces:**
- Consumes: `claude_host`, `claude_valid_kind` (Tasks 1 and 2); `get|set|unset --local` (Task 3); `run_on`, `shq`, `ok`, `fail`, `DOCTOR_RC` (existing).
- Produces:
  - `claude_copy <kind> <name> --from <host> --to <host…>|all`: returns 1 if any target failed
  - `claude_rm [-y] <kind> <name> <host…>|all`

- [ ] **Step 1: Write the failing tests**

Append to the claude setup section:

```bash
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
```

- [ ] **Step 2: Run the tests and check they fail**

Run: `test/run.sh 2>&1 | tail -30`
Expected: the new assertions FAIL (`copy`/`rm` treated as host names: "unknown host").

- [ ] **Step 3: Implement**

Add to the claude section, after `claude_unset_local`:

```bash
# claude_copy <kind> <name> --from <host> --to <host...>|all: read the item's
# full value on --from and make each target equal to it, one after another.
# The value travels on stdin (never on an ssh command line) and is kept only
# in a temp dir for the length of the copy. A plugin's marketplace goes first.
claude_copy() {
  local usage="usage: fleet claude copy <kind> <name> --from <host> --to <host...>|all"
  local k="${1:-}" n="${2:-}" from="" to="" h tmp exec="" mkt=""
  [ $# -ge 2 ] || die "$usage"
  shift 2
  claude_valid_kind "$k" || die "unknown kind '$k' (kinds: $CLAUDE_KINDS)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) [ $# -ge 2 ] || die "$usage"; from=$(claude_host "$2") || exit 1; shift 2 ;;
      --to) shift; while [ $# -gt 0 ] && [ "$1" != --from ]; do to="$to $1"; shift; done ;;
      *) die "$usage" ;;
    esac
  done
  [ -n "$from" ] && [ -n "$to" ] || die "$usage"
  if [ "$to" = " all" ]; then
    to=""; for h in $FLEET_HOSTS; do [ "$h" = "$from" ] || to="$to $h"; done
  else
    local t="$to"; to=""
    for h in $t; do h=$(claude_host "$h") || exit 1; [ "$h" = "$from" ] || to="$to $h"; done
  fi
  [ -n "$to" ] || die "nothing to copy to: every target is $from"
  tmp=$(mktemp -d)
  trap 'rm -rf "${tmp:-}"' RETURN
  run_on "$from" "fleet claude get --local $(shq "$k") $(shq "$n")" > "$tmp/value" 2>/dev/null || die "no $k '$n' on $from"
  if [ "$k" = file ] && run_on "$from" "fleet claude --local" | jq -e --arg n "$n" 'any(.items[]; .kind == "file" and .name == $n and .exec)' >/dev/null; then
    exec="--exec"
  fi
  if [ "$k" = plugin ]; then
    mkt="${n##*@}"
    run_on "$from" "fleet claude get --local marketplace $(shq "$mkt")" > "$tmp/mkt" 2>/dev/null \
      || die "$n's marketplace $mkt is not known on $from"
  fi
  for h in $to; do
    if [ -n "$mkt" ] && ! run_on "$h" "fleet claude set --local marketplace $(shq "$mkt")" < "$tmp/mkt" > "$tmp/out" 2>&1; then
      fail "$k $n -> $h: $(tail -1 "$tmp/out" | sed 's/^fleet: //')"; continue
    fi
    if run_on "$h" "fleet claude set --local $(shq "$k") $(shq "$n") $exec" < "$tmp/value" > "$tmp/out" 2>&1; then
      ok "$k $n -> $h"
      sed "s/^/        $DIM/; s/\$/$RESET/" "$tmp/out"
    else
      fail "$k $n -> $h: $(tail -1 "$tmp/out" | sed 's/^fleet: //')"
    fi
  done
  return "$DOCTOR_RC"
}

claude_rm() {   # [-y] <kind> <name> <host...>|all
  local usage="usage: fleet claude rm [-y] <kind> <name> <host...>|all"
  local yes=0 k n h hosts="" a tmp
  if [ "${1:-}" = -y ] || [ "${1:-}" = --yes ]; then yes=1; shift; fi
  [ $# -ge 3 ] || die "$usage"
  k="$1" n="$2"; shift 2
  claude_valid_kind "$k" || die "unknown kind '$k' (kinds: $CLAUDE_KINDS)"
  for a in "$@"; do
    if [ "$a" = all ]; then hosts=" $FLEET_HOSTS"; break; fi
    h=$(claude_host "$a") || exit 1; hosts="$hosts $h"
  done
  if [ "$yes" != 1 ]; then
    [ -t 0 ] || die "refusing to remove $k $n without -y"
    printf 'remove %s %s on%s? [y/N] ' "$k" "$n" "$hosts"
    read -r a </dev/tty
    case "$a" in y|Y) ;; *) die "left as is" ;; esac
  fi
  tmp=$(mktemp)
  trap 'rm -f "${tmp:-}"' RETURN
  for h in $hosts; do
    if run_on "$h" "fleet claude unset --local $(shq "$k") $(shq "$n")" > "$tmp" 2>&1 </dev/null; then ok "removed $k $n on $h"
    else fail "$k $n on $h: $(tail -1 "$tmp" | sed 's/^fleet: //')"; fi
  done
  return "$DOCTOR_RC"
}
```

In `cmd_claude`, add two entries before `esac`:

```bash
    copy) shift; claude_copy "$@"; return ;;
    rm)   shift; claude_rm "$@"; return ;;
```

In `usage`, after the `fleet claude [--json]…` lines, add:

```
  fleet claude copy <kind> <name> --from <host> --to <host...>|all
  fleet claude rm [-y] <kind> <name> <host...>|all
                                  make one item (kinds: marketplace plugin mcp setting perm file)
                                  the same as another Mac's, or remove it; `this` = this Mac
```

- [ ] **Step 4: Run the tests and check they pass**

Run: `test/run.sh 2>&1 | tail -5` and `shellcheck fleet`
Expected: `0 failed`; shellcheck clean. If `sed` with `$DIM` in the replacement trips on an escape byte, print the lines with `while IFS= read -r l; do printf '        %s%s%s\n' "$DIM" "$l" "$RESET"; done < "$tmp/out"` instead.

- [ ] **Step 5: Commit**

```bash
git add fleet test/run.sh
git commit -m "fleet claude copy|rm: reconcile one Claude setup item across Macs"
```

---

### Task 5: Doctor line and documentation

**Files:**
- Modify: `fleet` (`cmd_doctor`, claude section)
- Modify: `test/run.sh`
- Modify: `CLAUDE.md`, `README.md`, `SECURITY.md`

**Interfaces:**
- Consumes: `gather_into … claude_fetch`, `claude_matrix` (Task 2); `ok` (existing).
- Produces: `claude_doctor_line`.

- [ ] **Step 1: Write the failing test**

Append to the claude setup section (the rows copied in Task 4 still leave `CLAUDE.md` differing):

```bash
O=$(renv FLEET_HOSTS="laptop studio" -- doctor 2>&1)
assert_contains "doctor across Macs says the Claude setups differ" "$O" "claude setup differs on"
assert_contains "  ...pointing at fleet claude --diff" "$O" "(fleet claude --diff)"
assert_lacks "doctor <host> does not"                   "$(renv FLEET_HOSTS="laptop studio" -- doctor studio 2>&1)" "claude setup"
```

- [ ] **Step 2: Run the test and check it fails**

Run: `test/run.sh 2>&1 | tail -10`
Expected: the first two new assertions FAIL.

- [ ] **Step 3: Implement**

Add to the claude section:

```bash
# For `fleet doctor` across every host: one line, informational (a Mac may
# differ on purpose), never FAIL.
claude_doctor_line() {
  local tmp n
  tmp=$(mktemp -d)
  trap 'rm -rf "${tmp:-}"' RETURN
  gather_into "$tmp" "" claude_fetch
  n=$(claude_matrix "$tmp" | jq '[.items[] | select(.differs)] | length')
  if [ "$n" -eq 0 ]; then ok "claude setup is the same on every Mac that answered"
  else printf '%s  · claude setup differs on %s item(s) (fleet claude --diff)%s\n' "$DIM" "$n" "$RESET"; fi
}
```

In `cmd_doctor`, change the start and the end of the loop so the line runs only when no hosts were named and there is more than one host:

```bash
cmd_doctor() {
  local h every=0
  if [ "${1:-}" = "--local" ]; then doctor_local; exit "$DOCTOR_RC"; fi
  [ $# -gt 0 ] || every=1
  # shellcheck disable=SC2086  # FLEET_HOSTS is a space-separated list
  [ $# -gt 0 ] || set -- $FLEET_HOSTS
  [ $# -gt 0 ] || set -- "$FLEET_SELF"   # no hosts yet: check this machine, which reports that
  for h in "$@"; do
    if [ "$h" = "$FLEET_SELF" ]; then doctor_local; else doctor_remote "$h"; fi
    echo
  done
  if [ "$every" = 1 ] && [ $# -gt 1 ]; then
    printf '%sacross hosts%s\n' "$BOLD" "$RESET"; claude_doctor_line; echo
  fi
  exit "$DOCTOR_RC"
}
```

- [ ] **Step 4: Run the tests and check they pass**

Run: `test/run.sh 2>&1 | tail -5` and `shellcheck fleet`
Expected: `0 failed`; shellcheck clean.

- [ ] **Step 5: Update the docs**

`CLAUDE.md`:
- Under "Decisions already made", decision 6: add a sentence at the end: "`fleet claude copy` is not an exception: it is a per-item push over ssh that the owner starts, like `hosts push`, and nothing syncs by itself."
- In the "Commands:" list line, add `claude` after `models`.
- After the `models […]` paragraph, add:

```markdown
  `claude [--json] [--diff] [host...]` = how the Claude Code setup differs
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
  `claude rm [-y]` runs `claude unset --local`. Fan-out doctor adds one
  informational "claude setup differs" line.
```

`README.md`: add a section after "## Claude Code hooks and status line":

```markdown
## Keeping Claude setups aligned

Each Mac collects its own plugins, MCP servers, settings and permission
rules. `fleet claude` shows them side by side (`--diff` for just the
differences), and you fix one row at a time:

    fleet claude --diff
    fleet claude copy plugin superpowers@claude-plugins-official --from this --to all
    fleet claude copy mcp xcode --from mini --to this
    fleet claude copy perm "allow:Bash(git log:*)" --from this --to studio
    fleet claude rm plugin swift-lsp@claude-plugins-official laptop

Nothing changes unless you run `copy` or `rm`. An http MCP server that signs
in with OAuth has to be authenticated once on the new Mac (`/mcp`).
```

`SECURITY.md`: in "## What fleet does", add a bullet:

```markdown
- `fleet claude` compares Claude Code setups across your Macs. MCP server
  entries and the `env` setting can hold tokens, so a Mac reports them only as
  a sha256 digest, and neither the table nor `--json` prints them.
  `fleet claude copy` moves the real value from one of your Macs to another
  over the same ssh fleet already uses, on stdin, only when you ask, and keeps
  it only in a temp directory while it runs. Plugin installs go through
  `claude plugin install` without `-y`: a plugin whose marketplace wants to run
  a command is refused and left for you to install by hand.
```

Render README/CLAUDE.md is not needed; just run `test/run.sh` once more.

- [ ] **Step 6: Commit**

```bash
git add fleet test/run.sh CLAUDE.md README.md SECURITY.md
git commit -m "doctor: say when Claude setups differ; document fleet claude"
```

- [ ] **Step 7: Try it on the real fleet (read-only)**

Run: `./fleet claude --diff` from the checkout.
Expected: a table with one column per reachable Mac and the plugin/MCP/setting differences seen during design; unreachable Macs listed under "not answering". Do not run `copy`/`rm` against real machines without the owner.
