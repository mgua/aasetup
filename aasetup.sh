#!/usr/bin/env bash
#
# app-account-setup.sh
# Provision an application / development account on Ubuntu 24.04+.
#
#   - validates the distribution
#   - installs system + npm packages, Neovim (tarball) and trzsz
#   - creates a user with a fixed uid/gid (+ optional passwordless sudo)
#   - generates an SSH keypair (passphrase-protected) and exports the
#     public key for git-server configuration
#   - lays down ~/.gitconfig, ~/.vimrc, ~/.tmux.conf and the Neovim config
#
# Author: mgua@tomware.it
# Target: Ubuntu 24.04 LTS or newer. Run as root (or via sudo).
#
set -euo pipefail

# --------------------------------------------------------------------------- #
#  Configuration (override via env or CLI flags)                              #
# --------------------------------------------------------------------------- #
MYUSER="${MYUSER:-tomware}"
MYUID="${MYUID:-1111}"
MYGID="${MYGID:-1111}"
USER_GECOS="${USER_GECOS:-TomWare application account}"

GIT_NAME="${GIT_NAME:-g_sviluppo}"
GIT_EMAIL="${GIT_EMAIL:-g_sviluppo@tomware.it}"

SSH_KEY_NAME="${SSH_KEY_NAME:-id_rsa_${MYUSER}}"
SSH_KEY_COMMENT="${SSH_KEY_COMMENT:-${MYUSER}@tomware.it}"
SSH_KEY_BITS="${SSH_KEY_BITS:-2048}"

# A login public key to install into the user's authorized_keys (so they can SSH
# in). This is SEPARATE from the keypair the script generates above (which is the
# user's git-client identity). Empty => skip. Usually set per-user by aasetup_all.sh.
SSH_AUTHORIZED_KEY="${SSH_AUTHORIZED_KEY:-}"

NVIM_CONFIG_REPO="${NVIM_CONFIG_REPO:-https://github.com/mgua/mg-nvim-2025.git}"
TRZSZ_VERSION="${TRZSZ_VERSION:-1.2.0}"

# Where the public key + (generated) passphrase are written for the admin.
EXPORT_DIR="${EXPORT_DIR:-/root/account-exports/${MYUSER}}"

# Phase toggles (set to 0 to skip a phase)
DO_PACKAGES="${DO_PACKAGES:-1}"
DO_USER="${DO_USER:-1}"
DO_SUDO_NOPASSWD="${DO_SUDO_NOPASSWD:-1}"
DO_SSH="${DO_SSH:-1}"
DO_AUTHKEYS="${DO_AUTHKEYS:-1}"   # install SSH_AUTHORIZED_KEY into authorized_keys
PROMPT_AUTHKEY="${PROMPT_AUTHKEY:-0}"  # 1 = if no key was supplied, prompt to paste one (interactive only)
DO_GITCONFIG="${DO_GITCONFIG:-1}"
DO_NVIM="${DO_NVIM:-1}"
DO_VIMRC="${DO_VIMRC:-1}"
DO_TMUX="${DO_TMUX:-1}"
DO_PASSWORD="${DO_PASSWORD:-1}"   # 1 = generate a random initial password + force change at first login; 0 = key-only (--disabled-password)
PASSWORD_FORCE_CHANGE="${PASSWORD_FORCE_CHANGE:-1}"  # expire the generated password so the user must reset it on first login

# runtime state (set during create_user / set_account_password)
USER_CREATED=0
ACCOUNT_PASSWORD=""

# SSH passphrase handling:
#   SSH_PASSPHRASE="..."   use this passphrase
#   SSH_NO_PASSPHRASE=1    create the key with no passphrase
#   (default)              generate a strong random passphrase + export it
FORCE_SSH=0          # -f : overwrite an existing key (DANGEROUS)
EMAIL_SET=0          # set to 1 when -e is given (so the SSH key comment follows it)

APT_PACKAGES=(curl git nodejs npm python3 python3-pip python3-venv
              xclip ripgrep fd-find fzf tmux vim dos2unix jq 7zip mc
              ca-certificates wget)
NPM_GLOBAL=(yarn neovim tree-sitter-cli basedpyright)

# --------------------------------------------------------------------------- #
#  Logging helpers                                                            #
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
${C_BOLD}app-account-setup.sh${C_RESET} - provision an application account on Ubuntu 24.04+

