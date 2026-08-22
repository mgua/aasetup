# ~/.psprofile.sh - the Linux counterpart of mgua/psprofile (profile.ps1).
#
# Sourced from ~/.bashrc. Mirrors the portable half of the PowerShell profile so
# the same muscle memory works on both sides: same alias names, same behaviour
# where the platform allows it.
#
# Installed by mysetup (--do psprofile). Site copy: mysetup-etc/files/psprofile.sh
# Upstream PowerShell version: https://github.com/mgua/psprofile
#
# Aliases NOT carried over, and why:
#   ex, npp/np, cyg, hed/her, wup(winget)  - Windows-only tools
#   ga/la(Get-Alias), ls/ll variants       - the real ls already does this
#   pinstall                               - that job belongs to mysetup

# ---------------------------------------------------------------------------
# Everything below the guard is interactive-only. A non-interactive shell
# (scp, rsync, ssh 'cmd', a cron job) must not get prompts, aliases or output:
# writing to stdout here corrupts an scp stream, which is a genuinely
# hard-to-diagnose failure.
# ---------------------------------------------------------------------------
case $- in *i*) ;; *) return 0 ;; esac

PSPROFILE_VERSION="1.0.0"

# --------------------------------------------------------------------------- #
#  Shell behaviour                                                            #
# --------------------------------------------------------------------------- #
shopt -s checkwinsize histappend cmdhist
shopt -s globstar 2>/dev/null
HISTSIZE=50000
HISTFILESIZE=200000
HISTCONTROL=ignoreboth:erasedups
HISTTIMEFORMAT='%F %T  '
# Append after every command instead of only at exit, so two terminals and a
# crashed one do not each discard the others' history.
PROMPT_COMMAND="history -a${PROMPT_COMMAND:+; $PROMPT_COMMAND}"

# --------------------------------------------------------------------------- #
#  Navigation and listing  (cdh, ll, la, lla)                                 #
# --------------------------------------------------------------------------- #
alias cdh='cd ~'
alias ..='cd ..'
alias ...='cd ../..'
alias ll='ls -lF --color=auto --group-directories-first'
alias la='ls -lAF --color=auto --group-directories-first'
alias lla='ls -lAhF --color=auto --group-directories-first'
alias l='ls -CF --color=auto'
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias df='df -h'
alias du='du -h'
alias free='free -h'

# --------------------------------------------------------------------------- #
#  Editor  (nv, nvim, vi, vim -> neovim when present)                         #
# --------------------------------------------------------------------------- #
if command -v nvim >/dev/null 2>&1; then
    alias nv='nvim'
    alias vi='nvim'
    alias vim='nvim'
    export EDITOR=nvim VISUAL=nvim
else
    # No nvim: leave vi/vim alone rather than aliasing them to something absent.
    export EDITOR=vim VISUAL=vim
fi

# --------------------------------------------------------------------------- #
#  git  (gst)                                                                 #
# --------------------------------------------------------------------------- #
alias gst='git status -sb'
alias gd='git diff'
alias gl='git log --oneline --graph --decorate --all'
alias gp='git pull --ff-only'

# --------------------------------------------------------------------------- #
#  Python virtual environments  (se, secd, lv)                                #
#                                                                             #
#  Convention inherited from profile.ps1: ~/venv_<project> is the environment  #
#  for the project in ~/<project>. 'se' activates, 'secd' also changes there.  #
#  These must be shell FUNCTIONS: activation edits the current shell, so a     #
#  subshell or a script could not do it.                                       #
# --------------------------------------------------------------------------- #
_psp_pick() {
    # _psp_pick "prompt" item...  -> chosen item on stdout, empty if cancelled.
    local prompt="$1"; shift
    [ "$#" -eq 0 ] && return 1
    # fzf draws on the terminal: without one it dies with "inappropriate ioctl
    # for device", so only reach for it when stdin really is a tty.
    if [ -t 0 ] && command -v fzf >/dev/null 2>&1; then
        printf '%s\n' "$@" | fzf --height=40% --reverse --prompt="$prompt> "
        return
    fi
    local i=1 choice
    for item in "$@"; do printf '  %2d) %s\n' "$i" "$item" >&2; i=$((i+1)); done
    printf '%s [1-%d, empty to cancel]: ' "$prompt" "$#" >&2
    read -r choice
    [ -z "$choice" ] && return 1
    case "$choice" in
        ''|*[!0-9]*) echo "not a number" >&2; return 1 ;;
    esac
    [ "$choice" -ge 1 ] && [ "$choice" -le "$#" ] || { echo "out of range" >&2; return 1; }
    eval "printf '%s\n' \"\${$choice}\""
}

