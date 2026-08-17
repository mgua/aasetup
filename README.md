# aasetup — Linux application/dev account setup for TomWare

Provision Linux accounts (user + sudo + SSH key + git config + Neovim/tmux/vim)
on **Debian or Ubuntu**, one at a time or in batch from a JSON roster.

## Files

| File | What it is |
|---|---|
| `aasetup.sh` | provision **one** account (run as root) |
| `aasetup_all.sh` | provision **many** accounts from a JSON roster (run as root) |
| `template-users.json` | example roster — **copy to `users.json`** and edit |
| `users.json` | your real roster — **gitignored** (keep real names/emails/keys out of git) |
| `aasetup_recording.sh` | session recording for one account: asciinema + atuin, locked offline (run as root) |

## Requirements

Run as **root** on Debian ≥12 or Ubuntu ≥24.04. The batch runner needs `jq`,
which it **auto-installs** if missing (apt-get/dnf/yum) — no manual step.
`aasetup.sh` installs the rest (git, python, node, ripgrep, fzf, tmux, Neovim,
trzsz, …) on its first run.

## Quick start

```bash
# one user
sudo bash aasetup.sh -u alice -e alice@example.com -n "Alice Example"

# batch: create your roster from the template, then run it
cp template-users.json users.json     # edit users.json with your real users
sudo bash aasetup_all.sh               # all enabled users
sudo bash aasetup_all.sh alice appsvc  # only these
bash aasetup_all.sh -h                 # all options
```

`aasetup.sh` flags: `-u USER -U UID -G GID -e EMAIL -n NAME -f` (force-overwrite key)
`-h`. Phases toggle via env, e.g. `DO_PACKAGES=0`, `DO_NVIM=0`, `DO_TMUX=0`,
`DO_PASSWORD=0`, `PASSWORD_FORCE_CHANGE=0`, `PROMPT_AUTHKEY=1`.

## Roster fields (`users.json`)

| Field | Maps to | Notes |
|---|---|---|
| `user` | `-u` | account name |
| `uid`, `gid` | `-U` / `-G` | numeric ids (unique) |
| `gecos` | `USER_GECOS` | full name / description |
| `git_name` | `-n` | git author name |
| `git_email` | `-e` | git email + SSH key comment |
| `sudo_nopasswd` | `DO_SUDO_NOPASSWD` | `true` = passwordless sudo |
| `public_key` | `SSH_AUTHORIZED_KEY` | login key for `~/.ssh/authorized_keys`; `""` to skip |
| `enabled` | — | `false` skips the user entirely (default `true`) |
| `on_exists` | — | existing account: `"skip"` (leave alone) or `"setup"` (env only) |

`TEMPLATE*` entries are ignored — copy or delete them.

## What each user gets

- A new account (uid/gid) with passwordless sudo (if `sudo_nopasswd`).
- A random **10-digit password**, force-changed at first login, exported to
  `/root/account-exports/<user>/PASSWORD.txt`. (`DO_PASSWORD=0` = key-only;
  `PASSWORD_FORCE_CHANGE=0` = set it but don't force a change.)
- A generated **git-identity SSH keypair**; its passphrase + the public key to add
  to the git server go to `/root/account-exports/<user>/CREDENTIALS.txt`.
- Optionally a **login** public key in `~/.ssh/authorized_keys` (from `public_key`,
  or prompted with `-p`).
- `~/.gitconfig`, `~/.vimrc`, `~/.tmux.conf` (+ TPM), and the Neovim config.

Existing accounts are **skipped** by default; system packages install only once
(first user). Hand each user their files from `/root/account-exports/<user>/`,
then delete them.

## Session recording (`aasetup_recording.sh`)

Records maintenance work so it can be audited and learned from
(designed in synthian-gate thread 49). Run **after** the account exists:

```bash
sudo bash aasetup_recording.sh -u claude -t   # agent account: with tmux pane logs
sudo bash aasetup_recording.sh -u alice       # human: synrec + atuin only
```

What it sets up:

- **asciinema** — replayable per-task recordings, started with
  `synrec <recipe-slug>`. The file name carries datetime + machine +
  operator + recipe; one line per recording goes to `~/recordings/INDEX.psv`.
- **atuin** — structured LOCAL shell history (host, cwd, exit code, duration
  per command). No account, no sync, update checks off, secrets filter on,
  standard bash keys kept. (Skipped automatically where the distro has no
  atuin package: Debian <13, Ubuntu <25.10.)
- **AppArmor lockdown** — both tools are denied ALL network at the kernel,
  so shell history and recordings cannot leave the machine even through a
  config mistake or a compromised tool. The shell *inside* an asciinema
  recording stays a normal shell (ssh to targets works).
- **tmux pane logging** (`-t`, agent accounts only) — every pane of every
  tmux session is appended to `~/recordings/tmux/`, one file per pane per day.
- A **self-check** at the end verifies: profiles enforced, no atuin
  account/session exists, no atuin-server running.

House rules: recordings never leave the machine; never `atuin login` or
`atuin register`; never `asciinema upload` (blocked anyway); a recording that
caught a secret gets deleted and the deletion is mentioned in the thread.
