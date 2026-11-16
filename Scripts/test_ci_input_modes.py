import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('with_ci_input_modes.sh')


class InputModesTests(unittest.TestCase):
    def invoke(self, initial, mode='normal', child_status=0, hosted=True, ignore_write=False,
               air=False, host='Tahas-MacBook-Air'):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state = root / 'defaults.json'
            state.write_text(json.dumps(initial))
            fake = root / 'defaults'
            fake.write_text(f'#!{sys.executable}\n' + '''import json, os, sys
from pathlib import Path
p=Path(os.environ['FAKE_DEFAULTS_STATE'])
value=json.loads(p.read_text())
a=sys.argv[1:]
if a[0]=='read':
    if value is None: sys.exit(1)
    print(value)
elif a[0]=='write':
    if os.environ.get('FAKE_IGNORE_WRITE')!='1': p.write_text(json.dumps(int(a[-1])))
elif a[0]=='delete': p.write_text('null')
else: sys.exit(2)
''')
            fake.chmod(0o755)
            fake_hostname = root / 'hostname'
            fake_hostname.write_text('#!/bin/sh\n' + 'printf "%s\\n" "$FAKE_HOSTNAME"\n')
            fake_hostname.chmod(0o755)
            env = dict(os.environ, PATH=str(root)+os.pathsep+os.environ['PATH'],
                RUNNER_TEMP=tmp, GITHUB_ACTIONS='true' if hosted else 'false',
                RUNNER_ENVIRONMENT='github-hosted' if hosted else '', FAKE_DEFAULTS_STATE=str(state),
                FAKE_IGNORE_WRITE='1' if ignore_write else '0',
                ATTIC_AIR_INPUT_MODES='1' if air else '0', FAKE_HOSTNAME=host)
            child = 'import os,sys; print("CHILD_MODE="+os.environ["TEST_RUNNER_ATTIC_CI_KEYBOARD_MODE"]); sys.exit('+str(child_status)+')'
            result = subprocess.run(['/bin/bash', str(SCRIPT), mode, sys.executable, '-c', child],
                env=env, capture_output=True, text=True)
            return result, json.loads(state.read_text())

    def test_restores_present_and_absent_settings_after_success_and_failure(self):
        for initial in [None, 2]:
            for mode, expected in [('normal','0'), ('fka','3')]:
                for status in [0,7]:
                    with self.subTest(initial=initial,mode=mode,status=status):
                        result, restored = self.invoke(initial, mode, status)
                        self.assertEqual(result.returncode,status,result.stdout+result.stderr)
                        self.assertEqual(restored,initial)
                        self.assertIn('verified keyboard='+expected,result.stdout)
                        self.assertIn('CHILD_MODE='+expected,result.stdout)
                        self.assertIn('restored keyboard=',result.stdout)

    def test_never_changes_local_settings(self):
        result, restored = self.invoke(2, hosted=False)
        self.assertEqual(result.returncode,2)
        self.assertEqual(restored,2)
        self.assertNotIn('CHILD_MODE=',result.stdout)

    def test_the_ci_script_never_takes_an_air_request(self):
        result, restored = self.invoke(2, mode='fka', hosted=False, air=True)
        self.assertEqual(result.returncode,2)
        self.assertEqual(restored,2)
        self.assertNotIn('CHILD_MODE=',result.stdout)

    def test_a_setting_that_did_not_take_effect_fails_before_the_group(self):
        result, restored = self.invoke(2, ignore_write=True)
        self.assertEqual(result.returncode,1)
        self.assertEqual(restored,2)
        self.assertIn('verification failed',result.stdout)
        self.assertNotIn('CHILD_MODE=',result.stdout)

    def test_the_build_lock_covers_mode_changes_and_the_test_group(self):
        wrapper = SCRIPT.with_name('xcodebuild_locked.sh').read_text()
        locked_modes = wrapper.split('test|test-without-building)', 1)[1].split(';;', 1)[0]
        self.assertLess(locked_modes.index('exec /usr/bin/lockf'), locked_modes.index('with_ci_input_modes.sh'))
        self.assertIn('${GITHUB_ACTIONS:-}', wrapper)


