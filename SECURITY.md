# Security model

fleet runs commands on every Mac in your hosts file over ssh, and
`fleet install` / `fleet update` replace fleet's own code from a git remote.
Both are the point of the tool, and both are worth understanding before you
add a machine. This file says what talks to what, what a compromise of each
piece buys an attacker, what fleet does about it, and what only you can do.

## What talks to what

- **Your machine → the agents.** The Mac you sit at (the "control" machine)
  runs `ssh -o BatchMode=yes <host>` for every other host in
  `~/.config/fleet/hosts`: `fleet status --json` and `fleet hosts
  --info-local` when you run `ls` or the app polls; `fleet projects --local`,
  `fleet new --local`, `fleet kill --local`, `fleet doctor --local` and
  `fleet install --local` when you ask for them; a plain `cat >` to write the
  hosts file (and `allowed_signers`, below) there; and an interactive
  `ssh -t <host>` for `fleet attach` and `fleet shell`. Nothing else.
- **Agents never ssh anywhere.** A machine that only runs agents needs no
  ssh keys to the other Macs and no entry in their `authorized_keys`. Only
  control machines need to reach the agents. Keep it that way: an agent
  machine holding keys to your laptop is the fastest way to lose the laptop.
- **Every machine → GitHub.** `install` and `update` clone or fetch this repo,
  with the machine's own `gh` credentials when gh is installed, else plain
  git over https. Agents push their project branches with the gh credentials.
  fleet itself never pushes anything.
- **Nothing runs on a timer.** There is no daemon and no auto-update. Every
  deploy is you typing `fleet install <host>` or `fleet update`. Claude Code
  hooks run `~/bin/fleet hook <state>` on each event, and its status line
  runs `~/bin/fleet statusline` after each reply; both are whatever code is
  already on that machine, print nothing back to Claude, and never fetch.
- **What the hooks keep.** The state file for a session holds, besides the
  state, the last prompt you typed, the agent's last reply and what it is
  asking for, clipped to a few hundred characters, plus the model, context
  use and your account's usage percentages from the status line. They live
  in `~/.local/state/fleet` on the machine that runs the agent, travel to
  the control machine inside `fleet status --json` over ssh, and are shown
  by `fleet ls` and the app. They are only ever passed through `jq`; nothing
  in them reaches a shell.
- **The Mac app** is a wrapper: every button runs `fleet` on the control machine,
  which does the above.
- **The iPhone app is a control machine.** It holds an Ed25519 key, made on
  the phone and kept in its Keychain, that `fleet keys add` puts into
  `~/.ssh/authorized_keys` on every Mac. Over Tailscale it runs the same
  per-host commands (`status --json`, `hosts --info-local`, `projects
  --json`, `new --local`, `kill --local`) directly on each Mac; the Macs
  still need no keys to each other. Each Mac's ssh host key is pinned on the
  first connection and required afterwards.
- **`fleet keys`** is the only thing that writes `authorized_keys`. It
  accepts exactly one OpenSSH public key line (type, base64, optional
  comment; nothing else can reach the file), appends it with the file kept
  mode 600, and removes by comment.

## What a compromise buys

1. **Push access to this repo.** Whoever can move `main` (a stolen GitHub
   session, a merged pull request you did not read) gets code execution on
   every Mac the next time it runs `fleet update`, and, through the hooks,
   on every Claude prompt after that. This is the single biggest risk, and
   the reason for signed updates below.
2. **An agent machine.** It runs Claude Code with `--permission-mode auto`,
   so anything the agent can be talked into, a prompt injection in a repo it
   reads can do too. It holds a `gh` token and whatever ssh keys you gave it.
   If that token can push to *this* repo, item 1 follows. Treat agent
   machines as disposable: no personal data, a token that only reaches the
   project repos, and no keys to other Macs.
3. **The control machine.** Its ssh keys are effectively root on every agent.
   That is true of any ssh setup and fleet does not change it; it does mean
   FileVault and a locked screen on the laptop matter more than usual. The
   phone is one too: a lost phone is a lost key until you run `fleet keys rm
   fleet-<its name>` from any Mac, which revokes it everywhere. Its key never
   leaves the Secure Enclave-backed Keychain and the app has no export.
