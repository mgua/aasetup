#!/usr/bin/env bash
#
# aasetup_recording.sh
# Session recording for operators and agents (synthian-gate thread 49).
#
#   - installs asciinema + atuin and LOCKS BOTH OFFLINE via AppArmor:
#     shell history and recordings must never leave the machine
#   - atuin = structured LOCAL shell history (host, cwd, exit code,
#     duration per command). No account, no sync, update checks off,
#     secrets filter on. Standard bash keys are kept (no ctrl-r or
#     up-arrow takeover).
#   - asciinema = replayable per-task recordings, started with 'synrec'
#   - 'synrec [recipe-slug]' names the .cast after machine + operator +
#     recipe and appends an index line, so a recording can be tied to the
#     system-recipes recipe it executed
#   - optional always-on tmux pane logging (-t), meant for AGENT accounts
#
# Author: fable (Mr Fox) with mgua + kstefan — design: gate thread 49
# Target: Debian >=12 / Ubuntu >=24.04. Run as root (or via sudo).
# Idempotent: safe to re-run; existing user files are backed up first.
#
# Typical use, after the account exists (aasetup.sh):
#   sudo bash aasetup_recording.sh -u claude -t     # agent: with tmux logging
#   sudo bash aasetup_recording.sh -u tomware       # human: synrec only
#
set -euo pipefail

# --------------------------------------------------------------------------- #
#  Configuration (override via env or CLI flags)                              #
# --------------------------------------------------------------------------- #
MYUSER="${MYUSER:-tomware}"

# bash-preexec: tiny MIT hook library atuin needs on bash. Not packaged in
# Debian/Ubuntu, so we fetch ONE pinned copy at install time (never at shell
# start) and keep it locally.
BASH_PREEXEC_VERSION="${BASH_PREEXEC_VERSION:-0.6.0}"
BASH_PREEXEC_DIR="/usr/local/share/aasetup"
BASH_PREEXEC_FILE="${BASH_PREEXEC_DIR}/bash-preexec.sh"

# Phase toggles (set to 0 to skip a phase)
DO_PACKAGES="${DO_PACKAGES:-1}"
DO_APPARMOR="${DO_APPARMOR:-1}"
DO_ATUIN="${DO_ATUIN:-1}"       # per-user atuin config + bash hook
DO_SYNREC="${DO_SYNREC:-1}"     # /usr/local/bin/synrec wrapper
DO_TMUXLOG="${DO_TMUXLOG:-0}"   # always-on tmux pane logs; AGENT accounts only,
                                # humans must opt in themselves (thread 49)

ATUIN_AVAILABLE=1               # set to 0 when apt has no atuin candidate

# --------------------------------------------------------------------------- #
#  Logging helpers (same as aasetup.sh)                                       #
# --------------------------------------------------------------------------- #
if [[ -t 1 ]]; then
    C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m';  C_BOLD=$'\033[1m';   C_RESET=$'\033[0m'
else
    C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""; C_RESET=""
fi
_ts()  { date '+%H:%M:%S'; }
log()  { printf '%s %s[ INFO]%s %s\n'  "$(_ts)" "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf '%s %s[  OK ]%s %s\n'  "$(_ts)" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '%s %s[ WARN]%s %s\n'  "$(_ts)" "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s %s[FATAL]%s %s\n'  "$(_ts)" "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }
phase(){ printf '\n%s==> %s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

usage() {
    cat <<USAGE
${C_BOLD}aasetup_recording.sh${C_RESET} - session recording tools, locked offline

Usage: sudo $0 [options]

  -u USER   account to prepare        (default: ${MYUSER})
  -t        enable always-on tmux pane logging for this user
            (agent accounts only - humans opt in themselves)
  -h        show this help

Phases can be skipped with env vars set to 0, e.g.:
  DO_APPARMOR=0 sudo -E $0 -u svc_app

What gets installed:
  asciinema + atuin (apt), AppArmor profiles denying them ALL network,
  ~/.config/atuin/config.toml (sync off, update check off, secrets filter),
  the atuin bash hook (standard keys kept), /usr/local/bin/synrec,
  ~/recordings/ and, with -t, tmux hooks logging every pane.
USAGE
}

while getopts ":u:th" opt; do
    case "$opt" in
        u) MYUSER="$OPTARG" ;;
        t) DO_TMUXLOG=1 ;;
        h) usage; exit 0 ;;
        \?) die "Unknown option: -$OPTARG (use -h)" ;;
        :)  die "Option -$OPTARG requires an argument" ;;
    esac
