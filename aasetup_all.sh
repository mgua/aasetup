#!/usr/bin/env bash
#
# aasetup_all.sh — batch-provision accounts from users.json via aasetup.sh.
#
# SELECTION (which users get touched):
#   * Pass usernames on the command line to restrict the run to just those:
#         sudo bash aasetup_all.sh kstefan tomware
#     With no names, every enabled user in the JSON is processed.
#   * JSON field  enabled=false  skips a user entirely.
#
# WHAT HAPPENS PER USER:
#   * Account does NOT exist  -> full provision: create + 10-digit password + setup.
#   * Account ALREADY EXISTS  -> controlled by the JSON field  on_exists:
#         "skip"  (default) -> leave it completely alone (no setup, no password).
#         "setup"           -> do NOT recreate or set a password, but DO run the
#                              environment setup (ssh key, authorized_keys,
#                              gitconfig, nvim, vimrc, tmux). For accounts that
#                              exist but were never configured.
#
# System packages are installed only once (first user that runs any phase).
# One user's failure does not abort the batch; a summary is printed at the end.
#
# Usage:
#   sudo bash aasetup_all.sh [-j users.json] [user ...]
#     -j FILE   roster JSON (default: ./users.json)
#     user ...  restrict to these usernames (default: all enabled users)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON="$HERE/users.json"
SCRIPT="$HERE/aasetup.sh"

usage() {
    cat <<HELPDOC
aasetup_all.sh - batch-provision accounts from a JSON roster via aasetup.sh

USAGE
  sudo bash $0 [-j users.json] [user ...]

OPTIONS
  -j FILE    roster JSON file            (default: ${JSON})
  -p         if a user has no public_key, prompt to paste one (interactive)
  -h         show this help and exit

ARGUMENTS
  user ...   restrict the run to these usernames. With none, every enabled
             user in the roster is processed.
               sudo bash $0                     # all enabled users
               sudo bash $0 kstefan tomware     # only these two
               sudo bash $0 -j /path/roster.json kstefan

PER-USER JSON FIELDS (in the roster file)
  user            account name                       (-> -u)
  uid, gid        numeric ids                        (-> -U / -G)
  gecos           full name / description            (-> USER_GECOS)
  git_name        git author name                    (-> -n)
  git_email       git email + SSH key comment        (-> -e)
  sudo_nopasswd   true/false: passwordless sudo       (-> DO_SUDO_NOPASSWD)
  public_key      login key for ~/.ssh/authorized_keys ("" to skip; with -p you
                  are prompted to paste it; if still none, the user logs in with
                  the generated password and adds their own key later)
  enabled         false => skip this user entirely     (default: true)
  on_exists       what to do if the account EXISTS     (default: "skip")
                    skip   -> leave it untouched (no setup, no password)
                    setup  -> configure environment only (ssh key, authorized_keys,
                              gitconfig, nvim, vimrc, tmux); no create, no password
  (entries whose name starts with TEMPLATE are ignored)

WHAT HAPPENS PER USER
  * new account            -> create + random 10-digit password (forced change at
                              first login, exported to /root/account-exports/<user>/
                              PASSWORD.txt) + full environment setup
  * existing, on_exists=skip  -> skipped, nothing touched
  * existing, on_exists=setup -> environment setup only (no create, no password)
  System packages are installed once (first user that runs a phase). One user's
  failure does not abort the batch; a per-category summary is printed at the end.

REQUIREMENTS
  run as root; aasetup.sh must sit next to this script. 'jq' is auto-installed
  if missing (apt-get/dnf/yum).
HELPDOC
}

PROMPT_AUTHKEY=0
while getopts ":j:ph" opt; do
    case "$opt" in
        j) JSON="$OPTARG" ;;
        p) PROMPT_AUTHKEY=1 ;;
        h) usage; exit 0 ;;
        \?) echo "Unknown option -$OPTARG (use -h)" >&2; exit 1 ;;
        :)  echo "Option -$OPTARG needs an argument" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))
declare -a ONLY=("$@")            # optional username filter (empty => all)

[[ "${EUID}" -eq 0 ]]    || { echo "ERROR: run as root (sudo bash $0)." >&2; exit 1; }

# jq is required to read the roster. We are root here, so install it if missing
# (fully automated, no manual 'apt install -y jq' step). Honour DO_PACKAGES=0
# only as a way to refuse network access; otherwise just do it.
ensure_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    if command -v apt-get >/dev/null 2>&1; then
        echo "==> jq not found; installing via apt-get ..."
        DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y jq >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        echo "==> jq not found; installing via dnf ..."
        dnf install -y jq >/dev/null
    elif command -v yum >/dev/null 2>&1; then
        echo "==> jq not found; installing via yum ..."
        yum install -y jq >/dev/null
    fi
    command -v jq >/dev/null 2>&1
}
ensure_jq || { echo "ERROR: jq is required but could not be installed automatically (apt install -y jq)." >&2; exit 1; }