4. **A hostile answer from a host.** `fleet ls` parses each host's JSON with
   jq and then uses fields from it (paths, branch and session names) in local
   `git`, `tmux`, `ssh` and editor commands when you press Open, the terminal
   button or Shell. Hosts are your own machines and are trusted; fleet drops
   anything that is not a JSON array and quotes what it forwards, but it does
   not defend against a machine that is already yours and already
   compromised.

## What fleet does

- **Signed updates (opt in).** If `~/.config/fleet/allowed_signers` exists,
  `fleet update` refuses any tip commit that is not ssh-signed by a key in
  it, and says so. The file is in git's `allowed_signers` format and is pushed
  to every host along with the hosts file, so you write it once on the control
  machine. `fleet doctor` reports whether checking is on. Setup:

  ```bash
  # on the machine you commit from
  git config --global gpg.format ssh
  git config --global user.signingkey ~/.ssh/id_ed25519.pub
  git config --global commit.gpgsign true
  # the trust root; principal must be the committer email on your commits
  printf '%s %s\n' "$(git config user.email)" "$(cat ~/.ssh/id_ed25519.pub)" \
    > ~/.config/fleet/allowed_signers
  fleet hosts push          # or: fleet install <host>
  ```

  Only the tip is verified, which with fast-forward-only updates is enough:
  an unsigned commit on top fails, and a signed commit cannot be placed on top
  of one you did not sign without you signing it. Merge on your machine
  rather than with GitHub's merge button: GitHub signs web merges with its own
  GPG key, which this check does not know.
- **Updates are loud and fast-forward only.** `fleet update` fetches, prints
  the commits that are about to land, and only fast-forwards. A rewritten
  history or a dirty checkout stops it with a message rather than a reset.
- **Host names are validated.** A host is letters, digits, `.`, `_`, `-`;
  `fleet hosts add` refuses anything else and the loader skips it, so a
  hosts file cannot smuggle ssh options or shell text into `ssh "$host"`.
- **ssh never prompts and never hangs.** `BatchMode=yes`, a connect timeout,
  and a watchdog around every remote status. A host that does not answer
  contributes nothing.
- **No login shells remotely.** Remote commands carry their own PATH
  (`FLEET_PATH`), so what runs there does not depend on that machine's rc
  files.
- **Only your sessions.** Registered sessions are the only ones fleet
  attaches to, opens or ends; `--all` is explicit, and `fleet kill` asks
  first unless told `-y` (the app asks in a dialog instead).
- **Editors run with your checkout, not its contents.** `FLEET_OPEN` names a
  command or app from your own config; it is given the directory. Nothing
  from the repository being opened decides what runs.

## What only you can do

- **Tailscale ACLs.** Allow ssh (port 22) only from your control machines to
  the agents, not between agents and not from agents back. If you use Tailscale
  SSH, its check mode re-authenticates before a session.
- **gh tokens on agents.** Sign in with a fine-grained token scoped to the
  project repos, with no access to this repo. `gh auth login --insecure-storage`
  (needed for gh to work over ssh) stores the token in plain text in
  `~/.config/gh/hosts.yml`: FileVault on, and that file mode 600.
- **Branch protection here.** Require signed commits, forbid force pushes,
  and read every pull request as if it were a script you are about to run on
  every Mac you own, because it is.
- **Claude Code itself.** `--permission-mode auto` and `--remote-control` are
  fleet's defaults (`FLEET_CLAUDE_ARGS`). Remote Control makes the session
  reachable from claude.ai on your account; protect that account accordingly,
  or remove the flag for machines that do not need it.
- **Freeze a machine** by checking out a tag in its fleet checkout instead of
  `main`. `fleet update` fast-forwards only the branch that is checked out, so
  a detached checkout stays where it is until you move it.

## Reporting

This is a personal tool, published in case it is useful. Open a GitHub issue
for anything you find; there is no embargo process.