Usage: sudo $0 [options]

  -u USER   account name           (default: ${MYUSER})
  -U UID    numeric uid            (default: ${MYUID})
  -G GID    numeric gid            (default: ${MYGID})
  -e EMAIL  git email + SSH key comment (default: ${GIT_EMAIL})
  -n NAME   git author name        (default: ${GIT_NAME})
  -f        force-overwrite an existing SSH key
  -h        show this help

Phases can be skipped with env vars set to 0, e.g.:
  DO_PACKAGES=0 sudo -E $0 -u svc_app -U 2001 -G 2001

SSH passphrase:
  SSH_PASSPHRASE="..."   use a specific passphrase
  SSH_NO_PASSPHRASE=1    create the key without a passphrase
  (default)              generate a strong random one and export it
USAGE
}

# --------------------------------------------------------------------------- #
#  Argument parsing                                                           #
# --------------------------------------------------------------------------- #
while getopts ":u:U:G:e:n:fh" opt; do
    case "$opt" in
        u) MYUSER="$OPTARG" ;;
        U) MYUID="$OPTARG" ;;
        G) MYGID="$OPTARG" ;;
        e) GIT_EMAIL="$OPTARG"; EMAIL_SET=1 ;;
        n) GIT_NAME="$OPTARG" ;;
        f) FORCE_SSH=1 ;;
        h) usage; exit 0 ;;
        \?) die "Unknown option: -$OPTARG (use -h)" ;;
        :)  die "Option -$OPTARG requires an argument" ;;
    esac
done
# Recompute values that depend on MYUSER if it changed on the CLI.
SSH_KEY_NAME="${SSH_KEY_NAME:-id_rsa_${MYUSER}}"
[[ "$SSH_KEY_NAME" == "id_rsa_"* ]] || SSH_KEY_NAME="id_rsa_${MYUSER}"
# Key comment follows the email when -e is given, else defaults to user@tomware.it.
if [[ "$EMAIL_SET" == "1" ]]; then
    SSH_KEY_COMMENT="$GIT_EMAIL"
else
    SSH_KEY_COMMENT="${MYUSER}@tomware.it"
fi
EXPORT_DIR="/root/account-exports/${MYUSER}"

HOME_DIR="/home/${MYUSER}"
GROUP_NAME="$MYUSER"

# --------------------------------------------------------------------------- #
#  Small utilities                                                            #
# --------------------------------------------------------------------------- #
require_root() {
    [[ "${EUID}" -eq 0 ]] || die "This script must be run as root (use sudo)."
}

# Map uname -m to the asset arch strings used by the various downloads.
detect_arch() {
    case "$(uname -m)" in
        x86_64)  NVIM_ARCH="x86_64";  TRZSZ_ARCH="x86_64" ;;
        aarch64) NVIM_ARCH="arm64";   TRZSZ_ARCH="aarch64" ;;
        *) die "Unsupported CPU architecture: $(uname -m)" ;;
    esac
}

# Run a command as the target user with a login environment.
run_as_user() { sudo -u "$MYUSER" -H bash -lc "$*"; }

# Back up an existing file (preserving ownership) before we overwrite it.
backup_if_exists() {
    local f="$1"
    if [[ -e "$f" ]]; then
        local bak
        bak="${f}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$f" "$bak"
        warn "Existing $(basename "$f") backed up to $bak"
    fi
}

# Install a file from stdin into the user's home with correct owner/mode.
install_user_file() {           # $1 = dest path   $2 = mode (default 0644)
    local dest="$1" mode="${2:-0644}" tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    backup_if_exists "$dest"
    install -o "$MYUSER" -g "$GROUP_NAME" -m "$mode" "$tmp" "$dest"
    rm -f "$tmp"
    ok "Wrote ${dest} (mode ${mode})"
}

