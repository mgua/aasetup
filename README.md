# aasetup — assisted Linux application/dev account setup

This script prepare a linux system (Debian or Ubuntu) executing a set of configurations
that are functional for TomWare company use. Do not assume the settings are ok for you.

This script is experimental.

## prerequirements

```
apt update
apt install curl git
```

script download (execute from root):

```
cd
git clone https://github.com/mgua/aasetup.git
cd aasetup
#bash ./aasetup.sh
```


Provision Linux accounts (user + sudo + SSH key + git config + Neovim/tmux/vim)
on **Debian or Ubuntu**, one at a time or in batch from a JSON roster.

Two halves, two privilege levels:

* **`aasetup*.sh`** - run by **root**, *creates* accounts.
* **`mysetup`** - run by the **account itself**, *configures* its own
  environment from a menu, and needs no root except through `sudo` for
  package installs.

**New here?** [`GUIDE.md`](GUIDE.md) explains the three tools, how they fit
together, and the Windows-side integration (fonts, clipboard, editors, file
transfer). This README is the reference.

## Files

| File | What it is |
|---|---|
| `GUIDE.md` | how aasetup, mysetup and psprofile fit together, incl. the Windows side |
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
./mysetup                       # interactive menu, looping until you quit
./mysetup --list                # every task + whether it is already done
./mysetup --do gitconfig,vim    # just these
./mysetup --all --dry-run       # show every change a full run would make
./mysetup --all --yes           # unattended, accepting every default
```

Plain Python 3 standard library: **no venv, no pip, nothing to install.**
Everything is idempotent - a second run reports `current` and rewrites nothing.

The menu **loops**: setting an account up takes several passes, so after each
one you land back on the list with the statuses recomputed - the task you just
ran now reads `done`. Enter returns to the menu, `q` leaves, and on the way out
you get a per-session tally. `--do` and `--all` run once and exit, unchanged.

### Tasks

| Task | Does |
|---|---|
| `sudoers` | renders `/etc/sudoers.d/<user>`, validates it with `visudo -cf`, and prints the `install` command for an admin (offers to run it if you already have sudo) |
| `tools` | installs the system packages via `sudo apt-get`/`dnf`, plus the global npm packages |
| `filetransfer` | trzsz and/or lrzsz, so files can move over the ssh session itself |
| `gitconfig` | `~/.gitconfig` with your git identity |
| `nvim` | clones the house Neovim config and bootstraps its plugins (network) |
| `vim` | minimal `~/.vimrc` - no plugins, no plugin manager, no network |
| `tmux` | `~/.tmux.conf` plus the plugin manager and its plugins (network) |
| `sshkey` | create, upload (trz/rz) or paste this account's keypair; fixes perms, authorises the public half |
| `sshconfig` | `~/.ssh/config` for the site's hosts |
| `authkeys` | prompts you to paste login public keys into `~/.ssh/authorized_keys` |
| `history` | preloads `~/.bash_history` (and atuin) with the house commands, so CTRL-r knows them on day one |
| `shell` | `~/.psprofile.sh` (the Linux side of [psprofile](https://github.com/mgua/psprofile)) + Oh My Posh with the `slimfat2` theme |
| `fonts` | Hack Nerd Font for a *local* graphical terminal (system-wide with sudo, else per-user) |
| `theme` | one Catppuccin flavour across vim, tmux, bat and fzf (`theme-clear` reverts) |
| `chezmoi` | installs chezmoi for keeping dotfiles in git; does **not** init a repo |

Neovim, vim and tmux are **three independent entries**, because they are three
independent tools: take any one, any two, or none. Plain `vim` needs no network
and installs no plugins, so a minimal account can skip the Neovim clone
entirely. The `tmux` entry covers its own customisation - config plus plugins.

`tmuxconf`, `tpm` and `knownhosts` are hidden sub-tasks: not in the menu, but
still runnable with `--do`. `--do tmuxconf` writes `~/.tmux.conf` and stops
there, for tmux without any plugins.

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

### Moving files over the ssh session (`filetransfer`)

`sshkey`'s upload option needs a transfer tool, and there is no single right
one - it depends on your terminal, not on this box:

* **trzsz** drives the transfer from the **client**, so it works with an
  ordinary terminal (Windows Terminal included). Install `trz`/`tsz` here, and
  on your side `winget install trzsz.tssh`, then connect with
  `tssh user@host` instead of `ssh`.
* **lrzsz** (`rz`/`sz`) speaks **ZMODEM** — and trzsz's client implements that
  too, so `tssh --zmodem host` makes the old `rz`/`sz` work in Windows Terminal
  as well (needs `trzsz.lrzsz` on the Windows side). Under *bare* `ssh` they
  only work in a terminal with its own ZMODEM, such as SecureCRT or ZOC.

Note that OSC-52 - which the shipped `.vimrc` and `.tmux.conf` use, and which
Windows Terminal does support - is a *clipboard* escape sequence. It is
unrelated to file transfer and neither tool depends on it.

The task picks the install route for the distro automatically, via each
sub-task's `when` condition: the **PPA on Ubuntu** (`ppa:trzsz/ppa`, apt-managed,
and it ships both `trzsz` and `tssh`), the **upstream .deb** on Debian-family
non-Ubuntu, and the **upstream .rpm** on Fedora/RHEL/Rocky/openSUSE. `lrzsz` is
offered everywhere alongside, since unlike trzsz it is packaged by every distro.
A task whose `when` fails reports `n/a` instead of failing.

When neither `trz` nor `rz` exists, `sshkey` greys its upload option out and
names the fix rather than offering something that cannot work:

```
    1) create a new keypair here with ssh-keygen
    2) upload an existing keypair - UNAVAILABLE: no trz or rz on this box (run
       'mysetup --do filetransfer', menu item 3)
    3) paste an existing keypair into vim
