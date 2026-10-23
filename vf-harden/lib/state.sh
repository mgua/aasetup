# shellcheck shell=bash
# vf-harden/lib/state.sh - the state dir, the ledger of what this tool owns,
# recorded actions, and rollback.
#
#   $STATE_ROOT/                     (root 0700, default /var/lib/vf-harden)
#     owned.tsv                      ledger: kind  key  sha  step  run   (kind = file | step)
#     latest -> runs/<id>            the last --apply run (the --rollback default)
#     lock                           flock, held by --apply / --rollback
#     runs/<id>/meta                 host, os, profile, level, args, tool version
#     runs/<id>/log                  the full run log
#     runs/<id>/steps.tsv            step  status  (OK, ADOPTED, APPLIED, ...)
#     runs/<id>/manifest.tsv         one line per change, written BEFORE the change
#     runs/<id>/files/<abs path>     byte copies of every file modified
#     runs/<id>/rolled-back          present once the run was rolled back
#
# Rule: rollback only ever undoes what a manifest line says this tool did, and
# only when the target is still exactly as this tool left it (sha or mode check).
# Anything changed since is kept and reported, which makes the rollback PARTIAL.

STATE_ROOT="${STATE_ROOT:-/var/lib/vf-harden}"
CUR_STEP="${CUR_STEP:-}"
RUN_ID="${RUN_ID:-}"

state_init_run() {              # state_init_run ARGS... ; sets RUN_ID and RUN_DIR
    RUN_ID="$(date +%Y%m%dT%H%M%S)-${LEVEL}-${MODE}"
    install -d -m 0700 "$STATE_ROOT" "$STATE_ROOT/runs" || die "cannot create $STATE_ROOT"
    RUN_DIR="$STATE_ROOT/runs/$RUN_ID"
    install -d -m 0700 "$RUN_DIR" "$RUN_DIR/files" || die "cannot create $RUN_DIR"
    : > "$RUN_DIR/manifest.tsv"; : > "$RUN_DIR/steps.tsv"
    {
        printf 'run_id=%s\nhost=%s\nos=%s %s\nprofile=%s\nprofile_files=%s\n' \
            "$RUN_ID" "$(hostname -f 2>/dev/null || hostname)" "$OS_ID" "$OS_VERSION" "$PROFILE" "${PROFILE_FILES[*]}"
        printf 'level=%s\nmode=%s\ndry_run=%s\nargs=%s\nby=%s\ntool=%s\n' \
            "$LEVEL" "$MODE" "$DRY_RUN" "$*" "${SUDO_USER:-root}" "$VF_VERSION"
    } > "$RUN_DIR/meta"
    [[ "$MODE" == apply ]] && ln -sfn "runs/$RUN_ID" "$STATE_ROOT/latest"
    return 0
}

state_lock() {
    install -d -m 0700 "$STATE_ROOT" || die "cannot create $STATE_ROOT"
    exec 9>>"$STATE_ROOT/lock"
    flock -n 9 || die "another vf-harden run holds $STATE_ROOT/lock"
}

# manifest_add TYPE FIELDS... : empty fields become '-' (tab-separated read collapses them)
manifest_add() {
    local f line="$CUR_STEP"
    for f in "$@"; do line+=$'\t'"${f:--}"; done
    printf '%s\n' "$line" >> "$RUN_DIR/manifest.tsv" || { err "cannot write the manifest"; return 1; }
}
step_record() { printf '%s\t%s\n' "$1" "$2" >> "$RUN_DIR/steps.tsv"; }

state_backup() {                # state_backup PATH -> prints the backup path
    local src=$1 dst="$RUN_DIR/files$1"
    install -d -m 0700 "$(dirname -- "$dst")" && cp -a -- "$src" "$dst" || return 1
    printf '%s\n' "$dst"
}

# ---- ledger ---------------------------------------------------------------- #
LEDGER() { printf '%s/owned.tsv' "$STATE_ROOT"; }
ledger_owns() {                 # ledger_owns KIND KEY
    [[ -r "$(LEDGER)" ]] || return 1
    awk -F'\t' -v k="$1" -v p="$2" '$1 == k && $2 == p { f = 1 } END { exit !f }' "$(LEDGER)"
}
ledger_set() {                  # ledger_set KIND KEY SHA
    ledger_del "$1" "$2"
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "${3:--}" "$CUR_STEP" "$RUN_ID" >> "$(LEDGER)"
}
ledger_del() {                  # ledger_del KIND KEY
    local l tmp; l=$(LEDGER)
    [[ -e "$l" ]] || return 0
    tmp=$(mktemp "$l.XXXXXX") || return 1
    awk -F'\t' -v k="$1" -v p="$2" '!($1 == k && $2 == p)' "$l" > "$tmp" && mv -f -- "$tmp" "$l"
}

