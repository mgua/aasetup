# shellcheck shell=bash
# vf-harden/lib/common.sh - logging, small utilities, and the per-step plan.
# Sourced by aasetup_harden.sh; never run on its own.

# --------------------------------------------------------------------------- #
#  Logging (same visual language as aasetup.sh)                               #
# --------------------------------------------------------------------------- #
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m';  C_BOLD=$'\033[1m';   C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
    C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi
RUN_DIR="${RUN_DIR:-}"       # set by state_init_run in apply mode: the run log lives there
DRY_RUN="${DRY_RUN:-0}"
VERBOSE="${VERBOSE:-0}"

_ts()    { date '+%H:%M:%S'; }
_tolog() { [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]] && printf '%s %-6s %s\n' "$(date '+%F %T')" "$1" "$2" >>"$RUN_DIR/log"; return 0; }
log()    { printf '%s %s[ INFO]%s %s\n'  "$(_ts)" "$C_BLUE"   "$C_RESET" "$*"; _tolog INFO "$*"; }
ok()     { printf '%s %s[  OK ]%s %s\n'  "$(_ts)" "$C_GREEN"  "$C_RESET" "$*"; _tolog OK "$*"; }
warn()   { printf '%s %s[ WARN]%s %s\n'  "$(_ts)" "$C_YELLOW" "$C_RESET" "$*" >&2; _tolog WARN "$*"; }
err()    { printf '%s %s[FAIL]%s %s\n'   "$(_ts)" "$C_RED"    "$C_RESET" "$*" >&2; _tolog FAIL "$*"; }
die()    { printf '%s %s[FATAL]%s %s\n'  "$(_ts)" "$C_RED"    "$C_RESET" "$*" >&2; _tolog FATAL "$*"; exit 5; }
phase()  { printf '\n%s==> %s%s\n' "$C_BOLD" "$*" "$C_RESET"; _tolog PHASE "$*"; }

# One journal line per real change (never in check mode or for a no-op run).
journal() { [[ "$DRY_RUN" == 1 ]] && return 0; logger -t vf-harden -- "$*" 2>/dev/null || true; }

# --------------------------------------------------------------------------- #
#  The per-step plan                                                          #
# --------------------------------------------------------------------------- #
# A step's <id>_check is read-only. It registers one item per thing it looked at:
#   item_ok     compliant
#   item_fix    not compliant; carries the action (function + args) that fixes it
#   item_warn   compliant enough, but worth reporting (no action is taken)
#   item_block  a precondition failed: --apply stops before this step
#   item_na     not applicable on this machine
#   item_info   a report line (V10), no effect on the status
# The worst item decides the step status (see step_status).
plan_reset() {
    PLAN_CMDS=(); PLAN_DESC=()
    N_OK=0; N_FIX=0; N_WARN=0; N_BLOCK=0; N_NA=0
}
_item() { printf '      %s%-5s%s %s\n' "$2" "$1" "$C_RESET" "$3"; _tolog "  $1" "$3"; }
item_ok()    { N_OK=$((N_OK + 1));       [[ "$VERBOSE" == 1 ]] && _item ok  "$C_GREEN" "$*"; return 0; }
item_na()    { N_NA=$((N_NA + 1));       [[ "$VERBOSE" == 1 ]] && _item n/a "$C_DIM"  "$*"; return 0; }
item_info()  { _item info "$C_BLUE" "$*"; }
item_warn()  { N_WARN=$((N_WARN + 1));   _item warn "$C_YELLOW" "$*"; }
item_block() { N_BLOCK=$((N_BLOCK + 1)); _item BLOCK "$C_RED" "$*"; }
item_fix() {
    local desc=$1; shift
    N_FIX=$((N_FIX + 1))
    PLAN_DESC+=("$desc")
    PLAN_CMDS+=("$(printf '%q ' "$@")")
    _item fix "$C_YELLOW" "$desc"
}
step_status() {
    if   (( N_BLOCK )); then echo BLOCKER
    elif (( N_FIX ));   then echo WOULD-CHANGE
    elif (( N_WARN ));  then echo WARN
    elif (( N_OK ));    then echo COMPLIANT
    else                     echo N/A
    fi
}

# --------------------------------------------------------------------------- #
#  Small utilities                                                            #
# --------------------------------------------------------------------------- #
file_mode()  { stat -Lc '%a' -- "$1"; }
file_owner() { stat -Lc '%U' -- "$1"; }
file_group() { stat -Lc '%G' -- "$1"; }
sha_of()     { sha256sum -- "$1" 2>/dev/null | awk '{print $1}'; }

# Octal permission bits of $1 that the maximum $2 does not allow ("0" = none).
mode_excess() { printf '%o' $(( 8#$1 & ~8#$2 & 8#7777 )); }

in_list() {                     # in_list WORD LIST...
    local x=$1 y; shift
    for y in "$@"; do [[ "$x" == "$y" ]] && return 0; done
    return 1
}

pkg_installed() {
    # shellcheck disable=SC2016  # ${Status} is a dpkg-query field, not a shell variable
    [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == "install ok installed" ]]
}

unit_exists()  { [[ -n "$(systemctl list-unit-files --no-legend "$1" 2>/dev/null)" ]]; }
unit_enabled() { systemctl is-enabled "$1" 2>/dev/null || true; }   # prints the state, never fails
unit_active()  { systemctl is-active  "$1" 2>/dev/null || true; }

bool_norm() {                   # yes/true/1/on -> yes ; no/false/0/off -> no
    case "${1,,}" in
        yes|true|1|on)  echo yes ;;
        no|false|0|off) echo no ;;
        *)              echo "$1" ;;
    esac
}

# perm_item PATH MAXMODE OWNER "GROUP [GROUP...]"
# Registers ok/fix for one file. The mode may be stricter than MAXMODE; any of the
# listed groups is accepted, and the first one is set when the group is wrong.
perm_item() {
    local p=$1 max=$2 own=$3 grps=$4 m o g bad=""
    if [[ ! -e "$p" ]]; then item_na "$p: absent"; return 0; fi
    m=$(file_mode "$p"); o=$(file_owner "$p"); g=$(file_group "$p")
    [[ "$(mode_excess "$m" "$max")" == 0 ]] || bad="mode $m exceeds $max"
    [[ "$o" == "$own" ]] || bad="${bad:+$bad, }owner $o (want $own)"
    # shellcheck disable=SC2086  # $grps is a word list on purpose
    in_list "$g" $grps || bad="${bad:+$bad, }group $g (want ${grps// /|})"
    if [[ -z "$bad" ]]; then
        item_ok "$p $m $o:$g"
    else
        item_fix "$p: $bad" act_perm "$p" "$max" "$own" "$grps"
    fi
}
