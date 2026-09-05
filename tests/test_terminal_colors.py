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

    def test_background_inventory_and_readability(self):
        palettes = MODULE['conf_lines'](self.task.require('palettes'))
        self.assertEqual(len(palettes), 44)
        backgrounds = set()
        def luminance(color):
            channels = [int(color[n:n+2], 16) / 255 for n in (1, 3, 5)]
            linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
                      for c in channels]
            return sum(c * w for c, w in zip(linear, (0.2126, 0.7152, 0.0722)))
        for palette in palettes:
            name, fg, bg = [part.strip() for part in palette.split('|')]
            backgrounds.add(bg)
            light, dark = sorted((luminance(fg), luminance(bg)), reverse=True)
            self.assertGreaterEqual((light + 0.05) / (dark + 0.05), 4.5, name)
        self.assertEqual(len(backgrounds), 44)

    def grid_session(self, keys):
        import fcntl
        import select
        import signal
        import struct
        import sys
        import termios
        import time
        result = Path(self.temp.name) / 'grid-result'
        pid, master = pty.fork()
        if pid == 0:
            try:
                sys.stdin = open('/dev/tty', 'r')
                sys.stdout = open('/dev/tty', 'w', buffering=1)
                fcntl.ioctl(sys.stdin.fileno(), termios.TIOCSWINSZ,
                            struct.pack('HHHH', 24, 100, 0, 0))
                os.environ.pop('LINES', None)
                os.environ.pop('COLUMNS', None)
                original = termios.tcgetattr(sys.stdin.fileno())
                palettes = [('Default', None, None)] + [
                    (f'Color {n}', '#EEEEEE', '#123456') for n in range(44)]
                try:
                    choice = self.app.color_grid(palettes)
                except KeyboardInterrupt:
                    choice = 'interrupted'
                restored = termios.tcgetattr(sys.stdin.fileno()) == original
                result.write_text(f'{choice}|{restored}')
                os._exit(0)
            except BaseException:
                os._exit(1)
        data = b''
        sent = False
        deadline = time.monotonic() + 5
        try:
            while time.monotonic() < deadline:
                if not select.select([master], [], [], 0.1)[0]:
                    continue
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                data += chunk
                if not sent and b'Page 1/' in data:
                    os.write(master, keys)
                    sent = True
            else:
                os.kill(pid, signal.SIGKILL)
                self.fail('grid did not exit within five seconds')
        finally:
            os.close(master)
            _, status = os.waitpid(pid, 0)
        self.assertEqual(status, 0)
        self.assertTrue(sent)
        self.assertIn(b'\x1b[?25h\x1b[?1049l', data)
        return result.read_text(), data

    def test_grid_arrows_and_pages(self):
        result, output = self.grid_session(b'\x1b[C\x1b[B\r')
        self.assertEqual(result, '5|True')  # 3 columns: right one, down three
        self.assertIn(b'38;2;238;238;238;48;2;18;52;86m', output)
        result, _ = self.grid_session(b'\x1b[6~\r')
        self.assertEqual(result, '16|True')  # 5 rows of 3 columns

    def test_grid_number_cancel_and_interrupt(self):
        for keys, expected in [(b'45\r', '45'), (b'q', ''),
                               (b'\x1b', ''), (b'\x03', 'interrupted')]:
            with self.subTest(keys=keys):
                result, _ = self.grid_session(keys)
                self.assertEqual(result, expected + '|True')

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
