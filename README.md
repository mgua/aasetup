# aasetup — Linux application/dev account setup for TomWare

Provision Linux accounts (user + sudo + SSH key + git config + Neovim/tmux/vim)
on **Debian or Ubuntu**, one at a time or in batch from a JSON roster.

Two halves, two privilege levels:

* **`aasetup*.sh`** - run by **root**, *creates* accounts.
* **`mysetup`** - run by the **account itself**, *configures* its own
  environment from a menu, and needs no root except through `sudo` for
  package installs.

## Files

| File | What it is |
|---|---|
| `aasetup.sh` | provision **one** account (run as root) |
| `aasetup_all.sh` | provision **many** accounts from a JSON roster (run as root) |
| `template-users.json` | example roster — **copy to `users.json`** and edit |
| `users.json` | your real roster — **gitignored** (keep real names/emails/keys out of git) |
| `aasetup_recording.sh` | session recording for one account: asciinema + atuin, locked offline (run as root) |
| `mysetup` | self-service environment setup, run by the **non-root** account (Python 3, no deps) |
| `mysetup-etc/` | everything `mysetup` knows about your site: templates, package lists, history |
| `mysetup-etc.local/` | your real site config - **gitignored**; `mysetup` prefers it over `mysetup-etc/` |

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

## Self-service setup (`mysetup`)

Where `aasetup.sh` is the admin creating an account, `mysetup` is the **user
configuring their own**. Run it as yourself - it refuses to run as root:

```bash
./mysetup                       # interactive menu (what it is for)
./mysetup --list                # every task + whether it is already done
./mysetup --do gitconfig,vim    # just these
./mysetup --all --dry-run       # show every change a full run would make
./mysetup --all --yes           # unattended, accepting every default
```

Plain Python 3 standard library: **no venv, no pip, nothing to install.**
Everything is idempotent - a second run reports `current` and rewrites nothing.

### Tasks

| Task | Does |
|---|---|
| `sudoers` | renders `/etc/sudoers.d/<user>`, validates it with `visudo -cf`, and prints the `install` command for an admin (offers to run it if you already have sudo) |
| `tools` | installs the system packages via `sudo apt-get`/`dnf`, plus the global npm packages |
| `gitconfig` | `~/.gitconfig` with your git identity |
| `editor` | group: Neovim config repo + `~/.vimrc` + `~/.tmux.conf` + TPM and its plugins |
| `sshkey` | generates this account's git-identity keypair and prints the public key |
| `sshconfig` | `~/.ssh/config` for the site's hosts |
| `authkeys` | prompts you to paste login public keys into `~/.ssh/authorized_keys` |
| `history` | preloads `~/.bash_history` (and atuin) with the house commands, so CTRL-r knows them on day one |

`nvim`, `vim`, `tmux`, `tpm` and `knownhosts` are hidden sub-tasks: not in the
menu, but still runnable with `--do`.

Every task carries a `description` in `mysetup.conf`, shown when you select it,
so "Proceed?" is never a blind question. Steps that shell out - the package
install above all - print the **exact command** and then ask:

```
[ INFO] 18 of 20 package(s) already installed (apt)
[ INFO] missing: npm bat

      This will run:
        sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
        sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y npm
        sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y bat

Install 2 package(s) with sudo, one at a time? [Y/n]
```

Answer `n` and nothing is installed. Add a `description` to your own tasks the
same way - it is config, not code.

### One package per command, on purpose

`tools` installs **one package per `apt-get` call**, never a batch. A batch
returns a single exit code for the whole set, so one package with no install
candidate takes the other nineteen down with it and the log does not say which
one was at fault. Per-package, the failure names itself, the rest still get
installed, and the run ends with a verdict you can act on:

```
[FAIL] npm failed to install - continuing with the rest
[  OK ] installed bat
[ WARN] 1 of 2 package(s) failed: npm

==> Summary
  partial  tools          partial: installed 1/2, failed: npm
```

`partial` is its own outcome - not the green `ok` that would hide the failure,
not a hard `failed` that would abandon the packages that installed fine. The
same applies to the global npm packages. A failing `apt-get update` warns and
carries on, since a stale index should not block packages already fetchable.

### Everything user-specific lives in `mysetup-etc/`

The script carries no names, addresses, repo URLs or package names - point it at
a different `mysetup-etc/` and it provisions a different site. `--etc DIR` or
`MYSETUP_ETC` override the search, which is
`mysetup-etc.local/` → `mysetup-etc/` → `~/.config/mysetup/etc` → `/etc/mysetup`.

```
mysetup-etc/
  mysetup.conf         [vars] site values, [ask] questions, [task:*] the menu
  conf.d/*.conf        drop-in overrides, read after mysetup.conf
  packages.list        system packages ('7zip|p7zip-full' = first one that exists)
  npm-global.list      global npm packages
  files/               sudoers.tmpl gitconfig.tmpl ssh_config.tmpl vimrc tmux.conf
  ssh/known_hosts      host keys to pre-seed (fill in from a machine you trust)
  history/*.txt        command history, loaded in filename order
```

`*.tmpl` files are rendered; anything else is installed verbatim. Placeholders:
`{{USER}} {{HOME}} {{HOSTNAME}} {{FQDN}} {{GECOS}} {{DATE}} …`, everything in
`[vars]`, and `{{A|B|literal}}` for "first one that is not empty".

### Answers

Values that cannot be known in advance are declared in `[ask]` and asked once:

```ini
[ask]
git_name  = Git author name    | {{GECOS|USER}}
git_email = Git e-mail address | {{USER}}@{{DOMAIN}}
```

They are cached in `~/.config/mysetup/answers.conf`; `--reset-answers` forgets
them and `--set KEY=VALUE` overrides one for a single run.

### Two safety rules worth knowing

* `--yes` means *accept the defaults*, **not** *approve everything*. Prompts
  that default to no - writing into `/etc/sudoers.d`, replacing an existing SSH
  key - stay deliberate and interactive.
* Anything an admin or your password manager needs (the sudoers snippet, a
  generated key passphrase) is written to `~/.config/mysetup/out/`, mode 0600,
  and listed at the end of the run. **Delete those files once used.**

Files are never overwritten blind: a differing original is copied to
`<name>.bak.<timestamp>` first.

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
