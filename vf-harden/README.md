# vf-harden — VF G-0312 hardening by level

`aasetup_harden.sh` (at the repo root) hardens an Ubuntu server to the **VF G-0312**
standard (CIS Ubuntu 22.04, condensed) **by risk level**. It works on a fresh box
and on one already in production. The steps and levels come from Fabio Montini's
runbook *Hardening VF G-0312 su Ubuntu 24.04 in produzione* (2026-10-14). The
exceptions come from two production Plesk servers, called **server A** (hardened by hand
from the runbook) and **server B** (built from the template script `vf-harden-ubuntu2604.sh`)
in this documentation and in the code comments.

| Level | What | When | Status |
|---|---|---|---|
| **green** | permissions, texts, settings that don't change behaviour, reports | office hours | **implemented** |
| **yellow** | changes what users/apps can do (SSH, PAM, sudo, su, network, services) | maintenance window, console open | **implemented** |
| **red** | may stop a service, needs a reboot, or is not cleanly reversible | own window, snapshot, console; **one step per run, `-R`** | **implemented** |

**First time? Read [`GUIDE.md`](GUIDE.md)**: the operator's guide (preparation, workflow, reading the output, recovery).

**Supported:** Ubuntu 24.04 and 26.04, run as root. Bash only, no dependencies.

## Why it lives here, and why it is a separate script

aasetup's rule is *root creates, the user configures*. The `aasetup*.sh` scripts
run as root and change the system; `mysetup` runs as the user and refuses root.
Hardening is a root, system-wide job, so it follows the `aasetup_recording.sh`
pattern: one root script at the top (`aasetup_harden.sh`, same logging, getopts
flags, `validate_distro`, a `main`). Because it has ~25 steps with
check/apply/rollback each, the step code lives in its own folder (`vf-harden/`)
instead of one 2000-line file. Nothing in `aasetup.sh` or `mysetup` changed.

## Usage

```bash
sudo bash aasetup_harden.sh -l green              # check (default): read-only
sudo bash aasetup_harden.sh -l green -a -n        # dry run: the exact actions, nothing changed
sudo bash aasetup_harden.sh -l green -a           # apply + verify each step
sudo bash aasetup_harden.sh -l green -a -x        # apply, but stop before ANY change (no-op test)
sudo bash aasetup_harden.sh -l green -a -o V8 -b  # V8 only, and start the AIDE baseline (off-hours)
sudo bash aasetup_harden.sh -l green -r latest    # undo the last green --apply run (UNTESTED)
vf-harden/vf-green -a -n                          # same as -l green
sudo bash aasetup_harden.sh -l yellow             # yellow check
sudo bash aasetup_harden.sh -l yellow -a -s G3    # yellow apply, PAM faillock left out
sudo bash aasetup_harden.sh -l yellow -a -o G3    # PAM faillock ALONE (console open!)
sudo bash aasetup_harden.sh -l yellow -o G3 -r latest   # undo only G3 of the last yellow run
sudo bash aasetup_harden.sh -l red                # red check (read-only, like every check)
sudo bash aasetup_harden.sh -l red -a -R -o R1    # ONE red step, risks explicitly accepted
sudo bash aasetup_harden.sh -l red -a -R -o R3 -E # R3 + lock the audit rules (after AUDIT_OBSERVE_DAYS)
```

Other options: `-R` (red: I accept red risks; always with `-o`), `-E` (R3: lock the audit
rules), `-C` (console open: lets G3 run inside a full yellow apply),
`-p auto|default|plesk` (the profile), `-o V2,V9` (only these steps),
`-s V10` (skip these), `-S DIR` (state root), `-y` (no rollback prompt), `-v` (also
list compliant and not-applicable items), `-h`.

## What green covers

Green = runbook V1 V2 V4 V5 V7 V8 V9 V10. **V3 (cron/at) and V6 (password policy)
moved to yellow** (decision 2026-10-22). They change behaviour: `cron.allow` blocked
Plesk scheduled tasks for new sites, and the password defaults and pwquality change
PAM and the accounts Plesk creates.