[[ -r "$JSON" ]]         || { echo "ERROR: cannot read $JSON" >&2; exit 1; }
[[ -r "$SCRIPT" ]]       || { echo "ERROR: cannot read $SCRIPT" >&2; exit 1; }

# True if $1 is in the CLI filter (or if no filter was given).
in_only() {
    [[ "${#ONLY[@]}" -eq 0 ]] && return 0
    local u; for u in "${ONLY[@]}"; do [[ "$u" == "$1" ]] && return 0; done
    return 1
}

pkgs_done=0
declare -a PROVISIONED=() SETUP_ONLY=() SK_EXISTS=() SK_DISABLED=() SK_FILTER=() FAILED=()

# Each user object as one compact line; ignore TEMPLATE_* placeholders.
mapfile -t ROWS < <(jq -c '.users[] | select(.user | startswith("TEMPLATE") | not)' "$JSON")
[[ "${#ROWS[@]}" -gt 0 ]] || { echo "No users to process in $JSON."; exit 0; }

for row in "${ROWS[@]}"; do
    user=$(jq -r '.user'                     <<<"$row")
    uid=$(jq -r '.uid'                       <<<"$row")
    gid=$(jq -r '.gid'                       <<<"$row")
    gecos=$(jq -r '.gecos         // ""'     <<<"$row")
    gname=$(jq -r '.git_name      // ""'     <<<"$row")
    gemail=$(jq -r '.git_email    // ""'     <<<"$row")
    nopw=$(jq -r '.sudo_nopasswd  // false'  <<<"$row")
    pubkey=$(jq -r '.public_key   // ""'     <<<"$row")
    enabled=$(jq -r '.enabled     // true'   <<<"$row")
    on_exists=$(jq -r '.on_exists // "skip"' <<<"$row")

    # --- selection ----------------------------------------------------------
    if ! in_only "$user"; then SK_FILTER+=("$user"); continue; fi
    if [[ "$enabled" != "true" ]]; then
        echo "==> SKIP  $user  (enabled=false in JSON)"; SK_DISABLED+=("$user"); continue
    fi

    do_packages=$([[ "$pkgs_done" -eq 0 ]] && echo 1 || echo 0)
    do_sudo=$([[ "$nopw" == "true" ]] && echo 1 || echo 0)

    if id "$user" >/dev/null 2>&1; then
        # --- account already exists ----------------------------------------
        if [[ "$on_exists" != "setup" ]]; then
            echo "==> SKIP  $user  (exists; on_exists=skip)"; SK_EXISTS+=("$user"); continue
        fi
        echo "==> SETUP-ONLY  $user  (exists; configuring environment, no create/password)"
        # DO_USER=0 skips create_user + password + sudoers; DO_PASSWORD=0 is belt-and-braces.
        if DO_PACKAGES="$do_packages" DO_USER=0 DO_PASSWORD=0 SSH_AUTHORIZED_KEY="$pubkey" \
           PROMPT_AUTHKEY="$PROMPT_AUTHKEY" \
            bash "$SCRIPT" -u "$user" -U "$uid" -G "$gid" -e "$gemail" -n "$gname"; then
            SETUP_ONLY+=("$user"); pkgs_done=1
        else
            echo "!! FAILED  $user (exit $?) - continuing" >&2; FAILED+=("$user")
        fi
    else
        # --- new account: full provision -----------------------------------
        echo "==> PROVISION  $user  (uid=$uid gid=$gid <$gemail>)"
        if DO_PACKAGES="$do_packages" DO_SUDO_NOPASSWD="$do_sudo" USER_GECOS="$gecos" \
           SSH_AUTHORIZED_KEY="$pubkey" PROMPT_AUTHKEY="$PROMPT_AUTHKEY" \
            bash "$SCRIPT" -u "$user" -U "$uid" -G "$gid" -e "$gemail" -n "$gname"; then
            PROVISIONED+=("$user"); pkgs_done=1
        else
            echo "!! FAILED  $user (exit $?) - continuing" >&2; FAILED+=("$user")
        fi
    fi
done

echo
echo "===== batch summary ====="
echo "  provisioned   (${#PROVISIONED[@]}): ${PROVISIONED[*]:-none}"
echo "  setup-only    (${#SETUP_ONLY[@]}): ${SETUP_ONLY[*]:-none}"
echo "  skip (exists) (${#SK_EXISTS[@]}): ${SK_EXISTS[*]:-none}"
echo "  skip (disabled)(${#SK_DISABLED[@]}): ${SK_DISABLED[*]:-none}"
[[ "${#ONLY[@]}" -gt 0 ]] && echo "  skip (filtered)(${#SK_FILTER[@]}): ${SK_FILTER[*]:-none}"
echo "  failed        (${#FAILED[@]}): ${FAILED[*]:-none}"
[[ "${#FAILED[@]}" -eq 0 ]]   # non-zero exit if anything failed
