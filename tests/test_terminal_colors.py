"""Run with python3 -m unittest discover -s tests."""
import contextlib
import io
import os
from pathlib import Path
import pty
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
MODULE = runpy.run_path(str(ROOT / 'mysetup'), run_name='test_mysetup')


class TerminalColors(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.env = patch.dict(os.environ, HOME=self.temp.name, TERM='xterm-256color')
        self.env.start()
        self.addCleanup(self.env.stop)
        args = MODULE['build_parser']().parse_args(['--etc', str(ROOT / 'mysetup-etc')])
        self.app = MODULE['MySetup'](args)
        self.task = self.app.tasks['terminal-colors']
        self.rc = Path(self.temp.name) / '.bashrc'
        self.rc.write_text('# Keep this\nexport TEST_SETTING=yes\n')
        self.rc.chmod(0o600)
        self.output = contextlib.redirect_stdout(io.StringIO())
        self.output.__enter__()
        self.addCleanup(self.output.__exit__, None, None, None)

    def test_direct_menu_and_immediate_application(self):
        self.assertEqual(len(self.app.visible()), 17)
        with patch.object(self.app, 'print_table'), patch.object(
                self.app, 'confirm', side_effect=AssertionError('unexpected confirmation')):
            with patch('builtins.input', return_value='17'):
                self.assertEqual(self.app.menu(), [self.task])
        with patch('sys.stdin.isatty', return_value=True), patch(
                'builtins.input', side_effect=['bad', '17']), patch.object(
                self.app, 'review_change', side_effect=AssertionError('unexpected review')), patch.object(
                self.app, 'apply_terminal_colors') as apply:
            self.app.k_terminal_colors(self.task)
            apply.assert_called_once_with('\033]10;#302344\007\033]11;#F0EAF8\007\033[0m')
        self.assertTrue(self.rc.read_text().startswith('# Keep this\nexport TEST_SETTING=yes\n'))
        self.assertEqual(self.rc.stat().st_mode & 0o777, 0o600)

    def test_default_replaces_and_persists(self):
        with patch.object(self.app, 'apply_terminal_colors') as apply:
            self.app.vars['TERMINAL_COLORS'] = '2'
            self.app.k_terminal_colors(self.task)
            self.app.vars['TERMINAL_COLORS'] = '1'
            self.app.k_terminal_colors(self.task)
            apply.assert_called_with('\033]110\007\033]111\007\033[0m')
        text = self.rc.read_text()
        self.assertEqual(text.count('# BEGIN mysetup terminal colors'), 1)
        self.assertIn("printf '\\033]110\\007\\033]111\\007\\033[0m'", text)
        subprocess.run(['bash', '-n', str(self.rc)], check=True)
        result = subprocess.run(['bash', '--noprofile', '--norc', '-c', '. "$HOME/.bashrc"'],
                                check=True, capture_output=True)
        self.assertEqual(result.stdout, b'')

    def test_cancel_and_dry_run(self):
        before = self.rc.read_text()
        with patch('sys.stdin.isatty', return_value=True), patch(
                'builtins.input', return_value='0'), patch.object(
                self.app, 'apply_terminal_colors') as apply:
            self.assertEqual(self.app.k_terminal_colors(self.task), 'skipped')
            self.app.dry = True
            self.app.vars['TERMINAL_COLORS'] = '1'
            self.app.k_terminal_colors(self.task)
            apply.assert_not_called()
        self.assertEqual(self.rc.read_text(), before)

    def test_controlling_terminal_with_redirected_stdout(self):
        pid, master = pty.fork()
        if pid == 0:
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    self.app.apply_terminal_colors('\033]110\007\033]111\007\033[0m')
            finally:
                os._exit(0)
        data = b''
        try:
            while True:
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                data += chunk
        finally:
            os.close(master)
            _, status = os.waitpid(pid, 0)
        self.assertEqual(status, 0)
        self.assertEqual(data, b'\033]110\007\033]111\007\033[0m')


if __name__ == '__main__':
    unittest.main()
