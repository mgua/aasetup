"""Tests for aasetup_harden.sh / vf-harden (bash), in the house unittest style.

They need no root and change nothing on the machine: the parsers in
vf-harden/lib/parse.sh are pure functions, exercised here on fixture files in a
temporary directory. Run:  python3 -m unittest tests/test_vf_harden.py
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
VF = ROOT / 'vf-harden'
BASH_FILES = [ROOT / 'aasetup_harden.sh', VF / 'vf-green', VF / 'vf-yellow', VF / 'vf-red',
              *sorted((VF / 'lib').glob('*.sh')), *sorted((VF / 'steps').glob('*.sh')),
              *sorted((VF / 'profiles').glob('*.conf'))]


def bash(script: str, env: dict | None = None) -> subprocess.CompletedProcess:
    """Run a snippet with the pure libraries loaded (common, parse, net, pam)."""
    prelude = ''.join(f'. "{VF}/lib/{n}.sh"; ' for n in ('common', 'parse', 'net', 'pam', 'accounts')) + '\n'
    return subprocess.run(['bash', '-c', prelude + script], capture_output=True, text=True,
                          env={'PATH': '/usr/bin:/bin', **(env or {})})


class Syntax(unittest.TestCase):
    def test_every_file_parses(self):
        for f in BASH_FILES:
            with self.subTest(file=f.name):
                r = subprocess.run(['bash', '-n', str(f)], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)

    def test_step_contract(self):
        for f in sorted((VF / 'steps').glob('*.sh')):
            sid = re.match(r'([VGR])0?(\d+)-', f.name)
            self.assertIsNotNone(sid, f.name)
            prefix = f'{sid.group(1).lower()}{sid.group(2)}'
            text = f.read_text()
            with self.subTest(step=f.name):
                self.assertIn(f'{prefix}_meta()', text)
                self.assertIn(f'{prefix}_check()', text)

    def test_profiles_only_override_known_keys(self):
        key = re.compile(r'^([A-Z][A-Z0-9_]*)=', re.M)
        known = set(key.findall((VF / 'profiles' / 'default.conf').read_text()))
        for f in (VF / 'profiles').glob('*.conf'):
            with self.subTest(profile=f.name):
                self.assertLessEqual(set(key.findall(f.read_text())), known)


class Parsers(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.d = Path(self.tmp.name)

    def test_mode_excess(self):
        r = bash('mode_excess 644 644; echo; mode_excess 664 644; echo; mode_excess 4755 755')
        self.assertEqual(r.stdout.split(), ['0', '20', '4000'])

    def test_sysctl_last_file_wins_and_etc_masks_lib(self):
        etc, lib = self.d / 'etc', self.d / 'lib'
        etc.mkdir(); lib.mkdir()
        (lib / '10-ptrace.conf').write_text('kernel.yama.ptrace_scope = 1\n')
        (lib / '60-vf-hardening.conf').write_text('fs.suid_dumpable = 2\n')
        (etc / '60-vf-hardening.conf').write_text('fs.suid_dumpable = 0\n')   # masks lib's
        (etc / '60-vf-kernel.conf').write_text('# c\nkernel/yama/ptrace_scope=3\n')
        r = bash('sysctl_persisted kernel.yama.ptrace_scope; sysctl_persisted fs.suid_dumpable;'
                 'sysctl_persisted net.none || echo none', {'SYSCTL_DIRS': f'{etc} {lib}'})
        self.assertEqual(r.stdout.splitlines(), [f'3\t{etc}/60-vf-kernel.conf',
                                                 f'0\t{etc}/60-vf-hardening.conf', 'none'])

    def test_ptrace_scope_may_be_stricter(self):
        r = bash('sysctl_value_ok kernel.yama.ptrace_scope 2 1 && echo y;'
                 'sysctl_value_ok fs.suid_dumpable 1 0 || echo n')
        self.assertEqual(r.stdout.split(), ['y', 'n'])

    def test_ini_last_follows_sections_and_order(self):
        text = '[Journal]\n#Storage=auto\nStorage=auto\n[Other]\nStorage=volatile\n[Journal]\nStorage=persistent \n'
        r = bash('ini_last Journal Storage <<<"$T"; ini_last Journal Compress <<<"$T" || echo unset',
                 {'T': text})
        self.assertEqual(r.stdout.splitlines(), ['persistent', 'unset'])

    def test_modules_normalise_dash_and_underscore(self):
        cfg = 'blacklist usb_storage\ninstall usb_storage /bin/false\ninstall hfs /sbin/modprobe --ignore-install hfs\n'
        r = bash('mod_is_disabled usb-storage "$C" && echo y; mod_is_disabled hfs "$C" || echo n;'
                 'mod_is_disabled cramfs "$C" || echo n', {'C': cfg})
        self.assertEqual(r.stdout.split(), ['y', 'n', 'n'])

    def test_aide_rules_cover_subpaths_only(self):
        f = self.d / '99_vf_plesk_excludes'
        f.write_text('# x\n!/var/www\n! ^/var/lib/psa(/|$)\n!/var/log/.*\n/etc p+i\n')
        r = bash(f'R=$(aide_negative_rules "{f}"); printf "%s\\n" "$R";'
                 'for p in /var/www/vhosts /var/lib/psa /var/lib/psax /var/log /etc; do '
                 'aide_excluded "$p" "$R" && echo "$p y" || echo "$p n"; done')
        self.assertEqual(r.stdout.splitlines(), ['/var/www', '/var/lib/psa', '/var/log',
                                                 '/var/www/vhosts y', '/var/lib/psa y',
                                                 '/var/lib/psax n', '/var/log y', '/etc n'])


UBUNTU_AUTH_PLESK = """# here are the per-package modules (the "Primary" block)
auth\t[success=2 default=ignore]\tpam_unix.so nullok try_first_pass
auth\t[success=1 default=ignore]\tpam_plesk.so try_first_pass
# here's the fallback if no module succeeds
auth\trequisite\t\t\tpam_deny.so
auth\trequired\t\t\tpam_permit.so
auth\toptional\t\t\tpam_cap.so
"""

PLESK_PASSWORD = """password\trequisite\t\t\tpam_pwquality.so retry=3
password optional pam_plesk.so try_first_pass
password [success=1 default=ignore] pam_unix.so obscure use_authtok yescrypt try_first_pass
password\trequisite\t\t\tpam_deny.so
password\trequired\t\t\tpam_permit.so
"""


class Pam(unittest.TestCase):
    def run_pam(self, script, text):
        r = bash(script, {'T': text})
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def test_faillock_insertion_fixes_jumps_like_pam_auth_update(self):
        out = self.run_pam(
            'pam_insert_before auth . "auth requisite pam_faillock.so preauth" <<<"$T" |'
            ' pam_insert_before auth "pam_deny[.]so" "auth [default=die] pam_faillock.so authfail" |'
            ' pam_strip_arg "pam_unix[.]so" nullok', UBUNTU_AUTH_PLESK)
        rules = [l for l in out.splitlines() if l and not l.startswith('#')]
        self.assertEqual(rules[0], 'auth requisite pam_faillock.so preauth')
        self.assertIn('[success=3 default=ignore]', rules[1])      # unix skips plesk, authfail, deny
        self.assertNotIn('nullok', rules[1])
        self.assertIn('[success=2 default=ignore]', rules[2])      # plesk skips authfail, deny
        self.assertEqual(rules[3], 'auth [default=die] pam_faillock.so authfail')
        self.assertIn('pam_deny.so', rules[4])
        self.assertEqual(out.count('#'), 2)                        # comments kept

    def test_pwhistory_goes_before_pam_unix_and_plesk_lines_stay(self):
        out = self.run_pam('pam_insert_before password "pam_unix[.]so" "password requisite pam_pwhistory.so remember=24 use_authtok" <<<"$T"',
                           PLESK_PASSWORD)
        mods = [next(w for w in l.split() if w.startswith('pam_')) for l in out.splitlines() if l.strip()]
        self.assertEqual(mods, ['pam_pwquality.so', 'pam_plesk.so', 'pam_pwhistory.so', 'pam_unix.so', 'pam_deny.so', 'pam_permit.so'])
        self.assertIn('[success=1 default=ignore] pam_unix.so', out)  # its own jump is unchanged

    def test_insert_fails_without_anchor(self):
        r = bash('pam_insert_before account "pam_nothing" "x" <<<"$T"', {'T': PLESK_PASSWORD})
        self.assertNotEqual(r.returncode, 0)

    def test_has_args_and_flags(self):
        out = self.run_pam('pam_has password pam_pwquality <<<"$T" && echo q;'
                           'pam_has password pam_unix use_authtok <<<"$T" && echo u;'
                           'pam_has auth pam_unix <<<"$T" || echo no-auth;'
                           'pam_module_args password pam_unix <<<"$T"', PLESK_PASSWORD)
        self.assertEqual(out.split('\n')[:3], ['q', 'u', 'no-auth'])
        self.assertIn('use_authtok yescrypt', out)

    def test_kv_conf_flags_and_values(self):
        out = self.run_pam('kv_conf_last minlen <<<"$T"; kv_conf_last enforce_for_root <<<"$T" || echo absent;'
                           'kv_conf_last even_deny_root <<<"$T"',
                           'minlen = 8\n# enforce_for_root\nminlen=14 # vf\neven_deny_root\n')
        self.assertEqual(out.split(), ['14', 'absent', 'yes'])

    def test_add_arg_once(self):
        out = self.run_pam('pam_add_arg password "pam_unix[.]so" use_authtok <<<"$T"',
                           'password [success=1 default=ignore] pam_unix.so obscure yescrypt\n')
        self.assertEqual(out.strip(), 'password [success=1 default=ignore] pam_unix.so use_authtok obscure yescrypt')
        again = self.run_pam('pam_add_arg password "pam_unix[.]so" use_authtok <<<"$T"', out)
        self.assertEqual(again.strip(), out.strip())


class NetFstabSshSudo(unittest.TestCase):
    def test_cidr(self):
        r = bash('for a in 10.20.4.65 10.21.0.1 127.0.0.1 10.0.0.1; do ip_in_any $a "10.20.0.0/16 127.0.0.1" && echo y || echo n; done;'
                 'cidr_test_host 10.20.0.0/16; cidr_test_host 127.0.0.1; cidr_test_host bad || echo bad')
        self.assertEqual(r.stdout.split(), ['y', 'n', 'y', 'n', '10.20.0.1', '127.0.0.1', 'bad'])

    def test_fstab_add_only_missing(self):
        fstab = 'UUID=x / ext4 defaults 0 1\ntmpfs /dev/shm tmpfs defaults,nosuid 0 0\n#tmpfs /tmp tmpfs x 0 0\n'
        r = bash('fstab_opts /dev/shm <<<"$T"; fstab_opts /tmp <<<"$T" || echo none;'
                 'fstab_add_opts /dev/shm nodev,nosuid,noexec <<<"$T" | grep shm; opts_missing rw,nosuid,nodev nodev,nosuid,noexec',
                 {'T': fstab})
        self.assertEqual(r.stdout.splitlines(), ['defaults,nosuid', 'none',
                                                 'tmpfs /dev/shm tmpfs defaults,nosuid,nodev,noexec 0 0', 'noexec'])

    def test_sshd_rules(self):
        t = 'maxauthtries 4\npermitrootlogin no\nciphers chacha20-poly1305@openssh.com,aes256-ctr\nloglevel VERBOSE\nmaxstartups 10:30:60\n'
        r = bash('sshd_rule_ok maxauthtries le 4 <<<"$T" && echo a; sshd_rule_ok maxauthtries le 3 <<<"$T" || echo b;'
                 'sshd_rule_ok ciphers excl 3des-cbc,aes256-cbc <<<"$T" && echo c; sshd_rule_ok ciphers excl aes256-ctr <<<"$T" || echo d;'
                 'sshd_rule_ok loglevel eq verbose <<<"$T" && echo e; sshd_rule_ok maxstartups eq 10:30:60 <<<"$T" && echo f',
                 {'T': t})
        self.assertEqual(r.stdout.split(), list('abcdef'))

    def test_sudo_defaults_last_wins(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup); d = Path(tmp.name)
        (d / 'sudoers').write_text('Defaults\tenv_reset\nDefaults\tuse_pty\n')
        (d / '01_vf').write_text('Defaults use_pty\nDefaults logfile="/var/log/sudo.log", timestamp_timeout=15\n')
        (d / 'later').write_text('Defaults !use_pty\n')
        r = bash(f'D=$(sudo_defaults {d}/sudoers {d}/01_vf); sudo_default_last use_pty <<<"$D"; sudo_default_last logfile <<<"$D";'
                 f'sudo_default_last timestamp_timeout <<<"$D"; D=$(sudo_defaults {d}/sudoers {d}/01_vf {d}/later); sudo_default_last use_pty <<<"$D"')
        self.assertEqual(r.stdout.split(), ['on', '/var/log/sudo.log', '15', 'off'])


class Smoke(unittest.TestCase):
    """The entrypoint and every step load; nothing here needs root or changes anything."""

    def test_help_and_root_refusal(self):
        h = subprocess.run(['bash', str(ROOT / 'aasetup_harden.sh'), '-h'], capture_output=True, text=True)
        self.assertEqual(h.returncode, 0, h.stderr)
        self.assertIn('green | yellow | red', h.stdout)
        if os.geteuid() != 0:
            r = subprocess.run(['bash', str(ROOT / 'aasetup_harden.sh'), '-l', 'yellow'], capture_output=True, text=True)
            self.assertEqual(r.returncode, 5)
            self.assertIn('must be run as root', r.stderr)

    def test_every_step_loads_with_each_profile(self):
        for profile in ('default', 'plesk'):
            with self.subTest(profile=profile):
                libs = ' '.join(f'. "{VF}/lib/{n}.sh";' for n in
                                ('common', 'parse', 'net', 'pam', 'accounts', 'state', 'actions', 'sysctl', 'rollback', 'pkg', 'main', 'modes'))
                script = (f'VF_DIR="{VF}"; MODE=check; LEVEL=x; {libs}'
                          f' . "{VF}/profiles/default.conf"; . "{VF}/profiles/{profile}.conf";'
                          ' LEVEL_STEPS=(V1 V2 V3 V4 V5 V6 V7 V8 V9 V10 G1 G2 G3 G4 G5 G6 G7 G8 G9 G10 G11 R1 R2 R3 R4 R5 R6 R7); load_steps;'
                          ' for s in "${LEVEL_STEPS[@]}"; do "${s,,}_meta"; declare -F "${s,,}_check" >/dev/null || echo "NO CHECK $s";'
                          ' echo "$s|$STEP_TITLE|$STEP_IDS"; done')
                r = subprocess.run(['bash', '-uc', script], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertNotIn('NO CHECK', r.stdout)
                self.assertEqual(len(r.stdout.splitlines()), 28, r.stdout)


class Red(unittest.TestCase):
    def ev(self, *a):
        r = bash('r1_eval ' + ' '.join(f'"{x}"' for x in a))
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.strip()

    def test_r1_person_already_compliant(self):            # .71: 90 days, inactive never
        self.assertEqual(self.ev(20380, 20370, 1, 90, 7, '', 90, 1, 7, -1, 'no'), 'ok')

    def test_r1_old_password_gets_today_first(self):       # .61: 880 days old, max 99999
        self.assertEqual(self.ev(20380, 19500, 0, 99999, 7, '', 90, 1, 7, -1, 'no'), 'fix reset')

    def test_r1_recent_password_no_reset(self):
        self.assertEqual(self.ev(20380, 20370, 0, 99999, 7, '', 90, 1, 7, -1, 'no'), 'fix')

    def test_r1_inactive_must_be_never_when_profile_says_minus_one(self):
        self.assertEqual(self.ev(20380, 20370, 1, 90, 7, 45, 90, 1, 7, -1, 'no'), 'fix')
        self.assertEqual(self.ev(20380, 20370, 1, 90, 7, 30, 90, 1, 7, 45, 'no'), 'ok')

    def test_r1_exempt_never_expires(self):                # tomware
        self.assertEqual(self.ev(20380, 19500, 0, 99999, 7, '', 90, 1, 7, -1, 'yes'), 'ok')
        self.assertEqual(self.ev(20380, 19500, 0, 90, 7, '', 90, 1, 7, -1, 'yes'), 'fix')

    def test_r1_forced_change_is_not_reset(self):          # lastchg 0 = must change at next login
        self.assertEqual(self.ev(20380, 0, 0, 99999, 7, '', 90, 1, 7, -1, 'no'), 'fix')

    def test_people_filters_site_users_and_services(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup); d = Path(tmp.name)
        (d / 'shadow').write_text('root:$y$a:20000::::::\naalbano:$y$b:20000:1:90:7:::\nu_site:$y$c:19000::::::\n'
                                  'svc:$y$d:19000::::::\nnohash:!:19000::::::\nweb:$y$e:19000::::::\n')
        (d / 'passwd').write_text('root:x:0:0::/root:/bin/bash\naalbano:x:1001:1001::/home/aalbano:/bin/bash\n'
                                  'u_site:x:10001:1003::/var/www/vhosts/site:/bin/bash\nsvc:x:998:998::/home/svc:/bin/bash\n'
                                  'nohash:x:1002:1002::/home/nohash:/bin/bash\nweb:x:1005:1005::/home/web:/usr/sbin/nologin\n')
        r = bash('people_auto', {'SHADOW_FILE': str(d / 'shadow'), 'PASSWD_FILE': str(d / 'passwd'),
                                 'HOME_SCOPE': '/home', 'SITE_USER_GROUP': '', 'SITE_USER_REGEX': '^u_', 'R1_EXCLUDE': ''})
        self.assertEqual(r.stdout.split(), ['aalbano'], r.stderr)

    def test_grub_hash_shape(self):
        good = 'grub.pbkdf2.sha512.600000.' + 'A1' * 32 + '.' + 'B2' * 32
        r = bash(f'grub_hash_ok "{good}" && echo y; grub_hash_ok "secret" || echo n; grub_hash_ok "" || echo n')
        self.assertEqual(r.stdout.split(), ['y', 'n', 'n'])

    def test_red_apply_needs_R_and_o(self):
        h = ROOT / 'aasetup_harden.sh'
        for args, msg in ((['-l', 'red', '-a'], 'needs -R'), (['-l', 'red', '-a', '-R'], 'one step at a time'),
                          (['-l', 'red', '-a', '-R', '-o', 'R1', '-E'], '-E only together with -o R3')):
            with self.subTest(args=args):
                r = subprocess.run(['bash', str(h), *args], capture_output=True, text=True)
                self.assertEqual(r.returncode, 5)
                self.assertIn(msg, r.stderr)


if __name__ == '__main__':
    unittest.main()