_psp_venvs() {
    local d
    for d in "$HOME"/venv_*; do
        [ -f "$d/bin/activate" ] && basename "$d"
    done
}

se() {
    # Choose and activate a ~/venv_* environment.
    local venvs sel
    mapfile -t venvs < <(_psp_venvs)
    if [ "${#venvs[@]}" -eq 0 ]; then
        echo "no ~/venv_*/bin/activate found - create one with: python3 -m venv ~/venv_myproject"
        return 1
    fi
    sel="$(_psp_pick "virtualenv" "${venvs[@]}")" || return 1
    [ -z "$sel" ] && return 1
    # shellcheck disable=SC1090
    . "$HOME/$sel/bin/activate" && echo "activated $sel  ($(python --version 2>&1))"
}

secd() {
    # Same, then cd to the matching project folder (venv_foo -> ~/foo).
    local venvs sel proj
    mapfile -t venvs < <(_psp_venvs)
    if [ "${#venvs[@]}" -eq 0 ]; then
        echo "no ~/venv_*/bin/activate found"
        return 1
    fi
    sel="$(_psp_pick "virtualenv" "${venvs[@]}")" || return 1
    [ -z "$sel" ] && return 1
    # shellcheck disable=SC1090
    . "$HOME/$sel/bin/activate" || return 1
    proj="${sel#venv_}"
    if [ -d "$HOME/$proj" ]; then
        cd "$HOME/$proj" || return 1
        echo "activated $sel, now in ~/$proj"
    else
        echo "activated $sel  (no ~/$proj folder to change to)"
    fi
}

