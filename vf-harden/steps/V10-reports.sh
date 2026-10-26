# shellcheck shell=bash
# V10 - read-only reports (runbook V10; script sections 14, 16, 17). Changes
# nothing, ever: the fixes are red R2/R6, decided per item with the owner.
# Unlike the template script (lines 489-494) world-writable files are NOT chmod'ed.
#
# The full lists go to <run dir>/V10-reports.txt in apply mode (check mode only
# prints counts + the first lines). The filesystem scan (SFD-11..13) walks every
# local filesystem at nice 19 / idle I/O: minutes on a big web server. V10_FS_SCAN=no
# in the profile or `-s V10` skips it.

# shellcheck disable=SC2034  # STEP_TITLE/STEP_IDS are read by lib/main.sh
v10_meta() { STEP_TITLE="Reports (accounts, groups, world-writable, SUID)"; STEP_IDS="U22-RT-01..05, UG-03..08, SFD-11..13"; }

V10_OUT=""
_rep() {                        # _rep TAG LINES... : full list to the report file, a summary on screen
    local tag=$1 text=$2 n
    n=$(grep -c . <<<"$text" || true)
    if (( n == 0 )); then item_ok "$tag: none"; return 0; fi
    item_info "$tag: $n$( (( n > 5 )) && printf ' (first 5)'):"
    head -5 <<<"$text" | sed 's/^/              /'
    [[ -n "$V10_OUT" ]] && printf '== %s\n%s\n' "$tag" "$text" >> "$V10_OUT"
    return 0
}

v10_check() {
    [[ -n "$RUN_DIR" && "$DRY_RUN" != 1 ]] && V10_OUT="$RUN_DIR/V10-reports.txt"
    _rep "RT-01 UID 0 besides root" "$(awk -F: '$3 == 0 && $1 != "root" { print $1 }' /etc/passwd)"
    _rep "RT-02 primary GID 0" "$(awk -F: '$4 == 0 && $1 !~ /^(root|sync|shutdown|halt|operator)$/ { print $1 }' /etc/passwd)"
    _rep "RT-03 groups with GID 0 besides root" "$(awk -F: '$3 == 0 && $1 != "root" { print $1 }' /etc/group)"
    _rep "RT-05 root PATH problems" "$(v10_root_path)"
    _rep "UG-03 GIDs in passwd missing from group" "$(v10_missing_gids)"
    _rep "UG-04 members of group shadow" "$(awk -F: '$1 == "shadow" && $4 != "" { print $4 }' /etc/group)"
    local dup_uid
    dup_uid=$(cut -d: -f3 /etc/passwd | sort | uniq -d | while IFS= read -r u; do
        printf 'UID %s: %s\n' "$u" "$(awk -F: -v u="$u" '$3 == u { printf "%s ", $1 }' /etc/passwd)"; done)
    [[ -n "$dup_uid" && "$PROFILE" == plesk ]] && item_info "UG-05: on Plesk, extra FTP users share the site user's UID (expected)"
    _rep "UG-05 duplicate UIDs" "$dup_uid"
    _rep "UG-06 duplicate GIDs" "$(cut -d: -f3 /etc/group | sort | uniq -d)"
    _rep "UG-07 duplicate user names" "$(cut -d: -f1 /etc/passwd | sort | uniq -d)"
    _rep "UG-08 duplicate group names" "$(cut -d: -f1 /etc/group | sort | uniq -d)"
    if command -v aa-enabled >/dev/null 2>&1; then
        _rep "AA-01 AppArmor not enabled" "$(aa-enabled --quiet 2>/dev/null || echo 'aa-enabled: no')"
    fi
    if [[ "${V10_FS_SCAN:-yes}" == yes ]]; then v10_fs_scan; else item_info "SFD-11..13 filesystem scan skipped (V10_FS_SCAN=no)"; fi
    return 0
}

v10_root_path() {
    local p d
    # shellcheck disable=SC2016  # literal text on purpose: expanded later, not here
    p=$(env -i HOME=/root TERM=dumb bash -lc 'printf %s "$PATH"' </dev/null 2>/dev/null | tail -1)
    tr ':' '\n' <<<"$p" | while IFS= read -r d; do
        [[ -z "$d" || "$d" == . ]] && { echo "empty or '.' entry in root PATH"; continue; }
        [[ -d "$d" ]] || { [[ -e "$d" ]] && echo "$d is not a directory"; continue; }
        [[ "$(stat -Lc %U "$d")" == root ]] || echo "$d not owned by root"
        [[ "$(mode_excess "$(stat -Lc %a "$d")" 1755)" == 0 ]] || echo "$d writable by group/other"
    done
}

v10_missing_gids() {
    local g
    while read -r g; do
        awk -F: -v g="$g" '$3 == g { f = 1 } END { exit !f }' /etc/group || echo "GID $g"
    done < <(cut -d: -f4 /etc/passwd | sort -un)
}

# One pass per local filesystem, four tests at once (GNU find's comma operator).
v10_fs_scan() {
    local mnt raw www=${PLESK_VHOSTS:-/var/www/vhosts}
    raw=$(findmnt -rn -o TARGET,FSTYPE | awk '$2 ~ /^(ext[234]|xfs|btrfs|zfs|f2fs|jfs)$/ { print $1 }' |
        while IFS= read -r mnt; do
            nice -n 19 ionice -c 3 find "$mnt" -xdev \
                \( -path /proc -o -path /sys -o -path /run -o -path /dev -o -path '/snap/*' \) -prune -o \
                \( \( -type f -perm -0002 -printf 'WWF %p\n' \) , \
                   \( -type d -perm -0002 ! -perm -1000 -printf 'WWD %p\n' \) , \
                   \( \( -nouser -o -nogroup \) -printf 'NOOWN %p\n' \) , \
                   \( -type f -perm /6000 -printf 'SUID %p\n' \) \) 2>/dev/null
        done)
    _rep "SFD-11 world-writable files outside $www" "$(awk -v w="$www/" '$1 == "WWF" && index($2, w) != 1 { print $2 }' <<<"$raw")"
    _rep "SFD-11 world-writable files under $www (customer files: report only)" "$(awk -v w="$www/" '$1 == "WWF" && index($2, w) == 1 { print $2 }' <<<"$raw")"
    _rep "SFD-11 world-writable dirs without sticky bit" "$(awk '$1 == "WWD" { print $2 }' <<<"$raw")"
    _rep "SFD-12 files without owner/group" "$(awk '$1 == "NOOWN" { print $2 }' <<<"$raw")"
    local suid notpkg
    suid=$(awk '$1 == "SUID" { print $2 }' <<<"$raw")
    item_info "SFD-13 SUID/SGID files: $(grep -c . <<<"$suid" || true)"
    [[ -n "$V10_OUT" ]] && printf '== SFD-13 SUID/SGID baseline\n%s\n' "$suid" >> "$V10_OUT"
    notpkg=$(while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        dpkg -S "$f" >/dev/null 2>&1 || dpkg -S "/usr$f" >/dev/null 2>&1 || dpkg -S "${f#/usr}" >/dev/null 2>&1 || echo "$f"
    done <<<"$suid")
    _rep "SFD-13 SUID/SGID files not from any package (investigate)" "$notpkg"
}
