#!/usr/bin/env bash
#
# aasetup_harden.sh
# Server hardening to the VF G-0312 standard (CIS Ubuntu 22.04, condensed), by
# risk level, on a server that may already be in production.
#
#   - three levels, following Fabio's runbook: green (no behaviour change),
#     yellow (changes what users/apps can do), red (may stop a service, needs a
#     reboot, or is not cleanly reversible). All three are implemented; red
#     applies only with -R and one named step at a time (-o).
#   - --check (default) is read-only: per step, what is compliant, what was
#     applied by someone else ("adopted"), and what would change
#   - --apply changes only what is not compliant, verifies every step, and runs a
#     no-harm check after it; a failing step is rolled back and the run stops
#   - --rollback undoes one recorded --apply run, and only what this tool did
#   - profiles carry the exceptions: "plesk" is picked automatically when
#     /usr/local/psa exists
#
# The step code lives in vf-harden/ (one file per runbook step); see
# vf-harden/README.md for what each level covers, the state dir and exit codes.
#
# Author: aalbano@tomware.it (with Claude), from Fabio Montini's runbook and the
#         work on twsplesk03 / twsplesk71, 2026-10.
# Target: Ubuntu 24.04 and 26.04. Run as root (or via sudo).
#
# No 'set -e' on purpose: checks rely on non-zero returns, and every action's
# result is tested explicitly (as in aasetup_all.sh).
set -uo pipefail

VF_ENTRY="$(readlink -f "${BASH_SOURCE[0]}")"
VF_DIR="$(dirname "$VF_ENTRY")/vf-harden"
VF_VERSION="$(git -C "$(dirname "$VF_ENTRY")" describe --always --dirty 2>/dev/null || echo unknown)"

# --------------------------------------------------------------------------- #
#  Configuration (override via CLI flags)                                     #
# --------------------------------------------------------------------------- #
LEVEL=""                        # -l green|yellow|red
MODE=check                      # -c (default) | -a | -r RUN
PROFILE_REQ=auto                # -p auto|default|plesk
ONLY=""; SKIP=""                # -o / -s  comma lists of step IDs
DRY_RUN=0                       # -n
EXPECT_NOOP=0                   # -x
ROLLBACK_RUN=""                 # -r RUN_ID|latest
ASSUME_YES=0                    # -y
VERBOSE=0                       # -v
AIDE_BASELINE=0                 # -b
CONSOLE_OK=0                    # -C  console open + second root session (needed for G3)
RED_OK=0                        # -R  "I accept red risks" (needed for any red apply)
AUDIT_MAKE_IMMUTABLE=0          # -E  R3: lock the audit rules (-e 2) after the observation period
STATE_ROOT="/var/lib/vf-harden" # -S DIR
ORIG_ARGS=("$@")

for lib in common parse net pam accounts state actions sysctl rollback pkg main modes; do
    # shellcheck disable=SC1090
    . "$VF_DIR/lib/$lib.sh" || { echo "cannot load $VF_DIR/lib/$lib.sh" >&2; exit 5; }
done

usage() {
    cat <<USAGE
${C_BOLD}aasetup_harden.sh${C_RESET} - VF G-0312 hardening by level, with check / apply / rollback

Usage: sudo bash $0 -l LEVEL [mode] [options]

  -l LEVEL   green | yellow | red
Mode (one of):
  -c         check: read-only report per step              (default)
  -a         apply: change only what is not compliant, verify each step
  -r RUN     rollback: undo the --apply run RUN ('latest' = the last one of
             this level); with -o STEP only that step, e.g. -o G3 -r latest
Options:
  -p PROFILE auto | default | plesk   (default: auto = plesk if /usr/local/psa exists)
  -o STEPS   only these steps, e.g. -o V2,V9
  -s STEPS   skip these steps, e.g. -s V10 (V10 scans every local filesystem)
  -n         with -a: dry run - show the actions, change nothing, write nothing
  -x         with -a: expect a no-op - stop with exit 1 BEFORE the first change
  -b         with -a: V8 also starts the AIDE baseline (long, idle I/O; off-hours)
  -C         with -a: a console session is open and a second root session is
             ready: allows G3 (PAM faillock) in a full yellow run
  -R         with -a on red: "I accept red risks" - required, together with -o
             naming the step(s): red never applies a whole level at once
  -E         with -a -o R3: also lock the audit rules (-e 2), only after
             AUDIT_OBSERVE_DAYS of running them; effective at the next reboot
  -S DIR     state root                 (default: ${STATE_ROOT})
  -y         rollback without the confirmation prompt
  -v         verbose: also list compliant and not-applicable items
  -h         show this help

Examples:
  sudo bash $0 -l green                  # what is compliant, adopted, would change
  sudo bash $0 -l green -a -n            # the exact actions, nothing changed
  sudo bash $0 -l green -a               # apply + verify, record in ${STATE_ROOT}
  sudo bash $0 -l green -r latest        # undo that run (UNTESTED - see README)
  sudo bash $0 -l yellow                 # yellow check (SSH, PAM, sudo, su, network, ...)
  sudo bash $0 -l yellow -a -s G3        # yellow apply without PAM faillock
  sudo bash $0 -l yellow -a -o G3        # PAM faillock alone, console open
  sudo bash $0 -l red                    # red check (read-only)
  sudo bash $0 -l red -a -R -o R1        # one red step, explicitly accepted

Exit codes: 0 ok, 1 would change, 2 apply failed (step rolled back), 3 blocker,
4 rollback partial, 5 usage/environment.  Details: vf-harden/README.md
USAGE
}