lv() {
    # List *venv* folders with their sizes, largest last - they are the usual
    # reason a home directory is unexpectedly full.
    #
    # The sizes are collected BEFORE sorting rather than piping the loop into
    # sort: a 'for ... done | sort' runs the loop in a subshell, so any variable
    # it sets (such as a found-anything flag) is lost when the subshell exits.
    local d dirs=()
    for d in "$HOME"/*venv*; do
        [ -d "$d" ] && dirs+=("$d")
    done
    if [ "${#dirs[@]}" -eq 0 ]; then
        echo "no *venv* folders in $HOME"
        return 0
    fi
    du -sh "${dirs[@]}" 2>/dev/null | sort -h
}

# --------------------------------------------------------------------------- #
#  fzf navigation  (fzcd, fzl, fzv)                                           #
# --------------------------------------------------------------------------- #
if command -v fzf >/dev/null 2>&1; then
    _psp_finder() { command -v fdfind >/dev/null 2>&1 && echo fdfind \
                    || { command -v fd >/dev/null 2>&1 && echo fd; }; }

    fzl() {  # pick a file, print its path
        local f; f="$(_psp_finder)"
        if [ -n "$f" ]; then "$f" --type f --hidden --exclude .git . "${1:-.}"
        else find "${1:-.}" -type f -not -path '*/.git/*' 2>/dev/null; fi \
            | fzf --height=60% --reverse --prompt='file> ' \
                  --preview 'command -v batcat >/dev/null && batcat --color=always --line-range=:200 {} || head -200 {}'
    }

    fzcd() { # pick a folder and cd into it
        local f d
        f="$(_psp_finder)"
        if [ -n "$f" ]; then d="$("$f" --type d --hidden --exclude .git . "${1:-.}" | fzf --height=60% --reverse --prompt='cd> ')"
        else d="$(find "${1:-.}" -type d -not -path '*/.git/*' 2>/dev/null | fzf --height=60% --reverse --prompt='cd> ')"; fi
        [ -n "$d" ] && cd "$d" || return 0
    }

    fzv() {  # pick a file and view it
        local sel; sel="$(fzl "$@")" || return 1
        [ -z "$sel" ] && return 0
        if command -v batcat >/dev/null 2>&1; then batcat "$sel"
        elif command -v bat >/dev/null 2>&1; then bat "$sel"
        else ${PAGER:-less -S} "$sel"; fi
    }
fi

# --------------------------------------------------------------------------- #
#  chezmoi  (cmdiff)                                                          #
# --------------------------------------------------------------------------- #
if command -v chezmoi >/dev/null 2>&1; then
    alias cm='chezmoi'
    alias cmst='chezmoi status'
    alias cma='chezmoi add'
    cmdiff() {   # diff one file against its chezmoi source, or everything
        if [ "$#" -eq 0 ]; then chezmoi diff; else chezmoi diff "$@"; fi
    }
fi

# --------------------------------------------------------------------------- #
#  System update  (wup - the apt equivalent of winget update all)             #
# --------------------------------------------------------------------------- #
wup() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "== upgradable =="
        sudo apt-get update -qq && apt list --upgradable 2>/dev/null | sed '1d'
        printf 'upgrade all of the above? [y/N] '
        local a; read -r a
        case "$a" in [yY]*) sudo apt-get -y upgrade ;; *) echo "nothing done" ;; esac
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf check-update; printf 'upgrade? [y/N] '
        local a; read -r a; case "$a" in [yY]*) sudo dnf -y upgrade ;; *) echo "nothing done" ;; esac
    else
        echo "no apt-get or dnf here"
    fi
}

# --------------------------------------------------------------------------- #
#  Oh My Posh  (oo / omp toggle)                                              #
#                                                                             #
#  The theme is slimfat2 from the psprofile repo, so both platforms show the   #
#  same prompt. Toggling off restores a plain prompt that still shows the      #
#  active virtualenv, matching Toggle-OhMyPosh in profile.ps1.                 #
# --------------------------------------------------------------------------- #
: "${PSP_OMP_BIN:=$HOME/.local/bin/oh-my-posh}"
: "${PSP_OMP_THEME:=$HOME/.config/oh-my-posh/slimfat2.omp.json}"
command -v oh-my-posh >/dev/null 2>&1 && PSP_OMP_BIN="$(command -v oh-my-posh)"

_PSP_PS1_PLAIN='\[\e[32m\]$(_psp_venv_tag)\[\e[0m\]\[\e[34m\]\w\[\e[0m\]\$ '
_PSP_PROMPT_COMMAND_PLAIN="$PROMPT_COMMAND"

_psp_venv_tag() { [ -n "$VIRTUAL_ENV" ] && printf '(%s) ' "$(basename "$VIRTUAL_ENV")"; }

_psp_omp_on() {
    [ -x "$PSP_OMP_BIN" ] || { echo "oh-my-posh not found at $PSP_OMP_BIN (mysetup --do ohmyposh)"; return 1; }
    [ -f "$PSP_OMP_THEME" ] || { echo "theme not found: $PSP_OMP_THEME"; return 1; }
    # oh-my-posh init rewrites PS1 and PROMPT_COMMAND for us.
    eval "$("$PSP_OMP_BIN" init bash --config "$PSP_OMP_THEME")"
    PSP_OMP=1
}

_psp_omp_off() {
    unset -f _omp_hook 2>/dev/null
    PROMPT_COMMAND="$_PSP_PROMPT_COMMAND_PLAIN"
    PS1="$_PSP_PS1_PLAIN"
    PSP_OMP=0
}

omp() {
    if [ "${PSP_OMP:-0}" = "1" ]; then
        _psp_omp_off; echo "Oh My Posh: OFF (plain prompt, venv still shown)"
    else
        _psp_omp_on && echo "Oh My Posh: ON (slimfat2)"
    fi
}
alias oo=omp

# Start with the fancy prompt when it is available, plain otherwise.
if [ -x "$PSP_OMP_BIN" ] && [ -f "$PSP_OMP_THEME" ] && [ -z "$PSP_NO_OMP" ]; then
    _psp_omp_on
else
    _psp_omp_off
fi

# --------------------------------------------------------------------------- #
#  Identity switching  (sid)                                                  #
#                                                                             #
#  Same convention as Select-Identity in profile.ps1: an identity <id> is the
#  pair ~/.gitconfig_<id> + ~/.ssh/config_<id>, optionally with
#  ~/.ssh/id_rsa_<id>. Copies (not symlinks) are installed, and what was there
#  is kept as .bak - matching the PowerShell behaviour, and avoiding a symlink
#  that 'mysetup --do gitconfig' would later write straight through.
# --------------------------------------------------------------------------- #
sid() {
    local ids=() f id sel
    for f in "$HOME"/.gitconfig_*; do
        [ -f "$f" ] || continue
        id="${f##*/.gitconfig_}"
        [ -f "$HOME/.ssh/config_$id" ] && ids+=("$id")
    done
    if [ "${#ids[@]}" -eq 0 ]; then
        cat <<'MSG'
