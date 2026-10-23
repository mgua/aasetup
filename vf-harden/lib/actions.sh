# shellcheck shell=bash
# vf-harden/lib/actions.sh - more recorded actions (yellow): commands that rewrite
# files we cannot predict (pam-auth-update, useradd -D), groups, remounts, reloads.
# Same rule as lib/state.sh: the manifest line is written BEFORE the change.

# act_cmd_files "FILE..." CMD... : run CMD, which rewrites FILEs. Before: each FILE is
# backed up and recorded with an unknown sha ('-'); after: a 'file-sha' line seals
# the result, so rollback restores a FILE only if it is still what CMD produced.
act_cmd_files() {
    local files=$1 f b; shift
    for f in $files; do
        if [[ -e "$f" ]]; then
            b=$(state_backup "$f") && manifest_add file-modified "$f" "$b" - || return 1
        else
            manifest_add file-created "$f" - || return 1
        fi
    done
    log "run: $*"
    "$@" || { err "command failed: $*"; return 1; }
    for f in $files; do [[ -e "$f" ]] && { manifest_add file-sha "$f" "$(sha_of "$f")" || return 1; }; done
    return 0
}

act_group_create() {            # act_group_create GROUP
    getent group "$1" >/dev/null && return 0
    manifest_add group-created "$1" || return 1
    groupadd "$1" && ok "created group $1"
}

act_group_add() {               # act_group_add USER GROUP
    id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx -- "$2" && return 0
    manifest_add group-member-added "$1" "$2" || return 1
    gpasswd -a "$1" "$2" >/dev/null && ok "$1 added to $2"
}

act_reload_later() {            # rollback reloads UNIT after restoring the files
    manifest_add reload "$1"
}

act_remount() {                 # act_remount MOUNTPOINT ADD_OPTS : live remount, old options recorded
    local mp=$1 add=$2 old
    old=$(findmnt -no OPTIONS --mountpoint "$mp") || { err "$mp is not mounted"; return 1; }
    manifest_add remount "$mp" "$old" || return 1
    mount -o "remount,$add" "$mp"
}

# act_login_defs KEY VALUE : set KEY in /etc/login.defs (edit the active line, or append)
act_login_defs() {
    local k=$1 v=$2
    if grep -Eq "^[[:space:]]*${k}[[:space:]]" /etc/login.defs; then
        act_sed_file /etc/login.defs "s/^[[:space:]]*${k}[[:space:]].*/${k}\t${v}/"
    else
        act_sed_file /etc/login.defs "\$a ${k}\t${v}"
    fi
}

act_note() { manifest_add note "$*"; log "note: $*"; }