# --------------------------------------------------------------------------- #
#  Phase 1 — distribution validation                                          #
# --------------------------------------------------------------------------- #
validate_distro() {
    phase "Validating distribution"
    [[ -r /etc/os-release ]] || die "/etc/os-release not found."
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        ubuntu)
            if ! dpkg --compare-versions "${VERSION_ID:-0}" ge "24.04"; then
                die "Ubuntu 24.04 or newer required (found: ${VERSION_ID:-unknown})."
            fi
            ok "Ubuntu ${VERSION_ID} detected."
            ;;
        debian)
            # Debian's VERSION_ID is a single number ("12", "13"); on testing/sid
            # it's absent, so only enforce the floor when we actually have one.
            if [[ -n "${VERSION_ID:-}" ]] && ! dpkg --compare-versions "${VERSION_ID}" ge "12"; then
                die "Debian 12 (bookworm) or newer required (found: ${VERSION_ID})."
            fi
            ok "Debian ${VERSION_ID:-testing/sid} detected."
            ;;
        *)
            # Accept Debian/Ubuntu derivatives (Mint, Pop!_OS, …) via ID_LIKE.
            if [[ " ${ID_LIKE:-} " == *" debian "* || " ${ID_LIKE:-} " == *" ubuntu "* ]]; then
                warn "Unrecognized distro '${ID:-unknown}' but Debian-like (ID_LIKE=${ID_LIKE:-}); proceeding."
            else
                die "Only Ubuntu (>=24.04) and Debian (>=12) are supported (found: ${ID:-unknown})."
            fi
            ;;
    esac
}

# --------------------------------------------------------------------------- #
#  Phase 2 — package installation                                             #
# --------------------------------------------------------------------------- #
install_apt_packages() {
    phase "Installing APT packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    # '7zip' is the package name on Ubuntu and Debian >=12; older Debian and some
    # derivatives ship it as 'p7zip-full'. Swap if the preferred name has no
    # install candidate, so one missing name doesn't abort the whole batch.
    local i
    for i in "${!APT_PACKAGES[@]}"; do
        if [[ "${APT_PACKAGES[$i]}" == "7zip" ]] \
           && ! apt-cache policy 7zip 2>/dev/null | grep -q 'Candidate: [0-9]'; then
            warn "'7zip' unavailable here; using 'p7zip-full' instead."
            APT_PACKAGES[$i]="p7zip-full"
        fi
    done

    apt-get install -y "${APT_PACKAGES[@]}"
    ok "APT packages installed."

    # fd-find ships its binary as 'fdfind' to avoid a name clash; most Neovim
    # configs (telescope etc.) expect 'fd'. Provide a system-wide alias.
    if command -v fdfind >/dev/null && ! command -v fd >/dev/null; then
        ln -sf "$(command -v fdfind)" /usr/local/bin/fd
        ok "Symlinked fd -> fdfind."
    fi
}

install_npm_packages() {
    phase "Installing global npm packages"
    npm update -g npm
    npm install -g "${NPM_GLOBAL[@]}"
    ok "npm globals installed: ${NPM_GLOBAL[*]}"
}

install_neovim() {
    phase "Installing Neovim from upstream tarball"
    local tarball="nvim-linux-${NVIM_ARCH}.tar.gz"
    local url="https://github.com/neovim/neovim/releases/latest/download/${tarball}"
    local tmp; tmp="$(mktemp -d)"
    ( cd "$tmp" \
        && curl -fsSL -o "$tarball" "$url" \
        && tar xzf "$tarball" )
    rm -rf /opt/nvim
    mv "$tmp/nvim-linux-${NVIM_ARCH}" /opt/nvim
    ln -sf /opt/nvim/bin/nvim /usr/local/bin/nvim
    rm -rf "$tmp"
    ok "Neovim installed: $(/usr/local/bin/nvim --version | head -n1)"
}

install_trzsz() {
    phase "Installing trzsz ${TRZSZ_VERSION}"
    local deb="trzsz_${TRZSZ_VERSION}_linux_${TRZSZ_ARCH}.deb"
    local url="https://github.com/trzsz/trzsz-go/releases/download/v${TRZSZ_VERSION}/${deb}"
    local tmp; tmp="$(mktemp -d)"
    if curl -fsSL -o "$tmp/$deb" "$url"; then
        # apt install resolves dependencies; dpkg -i alone may leave them broken.
        apt-get install -y "$tmp/$deb"
        ok "trzsz installed."
    else
        warn "Could not download $deb - skipping trzsz (check version/arch)."
    fi
    rm -rf "$tmp"
}