# --------------------------------------------------------------------------- #
#  Argument parsing                                                           #
# --------------------------------------------------------------------------- #
while getopts ":l:car:p:o:s:nxbCRES:yvh" opt; do
    case "$opt" in
        l) LEVEL="$OPTARG" ;;
        c) MODE=check ;;
        a) MODE=apply ;;
        r) MODE=rollback; ROLLBACK_RUN="$OPTARG" ;;
        p) PROFILE_REQ="$OPTARG" ;;
        o) ONLY="${OPTARG^^}" ;;
        s) SKIP="${OPTARG^^}" ;;
        n) DRY_RUN=1 ;;
        x) EXPECT_NOOP=1 ;;
        b) AIDE_BASELINE=1 ;;
        C) CONSOLE_OK=1 ;;
        R) RED_OK=1 ;;
        E) AUDIT_MAKE_IMMUTABLE=1 ;;
        S) STATE_ROOT="$OPTARG" ;;
        y) ASSUME_YES=1 ;;
        v) VERBOSE=1 ;;
        h) usage; exit 0 ;;
        \?) die "Unknown option: -$OPTARG (use -h)" ;;
        :)  die "Option -$OPTARG requires an argument" ;;
    esac
done
shift $((OPTIND - 1))
(( $# == 0 )) || die "Unexpected argument(s): $* (use -h)"

case "$LEVEL" in
    green)      LEVEL_STEPS=(V1 V2 V4 V5 V7 V8 V9 V10) ;;   # V3 and V6 moved to yellow (2026-10-22)
    yellow)     # non-access steps first, then the access steps, the riskiest last (G3)
                LEVEL_STEPS=(V3 G5 G6 G7 G8 G9 G10 G11 V6 G2 G1 G4 G3) ;;
    red)        # reports first, the reversible-in-config steps next, GRUB last
                LEVEL_STEPS=(R6 R2 R1 R7 R5 R3 R4) ;;
    "")         usage; die "Missing -l LEVEL." ;;
    *)          die "Unknown level '$LEVEL' (green|yellow|red)." ;;
esac
[[ "$DRY_RUN" == 1 && "$MODE" != apply ]] && die "-n only makes sense with -a"
[[ "$EXPECT_NOOP" == 1 && "$MODE" != apply ]] && die "-x only makes sense with -a"
if [[ "$LEVEL" == red && "$MODE" == apply && "$DRY_RUN" != 1 ]]; then
    [[ "$RED_OK" == 1 ]] || die "red apply needs -R (I accept red risks): it may stop a service, needs a reboot or is not cleanly reversible."
    [[ -n "$ONLY" ]] || die "red applies one step at a time: name it with -o (e.g. -o R1); several only if -o lists them."
fi
[[ "$AUDIT_MAKE_IMMUTABLE" == 1 && ",$ONLY," != *",R3,"* ]] && die "-E only together with -o R3"

# --------------------------------------------------------------------------- #
#  main                                                                       #
# --------------------------------------------------------------------------- #
main() {
    phase "VF G-0312 hardening - level ${LEVEL}, mode ${MODE}$([[ "$DRY_RUN" == 1 ]] && printf ' (dry run)')"
    require_root
    validate_distro
    tree_safety
    profile_load "$PROFILE_REQ"
    log "Profile: ${PROFILE} (${PROFILE_FILES[*]}); state root: ${STATE_ROOT}; tool ${VF_VERSION}"
    load_steps
    case "$MODE" in
        check)    mode_check ;;
        apply)    mode_apply ;;
        rollback) mode_rollback ;;
    esac
}

main
exit $?