done

HOME_DIR="/home/${MYUSER}"

# --------------------------------------------------------------------------- #
#  Small utilities (same idiom as aasetup.sh)                                 #
# --------------------------------------------------------------------------- #
require_root() {
    [[ "${EUID}" -eq 0 ]] || die "This script must be run as root (use sudo)."
}

run_as_user() { sudo -u "$MYUSER" -H bash -lc "$*"; }

backup_if_exists() {
    local f="$1"
    if [[ -e "$f" ]]; then
        local bak
        bak="${f}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$f" "$bak"
        warn "Existing $(basename "$f") backed up to $bak"
    fi
}

install_user_file() {           # $1 = dest path   $2 = mode (default 0644)
    local dest="$1" mode="${2:-0644}" tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    backup_if_exists "$dest"
    install -o "$MYUSER" -g "$GROUP_NAME" -m "$mode" "$tmp" "$dest"
    rm -f "$tmp"
    ok "Wrote ${dest} (mode ${mode})"
}

# Append a marker-guarded block to a user-owned file (create it if absent).
# Appending as root keeps the file's ownership; creation happens as the user.
append_user_block_once() {      # $1 = file   $2 = marker   (block on stdin)
    local f="$1" marker="$2"
    if [[ -f "$f" ]] && grep -q "$marker" "$f"; then
        log "$(basename "$f") already carries '${marker}' - skipping."
        cat >/dev/null   # drain stdin
        return
    fi
    [[ -f "$f" ]] || run_as_user "touch '$f'"
    cat >> "$f"
    ok "Appended '${marker}' block to ${f}"
}

validate_distro() {
    phase "Validating distribution"
    [[ -r /etc/os-release ]] || die "/etc/os-release not found."
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) ok "${ID} ${VERSION_ID:-testing/sid} detected." ;;
        *)  if [[ " ${ID_LIKE:-} " == *" debian "* || " ${ID_LIKE:-} " == *" ubuntu "* ]]; then
                warn "Unrecognized distro '${ID:-unknown}' but Debian-like; proceeding."
            else
                die "Only Debian/Ubuntu are supported (found: ${ID:-unknown})."
            fi ;;
    esac
    id "$MYUSER" >/dev/null 2>&1 || die "User ${MYUSER} does not exist (run aasetup.sh first)."
    GROUP_NAME="$(id -gn "$MYUSER")"
}

# --------------------------------------------------------------------------- #
#  Phase 1 — packages                                                         #
# --------------------------------------------------------------------------- #
install_packages() {
    phase "Installing asciinema + atuin"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y asciinema
    ok "asciinema installed: $(asciinema --version 2>/dev/null | head -n1)"

    # atuin reached the archives in Debian 13 / Ubuntu 25.10; on older
    # releases we skip it (asciinema + synrec still work) instead of failing.
    # NOT 'policy | grep -q': under pipefail that pipeline can fail on a
    # MATCH (grep -q exits first, apt-cache dies on SIGPIPE) - read fully,
    # then grep. K's pilot run hit exactly that and atuin was skipped.
    local pol
    pol="$(apt-cache policy atuin 2>/dev/null || true)"
    if grep -q 'Candidate: [0-9]' <<<"$pol"; then
        apt-get install -y atuin
        ok "atuin installed: $(atuin --version 2>/dev/null | head -n1)"
    else
        ATUIN_AVAILABLE=0
        warn "No 'atuin' package on this release - skipping the structured-history layer."
    fi
}