| Step | U22 IDs | Compliant when (checked on the EFFECTIVE state) | What --apply does if not |
|---|---|---|---|
| V1 | SFD-01..10 | passwd/group/shells ≤644 root:root; shadow/gshadow ≤640 root:shadow; opasswd ≤600 | removes excess mode bits, fixes owner |
| V2 | CB-01..06 | issue/issue.net/motd = `BANNER_TEXT`, 644 root; no executable `update-motd.d` script; `motd-news.timer` not enabled | writes the text (original backed up), `chmod -x`, disables the timer |
| V4 | APH-01..03,05,06 | randomize_va_space=2, ptrace_scope≥1, suid_dumpable=0 **running and at boot** (from any sysctl.d file); `* hard core 0`; apport.service not enabled; systemd-coredump Storage=none if installed | writes `60-vf-kernel.conf` + `sysctl -p` on it; `limits.d/60-vf-core.conf`; disables apport (never purges) |
| V5 | FKM-01..05,09,10 | each module maps to `/bin/false` in `modprobe --showconfig` (any file) | writes `modprobe.d/60-vf-fs.conf`; a LOADED module is left out (warn), nothing is unloaded |
| V7 | SL-01..06 | effective journald values (`systemd-analyze cat-config`) | writes `journald.conf.d/60-vf.conf`, restarts journald |
| V8 | IC-01..03 | aide + aide-common installed, daily timer enabled, profile excludes covered, baseline present | installs (one package per call, simulation-gated), enables the timer, writes the excludes; baseline only with `-b` (background, idle I/O) |
| V9 | SS-01,12,13 | sshd_config(.d) ≤600, host keys ≤600, `.pub` ≤644, all root | fixes modes (no reload) |
| V10 | RT-01..05, UG-03..08, SFD-11..13 | report only | nothing; with `-a` the full lists go to `<run>/V10-reports.txt` |

## What yellow covers

Run it in a maintenance window, with the **vSphere console open and logged in as
root**, and a second SSH session ready. Take a snapshot before it (runbook rule).
Steps run in this order: the ones that don't touch access first, then the access
steps, and the riskiest last:

