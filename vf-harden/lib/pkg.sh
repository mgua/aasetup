# shellcheck shell=bash
# vf-harden/lib/pkg.sh - package installs and removals, always gated on apt's
# own simulation (lesson from .61: removing telnet/ftp also took ubuntu-standard).
#
# Installs follow the aasetup house rule "one package per apt-get call": a failure
# names itself. The single exception is a rollback purge, which must remove a
# package together with the dependencies it pulled in.

export DEBIAN_FRONTEND=noninteractive

# _apt_sim ARGS... : run `apt-get -s ARGS`, print its output, fail when apt fails.
# Read-only, so --check may use it: no lock, and no rebuild of /var/cache/apt/*.bin.
_apt_sim() {
    apt-get -s -o Debug::NoLocking=1 -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= "$@" 2>&1
}

# act_apt_install OPTS PKG... : install each package on its own, after checking that
# the simulation removes nothing. Records the NEW packages (not upgrades), so a
# rollback can purge exactly those.
act_apt_install() {
    local opts=$1 pkg sim new upg; shift
    for pkg in "$@"; do
        pkg_installed "$pkg" && { log "$pkg already installed"; continue; }
        # shellcheck disable=SC2086  # $opts is a list of apt options
        if ! sim=$(_apt_sim $opts install "$pkg"); then
            err "apt simulation for $pkg failed:"; printf '%s\n' "$sim" | tail -5 >&2; return 1
        fi
        if grep -q '^Remv ' <<<"$sim"; then
            err "installing $pkg would REMOVE packages - refused:"; grep '^Remv ' <<<"$sim" >&2; return 1
        fi
        new=$(awk '$1 == "Inst" && $3 !~ /^\[/ { print $2 }' <<<"$sim" | tr '\n' ' ')
        upg=$(awk '$1 == "Inst" && $3 ~ /^\[/ { print $2 }' <<<"$sim" | tr '\n' ' ')
        [[ -n "${upg// }" ]] && warn "installing $pkg also upgrades: $upg(not undone by rollback)"
        manifest_add pkg-installed "${new% }" || return 1
        log "apt-get install -y $opts $pkg"
        # shellcheck disable=SC2086
        apt-get install -y $opts "$pkg" || { err "$pkg failed to install"; return 1; }
        ok "installed $pkg${new:+ (new: ${new% })}"
    done
}

# apt_purge_gated PKG... : purge, but only if apt would remove nothing outside the
# list and install nothing. Used by rollback for packages this tool installed.
apt_purge_gated() {
    local sim r extra=()
    sim=$(_apt_sim purge "$@") || { err "apt simulation of purge failed"; return 1; }
    for r in $(awk '$1 == "Purg" || $1 == "Remv" { print $2 }' <<<"$sim"); do
        in_list "$r" "$@" || extra+=("$r")
    done
    if (( ${#extra[@]} )) || grep -q '^Inst ' <<<"$sim"; then
        warn "purging $* would also touch: ${extra[*]:-(installs)} - refused, packages kept"; return 1
    fi
    apt-get purge -y "$@" && ok "purged $*"
}

# purge_sim_extra PKG... : what a purge of PKGs would ALSO remove (beyond the list and
# R7_ALLOW_ALSO), one per line; "INSTALL" when it would install something. Read-only.
purge_sim_extra() {
    local sim r
    sim=$(_apt_sim purge "$@") || { echo "SIMULATION-FAILED"; return 0; }
    for r in $(awk '$1 == "Purg" || $1 == "Remv" { print $2 }' <<<"$sim"); do
        in_list "$r" "$@" ${R7_ALLOW_ALSO:-} || echo "$r"
    done
    grep -q '^Inst ' <<<"$sim" && echo INSTALL
    return 0
}

# act_apt_purge PKG... : purge after re-checking the simulation; records name=version
# of everything removed, so rollback can reinstall it (configs may differ: PARTIAL).
act_apt_purge() {
    local extra rm
    extra=$(purge_sim_extra "$@")
    [[ -z "$extra" ]] || { err "purging $* would also remove: $(tr '\n' ' ' <<<"$extra")- refused"; return 1; }
    rm=$(_apt_sim purge "$@" | awk '$1 == "Purg" || $1 == "Remv" { v = $3; gsub(/[][]/, "", v); printf "%s=%s ", $2, v }')
    manifest_add pkg-removed "${rm% }" || return 1
    apt-get purge -y "$@" && ok "purged: ${rm% }"
}
