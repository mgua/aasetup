#!/usr/bin/env bash
# Explain how to get an ssh authentication agent running for THIS account, after
# reporting what is actually running now. Changes nothing.
#
# Run by mysetup (--do sshagent). $1 = this account's private key path.
# Kept as a script rather than a printf in mysetup.conf because it inspects the
# machine before advising, and advice that ignores the current state is noise.
set -u
KEY="${1:-$HOME/.ssh/id_rsa_$USER}"

if [ -t 1 ]; then
    B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; R=$'\033[0m'
else
    B=""; D=""; G=""; Y=""; C=""; R=""
fi
# Shorten a path for display. The obvious bash anchored-replacement form,
# with $HOME as the pattern, does NOT work: bash re-scans the slashes of the
# expanded $HOME as the pattern delimiter, so it silently never matches.
tilde() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

h()  { printf '\n%s== %s ==%s\n' "$B" "$1" "$R"; }
say() { printf '  %s\n' "$1"; }
cmd() { printf '      %s%s%s\n' "$C" "$1" "$R"; }

# --------------------------------------------------------------------------- #
h "What is running right now"

if [ -n "${SSH_AUTH_SOCK:-}" ]; then
    say "${G}SSH_AUTH_SOCK is set${R}: $SSH_AUTH_SOCK"
    if [ -S "$SSH_AUTH_SOCK" ]; then
        say "the socket exists"
    else
        say "${Y}but that path is not a socket - the agent it pointed at is gone${R}"
    fi
    if out=$(ssh-add -l 2>&1); then
        say "${G}keys currently loaded:${R}"
        printf '      %s\n' "$out"
    else
        case "$out" in
            *"no identities"*) say "${Y}an agent is reachable but holds no keys${R}" ;;
            *)                 say "${Y}$out${R}" ;;
        esac
    fi
else
    say "${Y}SSH_AUTH_SOCK is not set - this shell has no agent${R}"
    say "every git push or ssh will ask for the key passphrase again"
fi

if [ -f "$KEY" ]; then
    if ssh-keygen -y -P "" -f "$KEY" >/dev/null 2>&1; then
        say "$(basename "$KEY") has ${Y}no passphrase${R} - an agent buys you nothing for it"
    else
        say "$(basename "$KEY") is passphrase-protected - this is what an agent is for"
    fi
else
    say "${Y}no key at $KEY${R} - run 'mysetup --do sshkey' first"
fi

# --------------------------------------------------------------------------- #
h "Option 1: the systemd user agent (best where this account has a session)"

UNIT=/usr/lib/systemd/user/ssh-agent.socket
if [ -f "$UNIT" ]; then
    say "openssh-client ships the unit, so there is nothing to write:"
    cmd "systemctl --user enable --now ssh-agent.socket"
    say ""
    say "The socket sets SSH_AUTH_SOCK in the ${B}systemd${R} environment, which an"
    say "ssh login shell never sees, so the shell has to point at it itself."
    say "Add to ~/.psprofile.sh (or ~/.bashrc):"
    cmd 'export SSH_AUTH_SOCK="${XDG_RUNTIME_DIR:-/run/user/$UID}/openssh_agent"'
    say ""
    say "One agent then serves every shell and survives logout only if lingering"
    say "is on - otherwise systemd kills the user session at last logout:"
    cmd "sudo loginctl enable-linger $USER"
    if systemctl --user is-enabled ssh-agent.socket >/dev/null 2>&1; then
        say "${G}already enabled for this account${R}"
    elif ! systemctl --user is-system-running >/dev/null 2>&1; then
        say "${Y}note: no systemd user session is reachable from this shell${R}"
        say "(no XDG_RUNTIME_DIR / DBUS_SESSION_BUS_ADDRESS). Normal in a"
        say "container or a bare 'ssh host cmd'; fine from a real login."
    fi
else
    say "${Y}no ssh-agent.socket unit on this box - use option 2${R}"
fi

# --------------------------------------------------------------------------- #
h "Option 2: one agent per shell (works anywhere, dies with the shell)"
say "Nothing to install, nothing to enable:"
cmd 'eval "$(ssh-agent -s)"'
cmd "ssh-add $(tilde "$KEY")"
say ""
say "Add a lifetime so an unattended terminal does not hold an unlocked key"
say "for ever - here, forget it after 4 hours:"
cmd "ssh-add -t 4h $(tilde "$KEY")"
say ""
say "'ssh-add -D' forgets every key now; 'ssh-add -l' lists what is loaded."

# --------------------------------------------------------------------------- #
h "Option 3: keychain (one agent reused across logins)"
if command -v keychain >/dev/null 2>&1; then
    say "${G}installed${R}. Add to ~/.psprofile.sh:"
else
    say "not installed here ($(apt-cache policy keychain 2>/dev/null | sed -n 's/.*Candidate: //p' | head -1 || echo 'apt has it')):"
    cmd "sudo apt-get install -y keychain"
fi
cmd "eval \$(keychain --eval --quiet $(basename "$KEY"))"
say "It finds an existing agent or starts one, so you unlock the key once per"
say "reboot rather than once per login."

# --------------------------------------------------------------------------- #
h "You already have the half that matters"
say "~/.ssh/config (written by 'mysetup --do sshconfig') sets:"
cmd "AddKeysToAgent yes"
say "so ssh loads the key into the agent the first time it uses it. With an"
say "agent running you are asked for the passphrase once, not per connection."
say ""
say "~/.gitconfig pins the key for git:"
cmd "core.sshCommand = ssh -i $(tilde "$KEY")"
say "so a personal key in the agent cannot be used for this account's pushes"
say "by accident."

# --------------------------------------------------------------------------- #
h "Forwarding an agent FROM Windows - and why it is off here"
say "Windows has its own agent. In an admin PowerShell, once:"
cmd "Set-Service ssh-agent -StartupType Automatic"
cmd "Start-Service ssh-agent"
cmd "ssh-add \$env:USERPROFILE\\.ssh\\id_rsa"
say ""
say "Forwarding it to this box would then let you use the Windows key here:"
cmd "ForwardAgent yes"
say ""
say "${Y}mysetup's ~/.ssh/config deliberately sets 'ForwardAgent no'.${R}"
say "A forwarded agent can be used by anyone with root on the machine you"
say "forwarded it to, for as long as you are connected - they cannot read the"
say "key, but they can sign with it. Turn it on per-host, for hosts you trust,"
say "never in 'Host *'."
printf '\n'