| Step | U22 IDs | Compliant when (EFFECTIVE state) | What --apply does if not | Plesk profile |
|---|---|---|---|---|
| V3 | CC-01..08, CA-01 | crontab ≤600, cron.* dirs ≤700; allow files as `CRON_ALLOW_MODE` says | modes; cron.allow from users with crontabs | `none`: no cron.allow (new site users' tasks fail with it) |
| G5 | UD-02, UD-03, RT-08 | login.defs UMASK, a login-shell umask + readonly TMOUT, root's umask | `profile.d/50-vf-hardening.sh`, login.defs, `/root/.bashrc` | kept; warns about files created by hand in vhosts |
| G6 | UG-09, UG-10, LG-01 | no /var/log file accessible by other; people's homes ≤750, dotfiles not g/o-writable | o-rwx / go-w, old modes recorded | `/var/log/plesk`, `/var/log/sw-cp-server` excluded; vhost homes never touched |
| G7 | NKP-01..26 | safe keys, role keys (only when ip_forward=0, one NIC, no docker/br-/tun/wg), and **every NIC's own keys** at the kernel's effective value | `60-vf-net.conf`, `61-vf-net-role.conf`, `62-vf-net-nic.conf` + `sysctl -p` on them | same |
| G8 | TS-01..06 | timesyncd (24.04) / chrony (26.04) uses `NTP_SERVERS`; VMware sync off | drop-in + restart / sources file | `NTP_SERVERS` empty → N/A |
| G9 | CS-*, GD-11 | units in `MASK_UNITS` masked (never purged; purge is red) | stop + mask; a RUNNING unit is only reported | Plesk stack in `PROTECTED_UNITS` |
| G10 | NKM-01..04 | sctp, dccp, tipc, rds → /bin/false | `modprobe.d/60-vf-net.conf` | same |
| G11 | FP-01..14,17,18 | /dev/shm (and existing separate partitions) live AND in fstab with nodev,nosuid[,noexec]; never /tmp | fstab + remount | same |
| V6 | PQ-01..08, SP defaults | libpam-pwquality + cracklib dictionary, pwquality values, pam_pwquality in common-password, login.defs, useradd INACTIVE | install (with recommends), conf, PAM line, login.defs | no enforce_for_root; PAM by hand; PASS_MAX_DAYS 99999, INACTIVE -1 |
| G2 | PE-02,05,06,07 | use_pty, logfile, timestamp_timeout ≤15 in what sudo reads; a logrotate rule for sudo.log | `sudoers.d/01_vf_hardening` (visudo -cf first), `logrotate.d/vf-sudo` with `su root syslog` | same; sudoers.d modes ≠ 0440 reported only |
| G1 | SS-02..22 | `sshd -T` values; root never from outside; root by key from `ROOT_LOGIN_ALLOW_FROM` | `sshd_config.d/01-vf-hardening.conf`; a `Match User root Address ...` block appended at the END of sshd_config; `sshd -t`, reload | addresses in `profiles.local`; a missing address in an existing root Match block = WARN |
| G4 | PE-03 | `pam_wheel ... group=sugroup` in /etc/pam.d/su; the group not empty | line after pam_rootok, group, admins as members (only if empty) | same |
| G3 | PF, PH, PU | faillock preauth/authfail/account, faillock.conf, pwhistory, no nullok | **only with `-C` or `-o G3`**; pam-auth-update (auto) or hand edits with jump counts fixed (manual) | manual around `pam_plesk.so`; pwhistory `enforce_for_root` differing = WARN |

Access steps carry the extra no-harm checks below. After G1 and G3 the tool reminds
you to log in from a NEW session before closing the old one. After G3 it prints
the rollback commands, including the console fallback (`cp -a <run>/files/etc/pam.d/common-* /etc/pam.d/`).

## What red covers

Red applies only with **`-R`** ("I accept red risks") **and `-o`** naming the step(s).
It never runs a whole level at once, and never reboots. A change that takes effect at
boot ends the run with **REBOOT REQUIRED** in the summary. `--check` runs all red steps
read-only, like every other level. The order is reports first, GRUB last:

| Step | U22 IDs | Compliant when | What --apply does if not | Plesk profile |
|---|---|---|---|---|
| R6 | SFD-11, SFD-13 | report only (world-writable, SUID not from a package; each with its owning package) | **nothing, ever**; `PLESK_VHOSTS` is not even scanned | same |
| R2 | RT-04,06,07, UD-01, UG-02 | system accounts without a login shell; accounts without a valid shell locked | only the accounts named in `R2_NOLOGIN` / `R2_LOCK` (old shell recorded) | site users (group/regex) never reported for RT-07 |
| R1 | SP-01, SP-05, SP-06 | each **person**: max `PEOPLE_PASS_MAX_DAYS`, min, warn, inactive never if `PASS_INACTIVE=-1`; `EXPIRY_EXEMPT` never expires | `chage` per person; a password older than the new max gets last-change = **today** first (no instant expiry, no forced change); old fields recorded | site users (`psacln`, `^u_`, homes outside /home), service accounts and root are never touched; tomware exempt; the daily `vf-passwd-expiry-flag.timer` is checked |
| R7 | CL-* (G9b) | `REMOVE_CLIENTS` not installed | `apt-get purge`, only if apt's simulation removes **nothing beyond the list** (`R7_ALLOW_ALSO` for an accepted metapackage); BLOCKER if a command is still used in crontabs/scripts | `PROTECTED_PACKAGES` never |
| R5 | FP-15, FP-16 | fstab: /tmp tmpfs nodev,nosuid,noexec; tmp.mount not masked | fstab line + unmask tmp.mount → **REBOOT REQUIRED** | allowed, with a loud warning (server B runs it through 4 Plesk updates; server A never had it) |
| R3 | AS, AR, AF, DR | auditd running; auditd.conf = profile; rules for all keys on disk AND loaded; file modes | install, `auditd.conf` (backup) + SIGHUP, `rules.d/50-vf.rules` + generated `50-vf-privileged.rules`, `augenrules --load`. Rules locked (`-e 2`) → loading needs a reboot (reported). `-e 2` itself only with `-E` after `AUDIT_OBSERVE_DAYS` | rotate ×5, syslog, **suspend** (never single/halt on a web server) |
| R4 | BL-01,02, AA-02,03, AS-03,04 | grub.cfg: params `apparmor=1 security=apparmor` (+`audit=1 audit_backlog_limit=8192` with auditd); superuser + pbkdf2; **`--unrestricted`** entries; grub.cfg 0600 + kernel hook | `grub.d/60-vf-hardening.cfg`, `01_vf_password`, `--unrestricted` in 10_linux FIRST, `update-grub`, verify, **REBOOT REQUIRED** | same; the hash comes from `GRUB_PASSWORD_HASH_FILE` (root, 0600) or `VF_GRUB_PASSWORD_HASH` in root's environment - **never a command-line argument** (sudo.log, journal, auditd keep those) |

R4 also refuses (BLOCKER) while a reboot timer is scheduled. A half-made GRUB password
plus an unattended reboot is the one dangerous combination (server A, 2026-10-16).

## Step statuses

| Status | Meaning |
|---|---|
| `OK` | compliant, and **this tool** applied the step (it is in the ledger `owned.tsv`). E.g. G9 on server B after the tool masked rsync.service itself (2026-10-23) |
| `ADOPTED` | compliant through **somebody else's** work: by hand from the runbook (server A's `60-vf-kernel.conf`), or the template (server B's `60-vf-hardening.conf`). Never changed, never rolled back |
| `+WARN` (`OK+WARN`, `ADOPTED+WARN`) | compliant, with a remark that needs a human decision (e.g. server B G1: root refused from 127.0.0.1) |
| `WOULD-CHANGE` | not compliant; `-a` would run the listed actions |
| `APPLIED` | changed in this run, verified, no-harm check passed |
| `HELD` | would change, but needs `-C` / `-o G3` (yellow G3) |
| `BLOCKER` | a precondition failed: fix by hand; `-a` stops before this step |
| `EXCEPTION` | the profile excludes the step (`STEP_EXCEPTION[ID]`) |
| `N/A` | not applicable here (e.g. G8 without NTP servers) |
| `FAILED` | the action, verification or no-harm check failed; the step was rolled back |

**A file this tool did not create is never edited or deleted.** If one of our file
names already exists without satisfying the check, that is a BLOCKER, to fix by hand.
The exception is system files whose content *is* the control (`/etc/issue`,
`/etc/default/apport`): they are backed up first, and rollback restores them.

## Profiles

`profiles/default.conf` lists every policy variable, including the ones only
yellow/red will read (marked `[ready]`). `profiles/plesk.conf` holds the Plesk
differences and is picked automatically when `/usr/local/psa` exists.
`profiles.local/<name>.conf` (**gitignored**) holds a site's real addresses and
account names. Load order: default → profile → local default → local profile.
The files are sourced by root, so they must be root-owned and not group/other-writable.

## State dir (`-S`, default `/var/lib/vf-harden`, mode 0700)

```
owned.tsv                 ledger: kind key sha step run   (files we created, steps we applied)
latest -> runs/<id>       the last --apply run
lock                      flock held by --apply / --rollback
runs/<id>/meta            host, OS, profile (+files), level, mode, args, sudo user, tool version
runs/<id>/log             full log of the run
runs/<id>/steps.tsv       per step: OK / ADOPTED / APPLIED / FAILED / rolled-back ...
runs/<id>/manifest.tsv    one line per change, written BEFORE the change
runs/<id>/files/<path>    byte copies of every file that was modified
runs/<id>/V10-reports.txt full report lists
runs/<id>/rolled-back     present after a full rollback (.partial after a partial one)
```

`--check` writes nothing anywhere. A no-op `--apply` writes only its run record and
the lock under the state root. It writes nothing to `/etc` and nothing to the journal.

## Rollback — tested once (G9, unit mask, on server B), otherwise UNTESTED

There is no throw-away VM yet. `-r` ran once for real: yellow G9 on server B (2026-10-23).
It restored rsync.service to exactly `disabled/inactive`. Every other entry type is
untested. It is designed to
**only ever undo what a manifest line says this tool did**, and only while the target
is still exactly as this tool left it:

| Manifest entry | Undo | Guard |
|---|---|---|
| `file-created` | delete | sha256 still equals what we wrote |
| `file-modified` | restore the backup | sha256 still equals what we wrote |
| `dir-created` | `rmdir` | only if empty |
| `perm` | old mode/owner | current mode/owner still equal what we set |
| `unit` | old enable state + old active state | — |
| `sysctl` | `sysctl -w key=old` | — |
| `restart` / `reload` | once, AFTER all files are back (ssh: only if `sshd -t` passes) | — |
| `file-modified` / `file-created` by a command (pam-auth-update, useradd -D) | restore / delete | sha recorded right after the command (`file-sha`) |
| `group-created` / `group-member-added` | `groupdel` / `gpasswd -d` | group must be empty to be deleted |
| `remount` | remount with the old options (no*-flags undone explicitly), after fstab is back | — |
| `pkg-installed` | `apt-get purge` of exactly those new packages | simulation removes nothing else |
| `pkg-removed` (R7) | `apt-get install` of the same names | configs may differ from before: PARTIAL by nature |
| `chage` + `chage-after` (R1) | `chage` back to the old shadow fields | only if the fields are still what R1 set |
| `usershell` / `userlock` (R2) | `usermod -s <old>` / `usermod -U` | shell still what R2 set |
| `hup` (R3) | SIGHUP to auditd after auditd.conf is back | — |
| `regen-grub` (R4) | `update-grub` + 0600, after the GRUB files are back | — |

Not undoable by any rollback: a reboot that already happened with R4/R5 in place,
loaded audit rules while they are locked (`-e 2`: until the next reboot), and an
account locked or expired before R1's rollback.

Anything that fails a guard is kept and listed, and the rollback ends **PARTIAL**
(exit 4). The AIDE baseline database is not deleted. Package upgrades pulled in by
an install are not undone. During `--apply`, a step that fails its verification is
rolled back on its own, immediately.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | check: all compliant/adopted (warnings allowed) · apply: done and verified · rollback: complete |
| 1 | check: something WOULD-CHANGE · apply `-x`: stopped before the first change · apply: a step was HELD (G3 without `-C`/`-o G3`) |
| 2 | apply: a step failed its action, verification or no-harm check; that step was rolled back, the run stopped |
| 3 | BLOCKER: a precondition failed; apply stops before that step |
| 4 | rollback PARTIAL |
| 5 | usage/environment: not root, unsupported OS, lock held, unsafe file ownership |

## No-harm check (after every applied step)

Taken right before the first change of a run, and compared after every applied step:
no new failed systemd units; `sshd -t`, `visudo -c` and `sudo -n true` for the admin who
ran the tool (`$SUDO_USER`) still pass, if they passed before. Plus the
profile's `HEALTHCHECK_HOOK` (e.g. a site copy of `p61-check.sh` that exits non-zero
on a difference), whose output goes to `<run>/health-<step>.txt`.

