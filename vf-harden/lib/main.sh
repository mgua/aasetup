# shellcheck shell=bash
# vf-harden/lib/main.sh - profile loading, preconditions, per-step dispatch,
# the three modes and the summary. Sourced by aasetup_harden.sh.
#
# Step contract (steps/<ID>-<name>.sh, function prefix = lowercase ID, e.g. v4_):
#   <id>_meta    sets STEP_TITLE and STEP_IDS (the U22 control IDs)
#   <id>_check   READ-ONLY; registers items (lib/common.sh). Fix items carry the
#                action that --apply runs; actions record themselves (lib/state.sh).
# Verification = <id>_check again after the actions (must not be WOULD-CHANGE or
# BLOCKER) + the no-harm check (health_check). On failure, that step is rolled back
# and the run stops.

declare -A STEP_EXCEPTION=()    # profile: STEP_EXCEPTION[V3]="reason for the scanner"
PROFILE_FILES=()
RESULTS=()                      # "ID<TAB>STATUS<TAB>TITLE" for the summary

# --------------------------------------------------------------------------- #
#  Profile                                                                    #
# --------------------------------------------------------------------------- #
_safe_to_source() {             # root-owned and not writable by group/other
    [[ "$(stat -c '%U' -- "$1")" == root && "$(mode_excess "$(stat -c '%a' -- "$1")" 755)" == 0 ]]
}

profile_load() {                # profile_load auto|default|plesk|...
    local want=$1 f
    if [[ "$want" == auto ]]; then
        if [[ -d /usr/local/psa ]]; then want=plesk; else want=default; fi
    fi
    [[ -f "$VF_DIR/profiles/$want.conf" ]] || die "unknown profile '$want' (no profiles/$want.conf)"
    PROFILE=$want
    local files=("$VF_DIR/profiles/default.conf")
    [[ "$want" != default ]] && files+=("$VF_DIR/profiles/$want.conf")
    files+=("$VF_DIR/profiles.local/default.conf")
    [[ "$want" != default ]] && files+=("$VF_DIR/profiles.local/$want.conf")
    for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        if ! _safe_to_source "$f"; then
            [[ "$MODE" == check ]] || die "refusing to source $f: not root-owned or writable by group/other"
            warn "$f is not root-owned or is group/other-writable (allowed for --check only)"
        fi
        # shellcheck disable=SC1090
        . "$f"
        PROFILE_FILES+=("${f#"$VF_DIR"/}")
    done
}

tree_safety() {                 # the scripts run as root: they must not be writable by others
    local bad
    bad=$(find "$VF_DIR" "$VF_ENTRY" \( ! -user root -o -perm /022 \) -print 2>/dev/null | head -5)
    [[ -z "$bad" ]] && return 0
    [[ "$MODE" == check ]] || die "refusing to run as root from files not owned by root or writable by others: $bad"
    warn "files not root-owned or writable by others (fine for --check, refused for --apply): $(tr '\n' ' ' <<<"$bad")"
}

# --------------------------------------------------------------------------- #
#  Preconditions                                                              #
# --------------------------------------------------------------------------- #
require_root() { [[ "${EUID}" -eq 0 ]] || die "This script must be run as root (use sudo)."; }

validate_distro() {
    [[ -r /etc/os-release ]] || die "/etc/os-release not found."
    # shellcheck disable=SC1091
    OS_ID=$(. /etc/os-release; printf '%s' "${ID:-}")
    # shellcheck disable=SC1091
    OS_VERSION=$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")
    case "$OS_ID:$OS_VERSION" in
        ubuntu:24.04|ubuntu:26.04) ok "Ubuntu ${OS_VERSION} detected." ;;
        *) [[ "${FORCE_OS:-0}" == 1 ]] || die "Only Ubuntu 24.04 and 26.04 are supported (found: ${OS_ID} ${OS_VERSION}); FORCE_OS=1 to override."
           warn "Unsupported OS ${OS_ID} ${OS_VERSION} - FORCE_OS=1 given, continuing." ;;
    esac
}

busy_check() {                  # no package manager or Plesk installer may be running
    local p n
    # Not `pgrep -x unattended-upgr`: the comm name is truncated to 15 chars and also
    # matches unattended-upgrade-shutdown, which Ubuntu keeps running all the time.
    p=$(for n in apt apt-get aptitude dpkg; do pgrep -a -x "$n"; done 2>/dev/null
        pgrep -a -f '/usr/bin/unattended-upgrade( |$)' 2>/dev/null
        pgrep -a -f 'psa/admin/sbin/autoinstaller|plesk-installer' 2>/dev/null)
    [[ -z "$p" ]] || die "package manager or Plesk installer running, try later: $(head -2 <<<"$p" | tr '\n' ' ')"
}

# --------------------------------------------------------------------------- #
#  No-harm check                                                              #
# --------------------------------------------------------------------------- #
# Taken lazily, right before the FIRST change of a run (so a no-op run does not even
# run `sudo -n true`, which would write a sudo log line).
_failed_units() { systemctl --failed --no-legend --plain 2>/dev/null | awk '{ print $1 }' | LC_ALL=C sort; }
_sshd_ok()      { command -v sshd >/dev/null 2>&1 || return 0; sshd -t >/dev/null 2>&1; }
_visudo_ok()    { command -v visudo >/dev/null 2>&1 || return 0; visudo -c >/dev/null 2>&1; }
_admin_sudo_ok() {              # the admin who ran us can still sudo without a prompt
    [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] || return 0
    runuser -u "$SUDO_USER" -- sudo -n true >/dev/null 2>&1
}
H_TAKEN=0