```

### The shell: psprofile and the slimfat2 prompt (`shell`)

`~/.psprofile.sh` is the Linux counterpart of `profile.ps1` in
[mgua/psprofile](https://github.com/mgua/psprofile) - same alias names, so the
same muscle memory works on both sides:

| | |
|---|---|
| `se` / `secd` / `lv` | pick and activate a `~/venv_<project>`; `secd` also cd's to `~/<project>`; `lv` lists venv sizes |
| `fzcd` / `fzl` / `fzv` | fzf: cd to a folder, print a file, view a file |
| `gst` `gd` `gl` `gp` | git status -sb, diff, log graph, pull --ff-only |
| `sid` | switch identity: `~/.gitconfig_<id>` + `~/.ssh/config_<id>` (+ `id_rsa_<id>`) |
| `oo` / `omp` | toggle Oh My Posh on and off |
| `cdh` `ll` `la` `lla` | home, ls variants |
| `wup` | update everything (the apt/dnf answer to `winget upgrade --all`) |
| `pspe` / `psmenu` | edit-and-reload the profile / list all of the above |

Windows-only aliases are listed at the top of the file with the reason they are
absent, so the difference between the two platforms is documented rather than
discovered.

Everything past the first ten lines is guarded on an interactive shell: a
profile that writes to stdout in a non-interactive one **corrupts scp and
rsync**, and that is a miserable fault to track down.

The prompt is your own `slimfat2.omp.json`, fetched from the psprofile repo
rather than copied into this one, so the two platforms cannot drift. It shows
folder, git state, python version and the active venv. Oh My Posh goes into
`~/.local/bin` (no root), and the download is checked against the release's
published `checksums.txt` - not piped from a URL into a root shell.

> **The prompt needs a Nerd Font in your terminal**, client-side, or the icons
> render as boxes. On Windows Terminal: `winget install DEVCOM.JetBrainsMonoNerdFont`
> (or any `*NerdFont*`), then set it as the profile font face.

### The SSH key: three ways in

Getting a key onto an account is three different jobs, so `sshkey` asks which -
but first it shows you everything that is already there, so declining is an
informed choice:

```
[ INFO] ~/.ssh (mode 0755) contains:
        0600  authorized_keys       3 key(s) allowed to log in here
        0644  id_rsa_claude         PRIVATE key  <- this account's configured key
        0644  id_rsa_claude.pub     public key
        0600  id_rsa_claude.txt     mysetup record of how the key was made
        0664  known_hosts           1 known host(s)
