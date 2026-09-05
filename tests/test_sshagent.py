import contextlib
import io
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
M = runpy.run_path(str(ROOT / 'mysetup'), run_name='test_sshagent')


class SSHAgent(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        env = patch.dict(os.environ, HOME=temp.name)
        env.start()
        self.addCleanup(env.stop)
        self.key = self.home / 'test-key'
        self.key.write_text('test fixture; never passed to real ssh-add')
        args = M['build_parser']().parse_args(['--etc', str(ROOT / 'mysetup-etc'),
                                             '--yes', '--set', f'SSH_KEY_PATH={self.key}'])
        self.app = M['MySetup'](args)
        self.task = self.app.tasks['sshagent']
        self.app.confirm = lambda *a, **k: True
        self.patcher = patch.object(self.app, 'agent_status')
        self.probe = self.patcher.start()
        self.addCleanup(self.patcher.stop)
        self.probe.return_value = subprocess.CompletedProcess([], 0, 'verified test identity', '')
        stream = contextlib.redirect_stdout(io.StringIO())
        stream.__enter__()
        self.addCleanup(stream.__exit__, None, None, None)

    def test_reuses_agent_and_persists_without_duplicate_hook(self):
        os.environ['SSH_AUTH_SOCK'] = '/test/socket'
        rc = self.home / '.bashrc'
        rc.write_text('# existing\n')
        rc.chmod(0o600)
        with patch('subprocess.run', return_value=subprocess.CompletedProcess([], 0)) as run:
            self.app.k_sshagent(self.task)
            self.app.k_sshagent(self.task)
            self.assertEqual([call.args[0] for call in run.call_args_list],
                             [['ssh-add', str(self.key)]] * 2)
        self.assertEqual(rc.read_text().count('activate.sh" ]'), 1)
        self.assertTrue(rc.read_text().startswith('# existing\n'))
        self.assertEqual(rc.stat().st_mode & 0o777, 0o600)
        snippet = self.home / '.ssh/mysetup-agent/activate.sh'
        subprocess.run(['bash', '-n', str(snippet)], check=True)
        self.assertEqual(snippet.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.app.visible()[10].id, 'sshagent')

    def test_starts_and_verifies_new_agent(self):
        missing = subprocess.CompletedProcess([], 2, '', 'no agent')
        empty = subprocess.CompletedProcess([], 1, 'no identities', '')
        loaded = subprocess.CompletedProcess([], 0, 'identity', '')
        self.probe.side_effect = [missing, missing, empty, loaded]
        with patch('subprocess.run', return_value=subprocess.CompletedProcess([], 0)) as run:
            self.app.k_sshagent(self.task)
            calls = [call.args[0] for call in run.call_args_list]
        sock = str(self.home / '.ssh/mysetup-agent/agent.sock')
        self.assertEqual(calls, [['ssh-agent', '-a', sock, '-s'], ['ssh-add', str(self.key)]])
        self.assertEqual(os.environ['SSH_AUTH_SOCK'], sock)

    def test_failed_unlock_does_not_claim_success_or_install_hook(self):
        os.environ['SSH_AUTH_SOCK'] = '/test/socket'
        with patch('subprocess.run', return_value=subprocess.CompletedProcess([], 1)):
            with self.assertRaisesRegex(M['TaskError'], 'key loading was not verified'):
                self.app.k_sshagent(self.task)
        self.assertFalse((self.home / '.bashrc').exists())

    def test_dry_run_does_not_start_agent_or_write_files(self):
        self.app.dry = True
        with patch('subprocess.run') as run:
            self.app.k_sshagent(self.task)
            run.assert_not_called()
        self.assertFalse((self.home / '.ssh').exists())


if __name__ == '__main__':
    unittest.main()