# ---- recorded actions (each one writes its manifest line BEFORE changing anything)
act_perm() {                    # act_perm PATH MAXMODE OWNER "GROUPS"
    local p=$1 max=$2 own=$3 grps=$4 m o g new ng
    m=$(file_mode "$p"); o=$(file_owner "$p"); g=$(file_group "$p")
    new=$(printf '%o' $(( 8#$m & 8#$max )))
    ng=$g
    # shellcheck disable=SC2086
    in_list "$g" $grps || ng=${grps%% *}
    manifest_add perm "$p" "$m" "$o" "$g" "$new" "$own" "$ng" || return 1
    chown "$own:$ng" -- "$p" && chmod "$new" -- "$p"
}

_act_mkdirs() {                 # create missing parent dirs, recording each one
    local d=$1 missing=() i
    while [[ ! -d "$d" ]]; do missing=("$d" "${missing[@]}"); d=$(dirname -- "$d"); done
    for i in "${missing[@]}"; do
        manifest_add dir-created "$i" || return 1
        install -d -m 0755 -o root -g root "$i" || return 1
    done
}

# act_write_file PATH MODE CONTENT : create a file this tool owns (or rewrite one it
# already owns). A file at PATH that this tool did not create is never touched.
act_write_file() {
    local p=$1 mode=$2 content=$3 dir tmp sha b
    dir=$(dirname -- "$p")
    if [[ -e "$p" ]] && ! ledger_owns file "$p"; then
        err "$p exists and was not created by this tool - not touching it"; return 1
    fi
    _act_mkdirs "$dir" || return 1
    tmp=$(mktemp -- "$dir/.vf-harden.XXXXXX") || return 1
    if ! { printf '%s' "$content" > "$tmp" && chmod "$mode" "$tmp" && chown root:root "$tmp"; }; then
        rm -f -- "$tmp"; return 1
    fi
    sha=$(sha_of "$tmp")
    if [[ -e "$p" ]]; then
        b=$(state_backup "$p") && manifest_add file-modified "$p" "$b" "$sha"
    else
        manifest_add file-created "$p" "$sha"
    fi || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$p" || return 1
    ledger_set file "$p" "$sha"
}

# act_replace_file PATH MODE CONTENT : replace the content of an existing system
# file (e.g. /etc/issue). The original is backed up; rollback restores it.
act_replace_file() {
    local p=$1 mode=$2 content=$3 real tmp sha b
    [[ -e "$p" ]] || { act_write_file "$p" "$mode" "$content"; return; }
    real=$(readlink -f -- "$p")
    tmp=$(mktemp -- "$(dirname -- "$real")/.vf-harden.XXXXXX") || return 1
    if ! { printf '%s' "$content" > "$tmp" && chmod "$mode" "$tmp" && chown root:root "$tmp"; }; then
        rm -f -- "$tmp"; return 1
    fi
    sha=$(sha_of "$tmp")
    b=$(state_backup "$real") && manifest_add file-modified "$real" "$b" "$sha" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$real"
}

# act_sed_file PATH SED-EXPR : edit a system file in place (backup + manifest first).
act_sed_file() {
    local p=$1 expr=$2 tmp sha b
    tmp=$(mktemp -- "$(dirname -- "$p")/.vf-harden.XXXXXX") || return 1
    if ! { sed -E "$expr" -- "$p" > "$tmp" && chmod --reference="$p" "$tmp" && chown --reference="$p" "$tmp"; }; then
        rm -f -- "$tmp"; return 1
    fi
    sha=$(sha_of "$tmp")
    b=$(state_backup "$p") && manifest_add file-modified "$p" "$b" "$sha" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$p"
}

act_unit_set() {                # act_unit_set UNIT enabled|disabled
    local u=$1 want=$2
    manifest_add unit "$u" "$(unit_enabled "$u")" "$(unit_active "$u")" "$want" || return 1
    if [[ "$want" == enabled ]]; then
        systemctl enable --now "$u"
    else
        systemctl disable --now "$u" || return 1
        systemctl reset-failed "$u" 2>/dev/null || true
    fi
}

act_restart_later() {           # record a restart that rollback must repeat AFTER undoing the files
    manifest_add restart "$1"
}

act_sysctl_record() {           # record runtime values, so rollback can put them back
    local k
    for k in "$@"; do manifest_add sysctl "$k" "$(sysctl -n "$k" 2>/dev/null)" || return 1; done
}