[ WARN] ~/.ssh is readable by others (mode 0755); 0700 is the norm
[ WARN] id_rsa_claude: readable by group/other - ssh will refuse it; chmod 600
[ INFO] ~/.ssh/authorized_keys authorises 3 key(s):
         1. ssh-ed25519   ...UUrNXdN1  alice@laptop
         2. ssh-ed25519   ...ktjCPBaj  sysec@tomware.it synthian operator
         3. ssh-ed25519   ...UUrNXdN1  (no comment)
[ WARN] authorized_keys line 3 is the same key as line 1 - a duplicate

      id_rsa_claude already exists. Answer q below to leave all of the above untouched.

  How should this account get its key?
    1) create a new keypair here with ssh-keygen
    2) upload an existing keypair from your machine (trz)
    3) paste an existing keypair into vim
    q) skip this task
```

**1 - create.** Shows the `ssh-keygen` command as you would type it, then runs
it and writes three files: `id_rsa_<user>` (0600), `.pub` (0644) and `.txt`
(0600) recording the command that made the key - type, size and comment, for
whoever inherits the account. The public half is offered for `authorized_keys`.

**2 - upload.** For a key that already exists on your machine. Runs `trz` (or
`rz`) in `~/.ssh` and normalises whatever arrives.

**3 - paste.** Same, without a transfer-capable terminal: opens your editor
twice, once per half. Instruction lines are marked and stripped, because a stray
comment is harmless in a `.pub` but corrupts a private key.

Whichever path ran, the files are then treated identically: **CRLF converted to
unix** (a Windows-pasted key fails with a message naming neither the file nor
the line endings), **0600 on the private half**, 0644 on the public one, and a
check that the two halves are actually the same key:

```
[ OK ] id_rsa_uploaded: converted CRLF line endings to unix
[ OK ] id_rsa_uploaded: private key, mode set to 0600
[WARN] id_rsa_x.pub does NOT match id_rsa_x - you have halves of two different keys
```

The `.txt` record does **not** contain the passphrase. It sits next to the
private key it would unlock, so recording it there would cancel the passphrase
out entirely; `record_passphrase = yes` in `mysetup-etc/` overrides that if you
really want it. Key type is site policy (`ssh_key_type` in `[vars]`, shipped as
`rsa`/4096 to match this site's `id_rsa_<user>` naming; `ed25519` is the better
choice for a new site and is a one-line change).

### An existing file is diffed before it is replaced

Any task that installs a dotfile - `gitconfig`, `vim`, `tmux`, `sshconfig` -
checks what is already there. If it differs, you get the unified diff in your
pager (`less -SRFX`: long lines chopped rather than wrapped, colours kept, no
paging for something that already fits, left on screen when you quit), and then
a prompt that **defaults to yes**:

```
[ INFO] ~/.gitconfig already exists and differs: +48 / -5 line(s)
      showing the diff in your pager - q to come back
      ... (diff) ...
Replace .gitconfig? (the current one is saved as .gitconfig.bak.<timestamp>) [Y/n]
```

Enter accepts. Answering `n` leaves the file alone and reports `skipped`, so you
can look at the diff, decline, and merge by hand instead. `$PAGER` is honoured;
`--no-pager` prints the diff inline. `--dry-run` shows the diff without asking,
and `--yes` replaces it after logging the `+N / -M` summary. An identical file is
recognised as such - no diff, no prompt, nothing rewritten.

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