# --------------------------------------------------------------------------- #
#  Phase 3 — user creation                                                    #
# --------------------------------------------------------------------------- #
create_user() {
    phase "Creating user ${MYUSER} (uid=${MYUID} gid=${MYGID})"

    if getent group "$MYGID" >/dev/null && \
       [[ "$(getent group "$MYGID" | cut -d: -f1)" != "$GROUP_NAME" ]]; then
        die "GID ${MYGID} is already used by group '$(getent group "$MYGID" | cut -d: -f1)'."
    fi
    if ! getent group "$GROUP_NAME" >/dev/null; then
        groupadd --gid "$MYGID" "$GROUP_NAME"
        ok "Group ${GROUP_NAME} created."
    else
        log "Group ${GROUP_NAME} already exists - skipping."
    fi

    if id "$MYUSER" >/dev/null 2>&1; then
        log "User ${MYUSER} already exists - skipping creation."
        USER_CREATED=0
    else
        if getent passwd "$MYUID" >/dev/null; then
            die "UID ${MYUID} is already in use by '$(getent passwd "$MYUID" | cut -d: -f1)'."
        fi
        # --disabled-password: adduser sets no password; set_account_password()
        #   below assigns the generated one (or leaves it key-only if DO_PASSWORD=0).
        # --gecos "...":       suppress the interactive chfn questionnaire.
        adduser --uid "$MYUID" --gid "$MYGID" \
                --shell /bin/bash --home "$HOME_DIR" \
                --disabled-password --gecos "$USER_GECOS" \
                "$MYUSER"
        ok "User ${MYUSER} created."
        USER_CREATED=1
    fi
}

# --------------------------------------------------------------------------- #
#  Phase 3b — initial account password (random 10 digits, force change)       #
# --------------------------------------------------------------------------- #
set_account_password() {
    [[ "$DO_PASSWORD" == "1" ]] || { log "Skipping account password (DO_PASSWORD=0; key-only login)."; return; }
    if [[ "$USER_CREATED" != "1" ]]; then
        log "User pre-existed - leaving its password untouched."
        return
    fi
    phase "Setting initial password for ${MYUSER} (random 10 digits)"

    # 10 random digits from /dev/urandom. 16 bytes -> >=16 digit chars, so
    # 'cut -c1-10' always yields exactly 10; cut reads all input (no SIGPIPE,
    # safe under 'set -o pipefail').
    ACCOUNT_PASSWORD="$(od -An -N16 -tu1 /dev/urandom | tr -dc '0-9' | cut -c1-10)"

    printf '%s:%s\n' "$MYUSER" "$ACCOUNT_PASSWORD" | chpasswd
    ok "Password set for ${MYUSER}."
    if [[ "$PASSWORD_FORCE_CHANGE" == "1" ]]; then
        chage -d 0 "$MYUSER"
        log "Password expired -> ${MYUSER} must change it at first login."
    fi

    # Export for the admin to hand over (separate file from the SSH credentials).
    install -d -o root -g root -m 0700 "$EXPORT_DIR"
    {
        echo "# Initial account password for ${MYUSER} - generated $(date -Is)"
        echo "# Host: $(hostname -f 2>/dev/null || hostname)"
        echo "username: ${MYUSER}"
        echo "password: ${ACCOUNT_PASSWORD}"
        if [[ "$PASSWORD_FORCE_CHANGE" == "1" ]]; then
            echo "# ^ must be changed at first login. Hand to the user, then DELETE this file."
        fi
    } > "${EXPORT_DIR}/PASSWORD.txt"
    chmod 0600 "${EXPORT_DIR}/PASSWORD.txt"
    ok "Initial password exported to ${EXPORT_DIR}/PASSWORD.txt"
}

configure_sudo() {
    [[ "$DO_SUDO_NOPASSWD" == "1" ]] || { log "Skipping sudoers (DO_SUDO_NOPASSWD=0)."; return; }
    phase "Configuring passwordless sudo for ${MYUSER}"
    local f="/etc/sudoers.d/${MYUSER}"
    # NOTE the ':ALL' - 'NOPASSWD' without it is invalid sudoers syntax.
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$MYUSER" > "$f"
    chmod 0440 "$f"
    if visudo -cf "$f" >/dev/null; then
        ok "Wrote and validated ${f}"
    else
        rm -f "$f"
        die "sudoers syntax check failed - file removed."
    fi
}