## Known gaps

- red: G9's purge of SERVER packages (`REMOVE_SERVICES`) and CS-13 (postfix
  loopback-only) are not implemented. G9 masks services; R7 purges clients only.
- red has not been applied by this tool anywhere yet; its rollback is untested.
- G7 per-NIC: a running value that is right, with only `default` at boot, counts as
  compliant (that is what made it right at the last boot). A NIC that comes up before
  systemd-sysctl would still show it at runtime and be fixed then.
- G3 has not been applied by this tool anywhere yet (server B got it from the template,
  server A has none). Do the first real G3 on a snapshot, with the console open.
- V8 excludes for Plesk are reconstructed from notes. **Compare them with server A's real
  `99_vf_plesk_excludes`** (compare the two files by hand). While they differ, V8 reports a WARN and changes nothing.
- V4's sysctl check reads `/etc,/run,/usr/local/lib,/usr/lib,/lib/sysctl.d`, which is
  systemd-sysctl's view. A key that only `/etc/sysctl.conf` sets counts only through
  Ubuntu's `99-sysctl.conf` symlink.
- V10's filesystem scan takes minutes on a big web server (`-s V10` or `V10_FS_SCAN=no`).
- Live tests so far: green and yellow on server B (check, no-op apply, one real G9
  apply/rollback); the test log is kept outside the repo. `shellcheck` was not available when it was
  written: only `bash -n` and the unit tests passed.
- `tests/test_vf_harden.py` (30 tests, no root): parsers, PAM jump arithmetic,
  CIDR, fstab, sshd/sudoers parsing, R1 ageing decisions and person filter, GRUB hash
  shape, the red `-R`/`-o` gate, and all 28 steps loading with both profiles.

## The template script

This tool is the live-server counterpart of an internal template-build script. The
problems found in that script while building this tool are tracked internally (fix them
before the next template build); the profiles here already avoid them.
