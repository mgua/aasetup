#!/usr/bin/env bash
# Explain what chezmoi is for and what to do next. Changes nothing.
# Run by mysetup (--do chezmoi-next).  $1 = git host,  $2 = suggested repo name
set -u
GITHOST="${1:-git.example.com}"
REPO="${2:-${USER}_dotfiles}"
SRC="${XDG_DATA_HOME:-$HOME/.local/share}/chezmoi"

if [ -t 1 ]; then
    B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; R=$'\033[0m'
else
    B=""; D=""; G=""; Y=""; C=""; R=""
fi
# Shorten a path for display. Not the anchored-replacement form: bash re-scans
# the slashes of an expanded $HOME as the pattern delimiter and never matches.
tilde() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

h()   { printf '\n%s== %s ==%s\n' "$B" "$1" "$R"; }
say() { printf '  %s\n' "$1"; }
cmd() { printf '      %s%s%s\n' "$C" "$1" "$R"; }

h "What chezmoi is for"
say "Your account's character lives in a dozen small files - ~/.gitconfig,"
say "~/.psprofile.sh, ~/.tmux.conf, ~/.ssh/config. Rebuild the machine, or get"
say "a second one, and you rebuild all of it from memory."
say ""
say "chezmoi keeps those files in a ${B}git repository${R} and can write them back out"
say "on any machine. Restoring an account becomes one command instead of an"
say "afternoon of half-remembered edits."

h "The one idea that makes the rest obvious"
say "chezmoi does not track your home directory. It keeps a ${B}separate source${R}"
say "directory, and generates your real files from it:"
printf '\n'
say "  ${D}the source directory${R}                       ${D}your home${R}"
say "  $(tilde "$SRC")"
say "      dot_gitconfig       ${G}--- apply --->${R}      ~/.gitconfig"
say "      dot_psprofile.sh    ${G}<---- add ----${R}      ~/.psprofile.sh"
say "      dot_tmux.conf                           ~/.tmux.conf"
printf '\n'
say "'add' imports a real file into the source; 'apply' writes the source back"
say "out. A leading dot becomes ${B}dot_${R} because a repository full of hidden files"
say "is a repository nobody can read."
say ""
say "That indirection is the whole point: because a source file is not the"
say "file itself, it can be a ${B}template${R} that differs per machine, or be stored"
say "${B}encrypted${R} - neither of which a plain git repo in \$HOME could do."

h "Why not just 'git init' in \$HOME?"
say "People try it once. \$HOME also holds caches, downloads, browser profiles"
say "and private keys, so you spend forever on .gitignore, every tool you run"
say "sees a dirty repository, and one careless 'git add -A' commits an ssh key."
say "chezmoi tracks only the files you name, and nothing else exists to it."

h "The daily loop"
cmd "chezmoi add ~/.psprofile.sh      # start tracking it, as it is now"
cmd "chezmoi edit ~/.psprofile.sh     # edit the SOURCE copy in \$EDITOR"
cmd "chezmoi diff                     # what would change in \$HOME"
cmd "chezmoi apply                    # write the changes out"
say ""
say "then commit as you would any repository - 'chezmoi cd' drops you into it:"
cmd "chezmoi cd"
cmd "git add -A && git commit -m 'psprofile: add a docker alias' && git push"
cmd "exit"
say ""
say "psprofile has these as ${B}cma${R}, ${B}cmdiff${R}, ${B}cmst${R} and ${B}cm${R}."

h "The payoff, on the next machine you build"
cmd "chezmoi init --apply git@$GITHOST:$REPO"
say "Clones the repo and writes every tracked file into place, in one command."

h "One file, two machines: templates"
say "Give a source file a .tmpl suffix and it is rendered per machine:"
printf '\n'
cmd '[user]'
cmd '    email = {{ if eq .chezmoi.hostname "laptop" }}me@home{{ else }}me@work{{ end }}'
printf '\n'
say "so one repository serves boxes that genuinely need different values,"
say "instead of a branch per machine."

h "Secrets: read this before adding anything sensitive"
say "${Y}Git history is permanent.${R} A password or token committed once stays"
say "reachable in the history after you delete the file. chezmoi can encrypt"
say "individual files so only the ciphertext is ever committed:"
cmd "chezmoi add --encrypt ~/.config/some-token"
say ""
say "It needs an encryption tool configured first (age is the simple choice):"
cmd "https://www.chezmoi.io/user-guide/frequently-asked-questions/encryption/"
say ""
say "Keep caches and generated files out with a .chezmoiignore in the source"
say "directory - same idea as .gitignore, same file syntax."

h "How this sits alongside mysetup"
say "They overlap, and it is worth being deliberate about which owns a file:"
say ""
say "  ${B}mysetup${R}  writes dotfiles from mysetup-etc - the ${B}site${R} defaults, the same"
say "           for every account, and it will happily rewrite them."
say "  ${B}chezmoi${R}  tracks how ${B}your${R} account has diverged from those defaults."
say ""
say "${Y}If both manage the same file, whichever runs last wins.${R} A safe habit:"
say "let mysetup lay a file down once, then track it with chezmoi and stop"
say "re-running that mysetup task for it. mysetup's diff prompt will show you"
say "the collision before it happens either way."

h "Where you are now"
if [ -d "$SRC/.git" ]; then
    say "${G}source directory is a git repo:${R} $SRC"
    ( cd "$SRC" && git remote -v 2>/dev/null | head -2 | sed 's/^/      /' )
    say "so 'chezmoi status' and 'chezmoi diff' are the commands you want next."
elif [ -d "$SRC" ]; then
    say "${Y}$SRC exists but is not a git repo yet${R} - 'chezmoi cd' then 'git init'."
else
    say "${Y}nothing initialised yet.${R} Pick a repository and run the init above."
    say "The repo does not have to exist first: 'chezmoi init' alone starts an"
    say "empty one locally, and you can add a remote whenever you like."
fi
printf '\n'