# --------------------------------------------------------------------------- #
#  Phase 4 — SSH key                                                          #
# --------------------------------------------------------------------------- #
setup_ssh() {
    phase "Preparing SSH key for ${MYUSER}"
    local ssh_dir="${HOME_DIR}/.ssh"
    local key="${ssh_dir}/${SSH_KEY_NAME}"

    install -d -o "$MYUSER" -g "$GROUP_NAME" -m 0700 "$ssh_dir"

    if [[ -f "$key" && "$FORCE_SSH" -ne 1 ]]; then
        warn "Key ${key} already exists - not overwriting (use -f to force)."
        return
    fi
    [[ "$FORCE_SSH" -eq 1 && -f "$key" ]] && rm -f "$key" "${key}.pub"

    # Resolve the passphrase.
    local passphrase generated=0
    if [[ -n "${SSH_NO_PASSPHRASE:-}" ]]; then
        passphrase=""
    elif [[ -n "${SSH_PASSPHRASE:-}" ]]; then
        passphrase="$SSH_PASSPHRASE"
    else
        passphrase="$(openssl rand -base64 24)"
        generated=1
    fi

    # Generate as the target user so ownership is correct from the start.
    # -N sets the NEW passphrase (the snippet's -P is the *old* passphrase flag).
    run_as_user "ssh-keygen -t rsa -b ${SSH_KEY_BITS} \
        -f '${key}' -C '${SSH_KEY_COMMENT}' -N '${passphrase}'"
    ok "Keypair generated: ${key}"

    # Safe export for git-server configuration (public key + passphrase).
    install -d -o root -g root -m 0700 "$EXPORT_DIR"
    install -o root -g root -m 0600 "${key}.pub" "${EXPORT_DIR}/${SSH_KEY_NAME}.pub"
    {
        echo "# Account export for ${MYUSER} - generated $(date -Is)"
        echo "# Host: $(hostname -f 2>/dev/null || hostname)"
        echo "key_file:   ${key}"
        echo "public_key: ${EXPORT_DIR}/${SSH_KEY_NAME}.pub"
        if [[ "$generated" -eq 1 ]]; then
            echo "passphrase: ${passphrase}"
            echo "# ^ randomly generated - hand it to the user, then DELETE this file."
        elif [[ -n "${SSH_NO_PASSPHRASE:-}" ]]; then
            echo "passphrase: <none>"
        else
            echo "passphrase: <supplied via SSH_PASSPHRASE - not stored>"
        fi
        echo
        echo "# --- public key (add this to the git server) ---"
        cat "${key}.pub"
    } > "${EXPORT_DIR}/CREDENTIALS.txt"
    chmod 0600 "${EXPORT_DIR}/CREDENTIALS.txt"
    ok "Public key + credentials exported to ${EXPORT_DIR}/"
}

# --------------------------------------------------------------------------- #
#  Phase 4b — login public key -> authorized_keys                             #
# --------------------------------------------------------------------------- #
install_authorized_key() {
    [[ "$DO_AUTHKEYS" == "1" ]] || { log "Skipping authorized_keys (DO_AUTHKEYS=0)."; return; }

    # No key supplied? Optionally prompt to paste one (only when interactive).
    if [[ -z "${SSH_AUTHORIZED_KEY//[[:space:]]/}" && "$PROMPT_AUTHKEY" == "1" && -t 0 ]]; then
        printf '%sPaste the SSH PUBLIC key for %s (one line; Enter to skip): %s' \
               "$C_BOLD" "$MYUSER" "$C_RESET" >&2
        read -r SSH_AUTHORIZED_KEY || true
    fi

    if [[ -z "${SSH_AUTHORIZED_KEY//[[:space:]]/}" ]]; then
        log "No login public key for ${MYUSER} - skipping authorized_keys."
        log "  (They can log in with the generated password, then add their own key.)"
        return
    fi

    # Light sanity check; install anyway so an unusual-but-valid key isn't blocked.
    case "$SSH_AUTHORIZED_KEY" in
        ssh-*|ecdsa-*|sk-ssh-*|sk-ecdsa-*) : ;;
        *) warn "${MYUSER}'s key doesn't start like an OpenSSH public key - installing as given." ;;
    esac

    phase "Installing login public key into authorized_keys for ${MYUSER}"
    local ssh_dir="${HOME_DIR}/.ssh" ak
    ak="${ssh_dir}/authorized_keys"
    install -d -o "$MYUSER" -g "$GROUP_NAME" -m 0700 "$ssh_dir"
    [[ -f "$ak" ]] || install -o "$MYUSER" -g "$GROUP_NAME" -m 0600 /dev/null "$ak"
    # Idempotent: only append if the exact key line isn't already there.
    if grep -qxF -- "$SSH_AUTHORIZED_KEY" "$ak" 2>/dev/null; then
        log "Public key already present in authorized_keys - skipping."
    else
        printf '%s\n' "$SSH_AUTHORIZED_KEY" >> "$ak"
        ok "Added login public key to ${ak}"
    fi
    chown "$MYUSER:$GROUP_NAME" "$ak"
    chmod 0600 "$ak"
}