FAKE_DEFAULTS = '''import json, os, sys
from pathlib import Path
p=Path(os.environ['FAKE_DEFAULTS_STATE'])
value=json.loads(p.read_text())
a=sys.argv[1:]
if a[0]=='read':
    if value is None: sys.exit(1)
    print(value)
elif a[0]=='write':
    if os.environ.get('FAKE_IGNORE_WRITE')!='1': p.write_text(json.dumps(int(a[-1])))
elif a[0]=='delete':
    if value is None: sys.exit(1)
    p.write_text('null')
else: sys.exit(2)
'''


class AirInputModesTests(unittest.TestCase):
    """The Air's wrapper, run against stand-ins for `defaults` and `scutil`:
    no test here reads or writes a real setting."""

    AIR = SCRIPT.with_name('with_air_input_modes.sh')

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.defaults_state = self.root / 'defaults.json'
        self.run_state = self.root / 'support' / 'keyboard-mode.state'
        for name, body in [('defaults', f'#!{sys.executable}\n' + FAKE_DEFAULTS),
                           ('scutil', '#!/bin/sh\nprintf "%s\\n" "$FAKE_LOCAL_HOST"\n')]:
            path = self.root / name
            path.write_text(body)
            path.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def setting(self):
        return json.loads(self.defaults_state.read_text())

    def run_air(self, mode, child, initial=None, host='Tahas-MacBook-Air', authorized=True, leave=None):
        """`initial` is the setting before the run (None: absent); `leave`
        presets the state file a killed earlier run left behind."""
        if initial is not ...:
            self.defaults_state.write_text(json.dumps(initial))
        if leave is not None:
            self.run_state.parent.mkdir(parents=True, exist_ok=True)
            self.run_state.write_text(leave + '\n')
        env = {k: v for k, v in os.environ.items() if k not in ('RUNNER_TEMP', 'GITHUB_ACTIONS', 'RUNNER_ENVIRONMENT')}
        env.update(PATH=str(self.root) + os.pathsep + os.environ['PATH'],
                   FAKE_DEFAULTS_STATE=str(self.defaults_state), FAKE_LOCAL_HOST=host,
                   ATTIC_AIR_INPUT_MODES='1' if authorized else '0',
                   ATTIC_AIR_INPUT_MODES_STATE=str(self.run_state))
        command = ['/bin/bash', str(self.AIR), mode] + ([sys.executable, '-c', child] if child else [])
        return subprocess.run(command, env=env, capture_output=True, text=True, timeout=30)

    REPORT = 'import os,sys; print("CHILD_MODE="+os.environ["TEST_RUNNER_ATTIC_CI_KEYBOARD_MODE"]); sys.stdout.flush(); '

    def test_restores_present_and_absent_settings_without_a_runner_temp(self):
        for initial in [None, 2]:
            for mode, expected in [('normal', '0'), ('fka', '3')]:
                for status in [0, 7]:
                    with self.subTest(initial=initial, mode=mode, status=status):
                        result = self.run_air(mode, self.REPORT + f'sys.exit({status})', initial)
                        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                        self.assertIn('CHILD_MODE=' + expected, result.stdout)
                        self.assertEqual(self.setting(), initial)
                        self.assertFalse(self.run_state.exists(), 'a verified restore removes the state file')

    def test_only_an_authorized_run_on_the_air_changes_anything(self):
        for host, authorized in [('Another-Mac', True), ('Tahas-MacBook-Air', False)]:
            with self.subTest(host=host, authorized=authorized):
                result = self.run_air('fka', self.REPORT, 2, host=host, authorized=authorized)
                self.assertEqual(result.returncode, 2)
                self.assertNotIn('CHILD_MODE=', result.stdout)
                self.assertEqual(self.setting(), 2)
                self.assertFalse(self.run_state.exists())

    def test_the_previous_value_is_on_disk_before_the_setting_changes(self):
        probe = self.REPORT + 'from pathlib import Path; print("STATE=" + Path(os.environ["ATTIC_AIR_INPUT_MODES_STATE"]).read_text().strip())'
        result = self.run_air('fka', probe, None)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('CHILD_MODE=3', result.stdout)
        self.assertIn('STATE=absent', result.stdout)
        self.assertIsNone(self.setting())

    def test_hup_int_and_term_restore_at_once(self):
        import signal, time
        for name in ['SIGHUP', 'SIGINT', 'SIGTERM']:
            with self.subTest(signal=name):
                child = self.REPORT + f'import signal,time; os.kill(os.getppid(), signal.{name}); time.sleep(20)'
                began = time.monotonic()
                result = self.run_air('fka', child, 2)
                self.assertLess(time.monotonic() - began, 10, 'the restore must not wait for the run to end')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('CHILD_MODE=3', result.stdout)
                self.assertIn('restored keyboard=2', result.stdout)
                self.assertEqual(self.setting(), 2)
                self.assertFalse(self.run_state.exists())

    def test_a_killed_run_is_restored_before_the_next_run_does_anything(self):
        child = self.REPORT + 'import signal; os.kill(os.getppid(), signal.SIGKILL)'
        killed = self.run_air('fka', child, None)
        self.assertEqual(killed.returncode, -9)
        self.assertEqual(self.setting(), 3, 'SIGKILL skips every trap')
        self.assertEqual(self.run_state.read_text().strip(), 'absent', 'the old value survives on disk')
        # The next run, even one asking for another mode, puts it back first.
        probe = self.REPORT + 'import subprocess; print("SEEN=" + subprocess.run(["defaults","read","-g","AppleKeyboardUIMode"], capture_output=True, text=True).stdout.strip())'
        result = self.run_air('normal', probe, ...)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        out = result.stdout
        self.assertLess(out.index('restored keyboard=absent'), out.index('before keyboard=absent'))
        self.assertIn('SEEN=0', out)
        self.assertIsNone(self.setting())
        self.assertFalse(self.run_state.exists())

    def test_restore_alone_puts_a_leftover_back_and_runs_nothing(self):
        result = self.run_air('restore', None, 3, leave='2')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.setting(), 2)
        self.assertFalse(self.run_state.exists())
        result = self.run_air('restore', None, 2)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.setting(), 2)

    def test_a_leftover_that_will_not_restore_stops_the_run_and_keeps_its_state(self):
        result = self.run_air('fka', self.REPORT, 3, leave='not-a-mode')
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('CHILD_MODE=', result.stdout)
        self.assertEqual(self.setting(), 3)
        self.assertTrue(self.run_state.exists())

    def test_the_air_branch_takes_the_build_lock_before_the_wrapper(self):
        wrapper = SCRIPT.with_name('xcodebuild_locked.sh').read_text()
        branch = next(b for b in wrapper.split('\nelif ')[1:] if 'with_air_input_modes.sh' in b)
        condition = branch.split('\n', 1)[0]
        self.assertIn('${ATTIC_AIR_INPUT_MODES:-}', condition)
        self.assertNotIn('GITHUB_ACTIONS', condition)
        body = branch.split('test|test-without-building)', 1)[1].split(';;', 1)[0]
        self.assertLess(body.index('exec /usr/bin/lockf -k /tmp/attic-xcodebuild.lock'),
                        body.index('with_air_input_modes.sh'))
        self.assertNotIn('with_air_input_modes.sh', wrapper.split('\nelif ')[0], 'never on the CI branch')


if __name__ == '__main__':
    unittest.main()
