# shellcheck shell=bash
# vf-harden/lib/modes.sh - the three modes (check / apply / rollback) and the summary.
#
# Exit codes (also in README.md):
#   0  check: everything compliant/adopted (warnings allowed) | apply: done, verified
#      | rollback: complete
#   1  check: at least one step WOULD-CHANGE | apply -x: a step would change, stopped
#      before touching it | apply: a step was HELD (G3 without -C / -o G3)
#   2  apply: a step failed its action/verification/no-harm check; that step was
#      rolled back and the run stopped
#   3  a step reported a BLOCKER (precondition); apply stops before that step
#   4  rollback finished PARTIAL (something changed since; kept and listed)
#   5  usage / environment error (not root, unsupported OS, lock held, unsafe files)

_result() { RESULTS+=("$1"$'\t'"$2"$'\t'"$STEP_TITLE"); }
REBOOT_REQUIRED=()              # filled by steps whose change takes effect at boot (R3 locked, R4, R5)

summary() {
    local r id st title c
    phase "Summary (level ${LEVEL}, profile ${PROFILE}, mode ${MODE}$([[ "$DRY_RUN" == 1 ]] && printf ', dry run'))"
    for r in "${RESULTS[@]}"; do
        IFS=$'\t' read -r id st title <<<"$r"
        c=$C_GREEN
        case "$st" in WOULD-CHANGE*|*WARN*|EXCEPTION) c=$C_YELLOW ;; BLOCKER|FAILED*) c=$C_RED ;; N/A) c=$C_DIM ;; esac
        printf '  %-4s %s%-16s%s %s\n' "$id" "$c" "$st" "$C_RESET" "$title"
        _tolog SUMMARY "$id $st $title"
    done
    [[ -n "$RUN_DIR" ]] && printf '\n  Run record: %s\n' "$RUN_DIR"
    if (( ${#REBOOT_REQUIRED[@]} )); then
        printf '\n  %sREBOOT REQUIRED%s for: %s - this tool never reboots; do it attended, console open.\n' \
            "$C_RED$C_BOLD" "$C_RESET" "${REBOOT_REQUIRED[*]}"
        _tolog REBOOT "required for ${REBOOT_REQUIRED[*]}"
    fi
    return 0
}

mode_check() {
    local id rc=0
    for id in "${LEVEL_STEPS[@]}"; do
        step_selected "$id" || continue
        check_step "$id"; _print_status "$ST"; _result "$id" "$ST"
        case "$ST" in
            WOULD-CHANGE) (( rc == 0 )) && rc=1 ;;
            BLOCKER)      rc=3 ;;
        esac
    done
    summary
    return $rc
}

mode_apply() {
    local id changed=0 held=0
    busy_check
    if [[ "$DRY_RUN" != 1 ]]; then state_lock; state_init_run "${ORIG_ARGS[@]}"; fi
    for id in "${LEVEL_STEPS[@]}"; do
        step_selected "$id" || continue
        check_step "$id"; _print_status "$ST"
        case "$ST" in
            BLOCKER)
                _record "$id"; summary; err "stopped at $id: resolve the BLOCKER first (nothing in $id was changed)"; return 3 ;;
            WOULD-CHANGE)
                if [[ "$DRY_RUN" == 1 ]]; then
                    log "dry run: ${#PLAN_CMDS[@]} action(s) not executed"
                elif ! console_gate "$id"; then
                    ST="HELD"; held=1
                    warn "$id is held: it needs -C (console open, second root session) or to be run alone with -o $id"
                elif [[ "${EXPECT_NOOP:-0}" == 1 ]]; then
                    _record "$id"; summary
                    err "$id would change something, and -x expects a no-op: stopped before touching it"; return 1
                else
                    if ! apply_step "$id"; then ST=FAILED; _record "$id"; summary; return 2; fi
                    changed=$((changed + 1)); _print_status "$ST"
                fi ;;
        esac
        _record "$id"
    done
    summary
    if [[ "$DRY_RUN" != 1 ]] && (( changed == 0 )); then
        log "no-op: nothing was changed; only the run record in $RUN_DIR was written"
    fi
    (( held )) && return 1
    return 0
}

# Steps in CONSOLE_STEPS (profile; default G3) are applied only with -C, or when
# they are the only step selected (-o G3).
console_gate() {
    in_list "$1" $CONSOLE_STEPS || return 0
    [[ "$CONSOLE_OK" == 1 || "$ONLY" == "$1" ]]
}

_record() { _result "$1" "$ST"; [[ "$DRY_RUN" == 1 || -z "$RUN_DIR" ]] || step_record "$1" "$ST"; }

mode_rollback() {
    local rd n ans
    state_lock
    if [[ "$ROLLBACK_RUN" == latest ]]; then
        rd=$(ls -1d "$STATE_ROOT"/runs/*-"$LEVEL"-apply 2>/dev/null | tail -1)
        [[ -n "$rd" ]] || die "no ${LEVEL} --apply run recorded in $STATE_ROOT"
    else
        rd="$STATE_ROOT/runs/$ROLLBACK_RUN"
    fi
    [[ -d "$rd" && -f "$rd/meta" ]] || die "no such run: $rd"
    grep -qx 'mode=apply' "$rd/meta" || die "$rd is not an --apply run"
    grep -qx "level=$LEVEL" "$rd/meta" || die "$rd was not a ${LEVEL} run (use the matching level)"
    grep -qx 'dry_run=0' "$rd/meta" || die "$rd was a dry run: nothing to undo"
    [[ -e "$rd/rolled-back" ]] && die "$rd was already rolled back"
    RUN_DIR=$rd; RUN_ID=${rd##*/}
    n=$(grep -c . "$rd/manifest.tsv" 2>/dev/null || true)
    phase "Rollback of run ${RUN_ID} (${n:-0} recorded change(s)) - UNTESTED code path"
    sed 's/^/      /' "$rd/manifest.tsv"
    if [[ "${ASSUME_YES:-0}" != 1 ]]; then
        [[ -r /dev/tty ]] || die "no terminal to confirm on: use -y"
        read -r -p "Undo these changes, newest first? [y/N] " ans </dev/tty
        [[ "$ans" == [yY]* ]] || { log "declined - nothing undone"; return 0; }
    fi
    if [[ -n "$ONLY" ]]; then
        local s rc=0
        for s in ${ONLY//,/ }; do
            log "rollback of step $s only"
            state_rollback "$rd" "$s" || rc=4
        done
        journal "run $RUN_ID: steps $ONLY rolled back (rc $rc)"
        (( rc == 0 )) && ok "steps $ONLY rolled back" || warn "rollback of $ONLY PARTIAL"
        return $rc
    fi
    if state_rollback "$rd"; then
        date '+%F %T full' > "$rd/rolled-back"; journal "run $RUN_ID rolled back (full)"; ok "rollback complete"; return 0
    fi
    date '+%F %T partial' > "$rd/rolled-back.partial"
    journal "run $RUN_ID rolled back PARTIALLY"
    warn "rollback PARTIAL: the items above marked WARN were kept; it can be re-run after fixing them"
    return 4
}