# --------------------------------------------------------------------------- #
#  Phase 5 — ~/.gitconfig                                                     #
# --------------------------------------------------------------------------- #
setup_gitconfig() {
    phase "Writing ~/.gitconfig"
    install_user_file "${HOME_DIR}/.gitconfig" 0644 <<GITCONFIG
[user]
	name = ${GIT_NAME}
	email = ${GIT_EMAIL}

[filter "lfs"]
	clean = git-lfs clean -- %f
	smudge = git-lfs smudge -- %f
	process = git-lfs filter-process
	required = true

[core]
	editor = nvim
	# On Windows the "official" ssh can leverage the ssh auth agent.
	sshCommand = ssh -i ~/.ssh/${SSH_KEY_NAME}

[merge]
	tool = nvimdiff

[mergetool "nvimdiff"]
	layout = (LOCAL,BASE,REMOTE)/MERGED

[init]
	defaultBranch = main

[credential "https://huggingface.co"]
	provider = generic

[http]
	postBuffer = 2048M
GITCONFIG
}

# --------------------------------------------------------------------------- #
#  Phase 6 — Neovim config                                                    #
# --------------------------------------------------------------------------- #
setup_nvim() {
    phase "Setting up Neovim config"
    local cfg="${HOME_DIR}/.config/nvim"

    if [[ -d "${cfg}/.git" ]]; then
        log "Neovim config repo already present - skipping clone."
    else
        if [[ -d "$cfg" && -n "$(ls -A "$cfg" 2>/dev/null)" ]]; then
            backup_if_exists "$cfg"
            rm -rf "$cfg"
        fi
        install -d -o "$MYUSER" -g "$GROUP_NAME" -m 0755 "$(dirname "$cfg")"
        run_as_user "git clone '${NVIM_CONFIG_REPO}' '${cfg}'"
        ok "Cloned Neovim config into ${cfg}"
    fi

    # First launch to bootstrap the plugin manager / plugins, headless so it
    # works inside or outside tmux and never blocks on a UI. We try a lazy.nvim
    # sync first, then fall back to a plain headless start.
    log "Bootstrapping plugins (headless)..."
    run_as_user "nvim --headless '+Lazy! sync' +qa" >/dev/null 2>&1 \
        || run_as_user "nvim --headless +qa" >/dev/null 2>&1 \
        || warn "Headless Neovim bootstrap returned non-zero (check it once manually)."
    ok "Neovim first-run completed."
}