install_bash_preexec() {
    [[ "$ATUIN_AVAILABLE" == "1" ]] || return 0
    phase "Installing bash-preexec ${BASH_PREEXEC_VERSION} (atuin's bash hook needs it)"
    if [[ -s "$BASH_PREEXEC_FILE" ]]; then
        log "bash-preexec already present - skipping download."
        return
    fi
    install -d -m 0755 "$BASH_PREEXEC_DIR"
    local url="https://raw.githubusercontent.com/rcaloras/bash-preexec/${BASH_PREEXEC_VERSION}/bash-preexec.sh"
    if curl -fsSL -o "${BASH_PREEXEC_FILE}.tmp" "$url"; then
        # sanity: it must look like the real thing, not an error page
        grep -q "bash-preexec" "${BASH_PREEXEC_FILE}.tmp" \
            || die "Downloaded bash-preexec.sh does not look right - refusing to install it."
        install -m 0644 "${BASH_PREEXEC_FILE}.tmp" "$BASH_PREEXEC_FILE"
        rm -f "${BASH_PREEXEC_FILE}.tmp"
        ok "bash-preexec installed to ${BASH_PREEXEC_FILE}"
    else
        rm -f "${BASH_PREEXEC_FILE}.tmp"
        ATUIN_AVAILABLE=0
        warn "Could not download bash-preexec - atuin recording will NOT work; re-run when online."
    fi
}

