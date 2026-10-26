# shellcheck shell=bash
# G11 - mount options on EXISTING partitions (runbook G11; script lines 103-137).
#   /dev/shm                     nodev,nosuid,noexec   (fstab line added if missing)
#   /home, /var                  nodev,nosuid           only if a separate mount
#   /var/tmp, /var/log(/audit)   nodev,nosuid,noexec    only if a separate mount
# Compliant = the LIVE options and the fstab line (so it survives a reboot, server A
# 2026-10-19). Never /tmp: tmpfs+noexec there is R5 (red). Before noexec on
# /dev/shm: a process with an EXECUTABLE mapping in /dev/shm is a BLOCKER (Oracle,
# some Java runtimes, headless browsers).

# shellcheck disable=SC2034  # STEP_TITLE/STEP_IDS are read by lib/main.sh
g11_meta() { STEP_TITLE="Mount options (existing partitions)"; STEP_IDS="U22-FP-01..14, 17, 18"; }

G11_MOUNTS="/dev/shm:nodev,nosuid,noexec /home:nodev,nosuid /var:nodev,nosuid
 /var/tmp:nodev,nosuid,noexec /var/log:nodev,nosuid,noexec /var/log/audit:nodev,nosuid,noexec"

g11_check() {
    local e mp want live fst miss_live miss_fst
    for e in $G11_MOUNTS; do
        mp=${e%%:*}; want=${e#*:}
        live=$(findmnt -no OPTIONS --mountpoint "$mp" 2>/dev/null)
        if [[ -z "$live" ]]; then
            # shellcheck disable=SC2015  # B is an item_*/ok helper that always returns 0
            [[ "$mp" == /dev/shm ]] && item_warn "/dev/shm is not mounted" || item_na "$mp: no separate partition (FP-19..25 exception)"
            continue
        fi
        fst=$(fstab_opts "$mp" < /etc/fstab) || fst=""
        miss_live=$(opts_missing "$live" "$want"); miss_fst=$(opts_missing "$fst" "$want")
        if [[ -z "$miss_live" && -n "$fst" && -z "$miss_fst" ]]; then item_ok "$mp: $want (live and fstab)"; continue; fi
        if [[ "$mp" == /dev/shm && "$want" == *noexec* && -n "$miss_live" ]] && g11_shm_exec_in_use; then
            item_block "/dev/shm has executable mappings in use (see 'grep /dev/shm /proc/*/maps'): noexec would break them"; continue
        fi
        item_fix "$mp: live '${miss_live:-ok}' fstab '${fst:+${miss_fst:-ok}}${fst:-no line}' missing - fstab + remount" g11_apply "$mp" "$want"
    done
    return 0
}

g11_shm_exec_in_use() { awk '$2 ~ /x/ && $6 ~ /^\/dev\/shm\// { f = 1 } END { exit !f }' /proc/[0-9]*/maps 2>/dev/null; }

g11_apply() {                   # MOUNTPOINT OPTS
    local mp=$1 want=$2 t
    if fstab_opts "$mp" < /etc/fstab >/dev/null; then
        t=$(fstab_add_opts "$mp" "$want" < /etc/fstab)
    elif [[ "$mp" == /dev/shm ]]; then
        t="$(cat /etc/fstab)"$'\n'"# VF G-0312 / U22-FP-03,04,17,18 (vf-harden G11)"$'\n'"tmpfs /dev/shm tmpfs defaults,$want 0 0"
    else
        err "$mp is mounted but has no fstab line: fix by hand"; return 1
    fi
    act_replace_file /etc/fstab 0644 "$t"$'\n' || return 1
    systemctl daemon-reload
    act_remount "$mp" "$want"
}