No identity profiles found. An identity <id> needs BOTH of:
    ~/.gitconfig_<id>
    ~/.ssh/config_<id>
and optionally ~/.ssh/id_rsa_<id> (+ .pub), which becomes ~/.ssh/id_rsa.
MSG
        return 1
    fi
    echo "current git identity: $(git config --global user.email 2>/dev/null || echo none)"
    sel="$(_psp_pick "identity" "${ids[@]}")" || return 1
    [ -z "$sel" ] && return 1
    local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
    [ -f "$HOME/.gitconfig" ]     && cp -p "$HOME/.gitconfig"     "$HOME/.gitconfig.bak.$stamp"
    [ -f "$HOME/.ssh/config" ]    && cp -p "$HOME/.ssh/config"    "$HOME/.ssh/config.bak.$stamp"
    cp -p "$HOME/.gitconfig_$sel"  "$HOME/.gitconfig"
    cp -p "$HOME/.ssh/config_$sel" "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"
    if [ -f "$HOME/.ssh/id_rsa_$sel" ]; then
        [ -f "$HOME/.ssh/id_rsa" ] && cp -p "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_rsa.bak.$stamp"
        cp -p "$HOME/.ssh/id_rsa_$sel" "$HOME/.ssh/id_rsa"; chmod 600 "$HOME/.ssh/id_rsa"
        [ -f "$HOME/.ssh/id_rsa_$sel.pub" ] && { cp -p "$HOME/.ssh/id_rsa_$sel.pub" "$HOME/.ssh/id_rsa.pub"; chmod 644 "$HOME/.ssh/id_rsa.pub"; }
    fi
    echo "identity now: $sel  ($(git config --global user.email 2>/dev/null))"
    echo "previous files kept as *.bak.$stamp"
}

# --------------------------------------------------------------------------- #
#  Self  (pspe, psmenu)                                                       #
# --------------------------------------------------------------------------- #
alias pspe='${EDITOR:-vi} ~/.psprofile.sh && . ~/.psprofile.sh'
alias pspr='. ~/.psprofile.sh'

psmenu() {
    cat <<MENU
 psprofile ${PSPROFILE_VERSION} (linux)   -   counterpart of mgua/psprofile

  navigate    cdh  ..  ...      home, up, up twice
              ll la lla l       ls variants
              fzcd              fzf: pick a folder and cd there
              fzl / fzv         fzf: pick a file, print it / view it
  python      se                pick and activate a ~/venv_* environment
              secd              same, then cd to the project folder
              lv                *venv* folders and their sizes
  git         gst gd gl gp      status -sb, diff, log graph, pull --ff-only
  chezmoi     cm cmst cma       chezmoi, status, add
              cmdiff [FILE]     diff against the chezmoi source
  identity    sid               switch .gitconfig_<id> + .ssh/config_<id>
  prompt      oo / omp          toggle Oh My Posh (slimfat2) on and off
  system      wup               update everything, with a confirmation
  self        pspe              edit this profile and reload it
              pspr              reload it without editing
              psmenu            this list

  account setup lives in 'mysetup' - run it for keys, dotfiles and tools.
MENU
}