# --------------------------------------------------------------------------- #
#  Phase 2 — AppArmor: recording tools get NO network, ever                   #
# --------------------------------------------------------------------------- #
# Shell history and session recordings are exactly the data that must never
# leave the machine (thread 49). Config flags alone are not enough: a config
# mistake, a hostile update or an attack on the tool could still open a
# socket. These profiles cut the network at the kernel, unconditionally.
#
# asciinema needs one exception: the SHELL it records must stay a normal
# shell (ssh to target machines happens inside recorded sessions), so shells
# spawn UNCONFINED (ux) while asciinema itself stays offline.
lockdown_apparmor() {
    phase "Locking recording tools offline (AppArmor)"
    if ! command -v apparmor_parser >/dev/null || [[ ! -d /sys/kernel/security/apparmor ]]; then
        warn "AppArmor is NOT available on this machine."
        warn "The offline guarantee (thread 49, Marco) is NOT enforced here - config flags only."
        return
    fi

    cat > /etc/apparmor.d/usr.bin.atuin <<'PROFILE'
# aasetup_recording.sh: atuin is a LOCAL shell-history recorder here.
# This profile exists for ONE reason: shell history must never leave the
# machine. All file access it may need is allowed; all network is denied.
abi <abi/3.0>,
include <tunables/global>

profile atuin /usr/bin/atuin {
  include <abstractions/base>
  deny network,
  /** mrwlk,
}
PROFILE
    apparmor_parser -r /etc/apparmor.d/usr.bin.atuin
    ok "atuin profile loaded (all network denied)."

    cat > /etc/apparmor.d/usr.bin.asciinema <<'PROFILE'
# aasetup_recording.sh: asciinema records terminal sessions to LOCAL files.
# 'asciinema upload' and any other network use is cut at the kernel. The
# recorded shell itself runs unconfined (ux): sessions must be able to ssh
# to target machines; only the recorder is offline.
abi <abi/3.0>,
include <tunables/global>

profile asciinema /usr/bin/asciinema {
  include <abstractions/base>
  include <abstractions/python>
  deny network,
  /** mrwlk,
  /usr/bin/python3* mrix,
  /bin/bash ux,
  /usr/bin/bash ux,
  /bin/sh ux,
  /usr/bin/sh ux,
  /bin/dash ux,
  /usr/bin/dash ux,
  /usr/bin/zsh ux,
}
PROFILE
    apparmor_parser -r /etc/apparmor.d/usr.bin.asciinema
    ok "asciinema profile loaded (recorder offline, recorded shell normal)."
}

# --------------------------------------------------------------------------- #
#  Phase 3 — per-user atuin: local only, standard keys                        #
# --------------------------------------------------------------------------- #
setup_atuin_user() {
    [[ "$ATUIN_AVAILABLE" == "1" ]] || { warn "atuin unavailable - skipping its per-user setup."; return; }
    phase "Configuring atuin for ${MYUSER} (local only)"

    # Parents as the user, so nothing under ~ ends up root-owned.
    run_as_user "mkdir -p '${HOME_DIR}/.config/atuin'"
    install_user_file "${HOME_DIR}/.config/atuin/config.toml" 0600 <<'ATUINCFG'
## aasetup_recording.sh - atuin as a LOCAL recorder (gate thread 49).
## No account, no sync: nothing leaves this machine. An AppArmor profile
## also denies the binary all network - these flags are belt and braces.
auto_sync = false
update_check = false
sync_frequency = "0"
## skip commands that look like they carry secrets (tokens, passwords)
secrets_filter = true
ATUINCFG

    append_user_block_once "${HOME_DIR}/.bashrc" "aasetup-recording atuin" <<HOOK

# aasetup-recording atuin: record shell history locally (offline by AppArmor).
# Standard bash keys are kept: no ctrl-r takeover, no up-arrow takeover.
if [[ \$- == *i* ]] && command -v atuin >/dev/null 2>&1; then
    source ${BASH_PREEXEC_FILE}
    eval "\$(atuin init bash --disable-up-arrow --disable-ctrl-r)"
fi
HOOK
}

# --------------------------------------------------------------------------- #
#  Phase 4 — synrec: per-task asciinema recording, indexed for recipes        #
# --------------------------------------------------------------------------- #
install_synrec() {
    phase "Installing /usr/local/bin/synrec"
    cat > /usr/local/bin/synrec <<'SYNREC'
#!/usr/bin/env bash
# synrec - record this terminal session with asciinema and index it.
#
#   synrec                      plain recording
#   synrec <recipe-slug>        recording tied to a system-recipes recipe
#
# The recording lands in ~/recordings/ as
#   <datetime>_<machine>_<operator>[_<recipe>].cast
# and one line goes to ~/recordings/INDEX.psv:
#   file|recipe|operator|machine|note
# End the recorded session with 'exit' or ctrl-d.
# Design: synthian-gate thread 49. Never use 'asciinema upload' - the
# recorder is network-blocked by AppArmor on purpose.
set -u
slug="${1:-}"
dir="$HOME/recordings"
mkdir -p "$dir" && chmod 700 "$dir"
name="$(date +%Y%m%d-%H%M%S)_$(hostname -s)_${USER}${slug:+_${slug}}.cast"
echo "synrec: recording to $dir/$name"
asciinema rec "$dir/$name"
note=""
if [[ -t 0 ]]; then
    read -rp "synrec: one line for the index (targets touched, ok/fail; empty = skip): " note || true
fi
printf '%s|%s|%s|%s|%s\n' "$name" "${slug:--}" "$USER" "$(hostname -s)" "$note" >> "$dir/INDEX.psv"
echo "synrec: indexed in $dir/INDEX.psv"
SYNREC
    chmod 0755 /usr/local/bin/synrec
    ok "synrec installed."

    run_as_user "mkdir -p '${HOME_DIR}/recordings' && chmod 700 '${HOME_DIR}/recordings'"
    ok "~/recordings ready (mode 700)."
}

# --------------------------------------------------------------------------- #
#  Phase 5 — optional: always-on tmux pane logging (agent accounts)           #
# --------------------------------------------------------------------------- #
install_tmuxlog() {
    [[ "$DO_TMUXLOG" == "1" ]] || { log "Skipping tmux pane logging (agents opt in with -t)."; return; }
    phase "Enabling tmux pane logging for ${MYUSER}"

    cat > /usr/local/bin/tmux-reclog <<'RECLOG'
#!/usr/bin/env bash
# tmux-reclog - receive one tmux pane's output on stdin, append to a log.
# Wired by aasetup_recording.sh via pipe-pane hooks; one file per pane per day.
set -u
d="$HOME/recordings/tmux"
mkdir -p "$d" && chmod 700 "$d" "$HOME/recordings" 2>/dev/null
exec cat >> "$d/$(date +%Y%m%d)_$(hostname -s)_${1:-s}-${2:-w}-${3:-p}.log"
RECLOG
    chmod 0755 /usr/local/bin/tmux-reclog
    ok "tmux-reclog installed."

    run_as_user "mkdir -p '${HOME_DIR}/recordings/tmux'"
    # -g replaces (idempotent across config reloads); pipe-pane -o only opens
    # a pipe when none is attached, so a re-fired hook never closes logging.
    append_user_block_once "${HOME_DIR}/.tmux.conf" "aasetup-recording tmuxlog" <<'TMUXHOOKS'

# aasetup-recording tmuxlog: log every pane to ~/recordings/tmux (thread 49).
# Applies from the NEXT tmux server start (or: tmux source-file ~/.tmux.conf).
set-hook -g after-new-session 'pipe-pane -o "exec /usr/local/bin/tmux-reclog #{session_name} #{window_index} #{pane_index}"'
set-hook -g after-new-window  'pipe-pane -o "exec /usr/local/bin/tmux-reclog #{session_name} #{window_index} #{pane_index}"'
set-hook -g after-split-window 'pipe-pane -o "exec /usr/local/bin/tmux-reclog #{session_name} #{window_index} #{pane_index}"'
TMUXHOOKS
}

# --------------------------------------------------------------------------- #
#  Phase 6 — self-check: is the offline guarantee actually holding?           #
# --------------------------------------------------------------------------- #
self_check() {
    phase "Self-check"
    local bad=0

    if [[ -d /sys/kernel/security/apparmor ]]; then
        if grep -q '^atuin (enforce)$' /sys/kernel/security/apparmor/profiles 2>/dev/null \
           || [[ "$ATUIN_AVAILABLE" == "0" ]]; then
            ok "atuin profile enforced (or atuin not installed)."
        else
            warn "atuin AppArmor profile NOT in enforce mode!"; bad=1
        fi
        if grep -q '^asciinema (enforce)$' /sys/kernel/security/apparmor/profiles 2>/dev/null; then
            ok "asciinema profile enforced."
        else
            warn "asciinema AppArmor profile NOT in enforce mode!"; bad=1
        fi
    else
        warn "AppArmor not available - offline guarantee NOT enforced."; bad=1
    fi

    # An atuin session file only exists after 'atuin login/register' - which
    # must never happen (no account = nothing to sync to).
    if [[ -e "${HOME_DIR}/.local/share/atuin/session" ]]; then
        warn "${MYUSER} has an atuin SESSION file - an account exists! Remove it and investigate."; bad=1
    else
        ok "No atuin account/session for ${MYUSER}."
    fi

    # The Debian package ships an atuin-server unit. We never run a server.
    if systemctl is-active --quiet atuin-server 2>/dev/null; then
        warn "atuin-server service is RUNNING on this machine - it must not be!"; bad=1
    else
        ok "atuin-server not running."
    fi

    if [[ "$bad" == "1" ]]; then
        printf '%s\n' "${C_RED}${C_BOLD}SELF-CHECK FAILED - the offline guarantee is not fully in place.${C_RESET}" >&2
    else
        ok "All offline guarantees in place."
    fi
}

# --------------------------------------------------------------------------- #
#  Summary                                                                    #
# --------------------------------------------------------------------------- #
summary() {
    phase "Done"
    cat <<SUMMARY
  User .............. ${MYUSER}
  Recordings ........ ${HOME_DIR}/recordings/          (mode 700, stays local)
  Index ............. ${HOME_DIR}/recordings/INDEX.psv (file|recipe|operator|machine|note)
  Record a task ..... synrec <recipe-slug>   (end with 'exit' or ctrl-d)
  Shell history ..... atuin, local sqlite only$( [[ "$DO_TMUXLOG" == "1" ]] && printf '\n  tmux pane logs .... %s/recordings/tmux/ (from next tmux server start)' "$HOME_DIR" )

  Rules (thread 49): recordings never leave the machine; no atuin
  login/register ever; never 'asciinema upload' (blocked anyway); a
  recording that caught a secret gets deleted and mentioned in the thread.
SUMMARY
}

# --------------------------------------------------------------------------- #
#  main                                                                       #
# --------------------------------------------------------------------------- #
main() {
    require_root
    validate_distro

    [[ "$DO_PACKAGES" == "1" ]] && { install_packages; install_bash_preexec; } || log "Skipping packages (DO_PACKAGES=0)."
    [[ "$DO_APPARMOR" == "1" ]] && lockdown_apparmor || log "Skipping AppArmor (DO_APPARMOR=0)."
    [[ "$DO_ATUIN"    == "1" ]] && setup_atuin_user  || log "Skipping atuin user setup (DO_ATUIN=0)."
    [[ "$DO_SYNREC"   == "1" ]] && install_synrec    || log "Skipping synrec (DO_SYNREC=0)."
    install_tmuxlog
    self_check
    summary
}

main "$@"