# --------------------------------------------------------------------------- #
#  Phase 7 — ~/.vimrc                                                         #
# --------------------------------------------------------------------------- #
setup_vimrc() {
    phase "Writing ~/.vimrc"
    # Quoted heredoc: backslash escapes (\u23ce, \033, \007) are preserved
    # verbatim for Vim to interpret.
    install_user_file "${HOME_DIR}/.vimrc" 0644 <<'VIMRC'
"mgua@tomware.it: minimal .vimrc with visual mode select and osc52 yank with SPACE-y
set number|set relativenumber|colorscheme habamax|set mouse=a
set shiftwidth=4|set tabstop=4|set autoindent|set showcmd|set timeoutlen=1500
syntax on|filetype plugin indent on
set cursorline|set nowrap!|set encoding=UTF-8|set list
set listchars=eol:\u23ce,tab:\u25b8\u2500,trail:\u00b7,nbsp:\u23b5,space:\u00b7
let mapleader = " "
function! Osc52Yank()
let l:linecount = line("'>") - line("'<") + 1
let b64 = system('base64 -w0', @")
let b64 = substitute(b64, '\n', '', 'g')
silent exe "!echo -ne '\033]52;c;" . b64 . "\007' > /dev/fd/2"
redraw!
echo l:linecount . " lines yanked → OSC52 clipboard"
endfunction
vnoremap <silent> <leader>y y:call Osc52Yank()<CR>
VIMRC
}

# --------------------------------------------------------------------------- #
#  Phase 8 — ~/.tmux.conf + TPM                                               #
# --------------------------------------------------------------------------- #
setup_tmux() {
    phase "Setting up tmux (TPM + ~/.tmux.conf)"
    local tpm_dir="${HOME_DIR}/.tmux/plugins/tpm"

    if [[ -d "${tpm_dir}/.git" ]]; then
        log "TPM already cloned - skipping."
    else
        install -d -o "$MYUSER" -g "$GROUP_NAME" -m 0755 "$(dirname "$tpm_dir")"
        run_as_user "git clone https://github.com/tmux-plugins/tpm '${tpm_dir}'"
        ok "TPM cloned."
    fi

    install_user_file "${HOME_DIR}/.tmux.conf" 0644 <<'TMUXCONF'
#.tmux.conf by mgua@tomware.it
# This must live in the home of the user that launches tmux.
# If you launch tmux as root it has to go in root's home instead.
# git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
# Tmux Plugin Manager - (must be near the top)
set -g @plugin 'tmux-plugins/tpm'
# clipboard via OSC-52 (works from Windows Terminal)
set -g set-clipboard on
set -g mouse on
set -g history-limit 50000
setw -g mode-keys vi
set -g base-index 1
setw -g pane-base-index 1
# reload config with CTRL-b r
bind r source-file ~/.tmux.conf \; display-message "Config reloaded..."
# Plugins (install with CTRL-b I, or headless via tpm/bin/install_plugins)
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'tmux-plugins/tmux-yank'
# Initialize TPM (must be the LAST line)
run '~/.tmux/plugins/tpm/tpm'
TMUXCONF

    # Headless plugin install (equivalent of pressing CTRL-b I).
    log "Installing tmux plugins (headless)..."
    run_as_user "'${tpm_dir}/bin/install_plugins'" >/dev/null 2>&1 \
        || warn "tmux plugin install returned non-zero (run CTRL-b I once if needed)."
    ok "tmux ready."
}

# --------------------------------------------------------------------------- #
#  Summary                                                                    #
# --------------------------------------------------------------------------- #
summary() {
    phase "Done"
    cat <<SUMMARY
  User .............. ${MYUSER} (uid=${MYUID}, gid=${MYGID})
  Home .............. ${HOME_DIR}
  SSH key ........... ${HOME_DIR}/.ssh/${SSH_KEY_NAME}
  Export dir ........ ${EXPORT_DIR}
                      ${SSH_KEY_NAME}.pub   <- add to the git server
                      CREDENTIALS.txt       <- SSH key passphrase (if generated)
                      PASSWORD.txt          <- initial 10-digit login password (if generated)

  Next steps:
    1. Add ${EXPORT_DIR}/${SSH_KEY_NAME}.pub to the git server (gitolite/authorized_keys).
    2. Give the SSH passphrase (CREDENTIALS.txt) + login password (PASSWORD.txt) to
       the user, then securely delete both files.
    3. Verify a first interactive login and 'nvim'/'tmux' as ${MYUSER}.
SUMMARY
}

# --------------------------------------------------------------------------- #
#  main                                                                       #
# --------------------------------------------------------------------------- #
main() {
    require_root
    detect_arch
    validate_distro

    if [[ "$DO_PACKAGES" == "1" ]]; then
        install_apt_packages
        install_npm_packages
        install_neovim
        install_trzsz
    else
        log "Skipping package installation (DO_PACKAGES=0)."
    fi

    [[ "$DO_USER" == "1" ]]      && { create_user; set_account_password; configure_sudo; } || log "Skipping user creation."
    [[ "$DO_SSH" == "1" ]]       && setup_ssh        || log "Skipping SSH setup."
    install_authorized_key
    [[ "$DO_GITCONFIG" == "1" ]] && setup_gitconfig  || log "Skipping gitconfig."
    [[ "$DO_NVIM" == "1" ]]      && setup_nvim       || log "Skipping Neovim setup."
    [[ "$DO_VIMRC" == "1" ]]     && setup_vimrc      || log "Skipping vimrc."
    [[ "$DO_TMUX" == "1" ]]      && setup_tmux       || log "Skipping tmux setup."

    summary
}

main "$@"