health_snapshot() {
    (( H_TAKEN )) && return 0
    H_FAILED=$(_failed_units)
    if _sshd_ok; then H_SSHD=ok; else H_SSHD=bad; fi
    if _visudo_ok; then H_VISUDO=ok; else H_VISUDO=bad; fi
    if _admin_sudo_ok; then H_SUDO=ok; else H_SUDO=bad; fi
    H_TAKEN=1
}

health_check() {
    local new
    new=$(comm -13 <(printf '%s\n' "$H_FAILED") <(_failed_units) | sed '/^$/d' | tr '\n' ' ')
    [[ -z "$new" ]] || { err "no-harm: new failed units: $new"; return 1; }
    if [[ "$H_SSHD" == ok ]] && ! _sshd_ok; then err "no-harm: sshd -t fails now"; return 1; fi
    if [[ "$H_VISUDO" == ok ]] && ! _visudo_ok; then err "no-harm: visudo -c fails now"; return 1; fi
    if [[ "$H_SUDO" == ok ]] && ! _admin_sudo_ok; then err "no-harm: 'sudo -n true' fails now for $SUDO_USER"; return 1; fi
    if [[ -n "${HEALTHCHECK_HOOK:-}" ]]; then
        [[ -x "$HEALTHCHECK_HOOK" ]] || { err "no-harm: HEALTHCHECK_HOOK $HEALTHCHECK_HOOK not executable"; return 1; }
        "$HEALTHCHECK_HOOK" > "$RUN_DIR/health-$CUR_STEP.txt" 2>&1 \
            || { err "no-harm: $HEALTHCHECK_HOOK failed (see $RUN_DIR/health-$CUR_STEP.txt)"; return 1; }
    fi
    return 0
}

# --------------------------------------------------------------------------- #
#  Steps                                                                      #
# --------------------------------------------------------------------------- #
step_selected() {
    local id=$1
    [[ -z "$ONLY" || ",$ONLY," == *",$id,"* ]] && [[ ",$SKIP," != *",$id,"* ]]
}

load_steps() {
    local id f
    for id in "${LEVEL_STEPS[@]}"; do
        f=$(compgen -G "$VF_DIR/steps/${id:0:1}$(printf '%02d' "${id:1}")-*.sh" | head -1)
        [[ -n "$f" ]] || die "no step file for $id in $VF_DIR/steps/"
        # shellcheck disable=SC1090
        . "$f"
    done
}

# check_step ID -> sets ST (status) ; prints the step header and its items
check_step() {
    local id=$1 fn=${1,,}
    CUR_STEP=$id; plan_reset
    "${fn}_meta"
    phase "$id  $STEP_TITLE  ($STEP_IDS)"
    if [[ -n "${STEP_EXCEPTION[$id]:-}" ]]; then
        item_info "profile exception: ${STEP_EXCEPTION[$id]}"; ST=EXCEPTION; return 0
    fi
    "${fn}_check"
    ST=$(step_status)
    if [[ "$ST" == COMPLIANT || "$ST" == WARN ]]; then
        if ledger_owns step "$id"; then ST="OK${ST/COMPLIANT/}"; else ST="ADOPTED${ST/COMPLIANT/}"; fi
        ST=${ST/WARN/+WARN}
    fi
}

_print_status() {
    local c=$C_GREEN
    case "$1" in WOULD-CHANGE|*WARN*|EXCEPTION) c=$C_YELLOW ;; BLOCKER|FAILED*) c=$C_RED ;; N/A) c=$C_DIM ;; esac
    printf '    %s=> %s%s\n' "$c" "$1" "$C_RESET"; _tolog STATUS "$CUR_STEP $1"
}

# apply_step ID : run the plan registered by the last check, verify, no-harm check
apply_step() {
    local id=$1 i
    health_snapshot
    for i in "${!PLAN_CMDS[@]}"; do
        log "apply: ${PLAN_DESC[$i]}"
        if ! eval "${PLAN_CMDS[$i]}"; then
            err "$id: action failed: ${PLAN_DESC[$i]}"; _undo_step "$id"; return 2
        fi
    done
    log "verify $id"
    check_step "$id"
    if [[ "$ST" == WOULD-CHANGE || "$ST" == BLOCKER ]]; then
        err "$id: still $ST after applying"; _undo_step "$id"; return 2
    fi
    health_check || { _undo_step "$id"; return 2; }
    ledger_set step "$id" -
    journal "$id applied and verified (run $RUN_ID)"
    ST=APPLIED
}

_undo_step() {
    warn "$1: rolling this step back"
    journal "$1 failed, rolled back (run $RUN_ID)"
    state_rollback "$RUN_DIR" "$1" || warn "$1: rollback was PARTIAL - see $RUN_DIR/log"
}
