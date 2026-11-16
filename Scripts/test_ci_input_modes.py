import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('with_ci_input_modes.sh')


class InputModesTests(unittest.TestCase):
    def invoke(self, initial, mode='normal', child_status=0, hosted=True, ignore_write=False, extra_env=None):
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
            env = dict(os.environ, PATH=str(root)+os.pathsep+os.environ['PATH'],
                RUNNER_TEMP=tmp, GITHUB_ACTIONS='true' if hosted else 'false',
                RUNNER_ENVIRONMENT='github-hosted' if hosted else '', FAKE_DEFAULTS_STATE=str(state),
                FAKE_IGNORE_WRITE='1' if ignore_write else '0', **(extra_env or {}))
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
        result, restored = self.invoke(2, mode='fka', hosted=False, extra_env={'ATTIC_AIR_INPUT_MODES': '1'})
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
def note(what):
    # Each change says whether the run's state file and its end marker existed.
    marker=os.environ.get('FAKE_MARKER')
    with open(os.environ['FAKE_DEFAULTS_LOG'], 'a') as log:
        log.write(f"{what} state={Path(os.environ['ATTIC_AIR_INPUT_MODES_STATE']).exists()} "
                  f"ended={bool(marker) and Path(marker).exists()}\\n")
if a[0]=='read':
    if value is None: sys.exit(1)
    print(value)
elif a[0]=='write':
    note('write ' + a[-1])
    p.write_text(json.dumps(int(a[-1])))
elif a[0]=='delete':
    note('delete')
    if value is None: sys.exit(1)
    p.write_text('null')
else: sys.exit(2)
'''

# A stand-in run: it starts a worker in its own process group (unless DETACH),
# reports READY, and on `SIGNAL` takes a second to wind down before it marks
# that it ended. Every pid it starts is written down for tearDown.
STAND_IN_RUN = '''import os, signal, subprocess, sys, time
from pathlib import Path
root = Path(os.environ['STAND_IN_ROOT'])
print('CHILD_MODE=' + os.environ['TEST_RUNNER_ATTIC_CI_KEYBOARD_MODE'], flush=True)
(root / 'run.pid').write_text(str(os.getpid()))
worker = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                          close_fds=False, start_new_session=os.environ.get('DETACH') == '1')
(root / 'worker.pid').write_text(str(worker.pid))
mode = os.environ.get('STAND_IN', 'wind-down')
if mode == 'ignore-term':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
elif mode == 'wind-down':
    def wind_down(number, frame):
        time.sleep(1)
        (root / 'ended').write_text('ended')
        sys.exit(0)
    for name in ('SIGHUP', 'SIGINT', 'SIGTERM'):
        signal.signal(getattr(signal, name), wind_down)
print('READY', flush=True)
if mode == 'leave-worker':
    sys.exit(0)
time.sleep(60)
'''


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


class AirInputModesTests(unittest.TestCase):
    """The Air's wrapper, run against stand-ins for `defaults`, `scutil` and a
    long-running test group, with its own build-lock file: no test here reads
    or writes a real setting or takes the real build lock."""

    AIR = SCRIPT.with_name('with_air_input_modes.sh')

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.defaults_state = self.root / 'defaults.json'
        self.defaults_log = self.root / 'defaults.log'
        self.run_state = self.root / 'support' / 'keyboard-mode.state'
        self.lock = self.root / 'build.lock'
        self.processes = []
        for name, body in [('defaults', f'#!{sys.executable}\n' + FAKE_DEFAULTS),
                           ('scutil', '#!/bin/sh\nprintf "%s\\n" "$FAKE_LOCAL_HOST"\n')]:
            path = self.root / name
            path.write_text(body)
            path.chmod(0o755)

    def tearDown(self):
        for process in self.processes:
            if process.poll() is None:
                process.kill()
                process.wait()
        for name in ('run.pid', 'worker.pid'):
            path = self.root / name
            if path.exists() and alive(int(path.read_text())):
                os.kill(int(path.read_text()), signal.SIGKILL)
        self.tmp.cleanup()

    def setting(self):
        return json.loads(self.defaults_state.read_text())

    def changes(self):
        return self.defaults_log.read_text().splitlines() if self.defaults_log.exists() else []

    def lock_is_free(self):
        return subprocess.run(['/usr/bin/lockf', '-k', '-t', '0', str(self.lock), 'true'],
                              capture_output=True).returncode == 0

    def hold_lock(self, seconds):
        holder = subprocess.Popen(['/usr/bin/lockf', '-k', str(self.lock), 'sleep', str(seconds)])
        self.processes.append(holder)
        deadline = time.monotonic() + 5
        while self.lock_is_free():
            self.assertLess(time.monotonic(), deadline, 'lockf never took the lock')
            time.sleep(0.05)
        return holder

    def env(self, host='Tahas-MacBook-Air', authorized=True, **extra):
        env = {k: v for k, v in os.environ.items() if k not in ('RUNNER_TEMP', 'GITHUB_ACTIONS', 'RUNNER_ENVIRONMENT')}
        env.update(PATH=str(self.root) + os.pathsep + os.environ['PATH'],
                   FAKE_DEFAULTS_STATE=str(self.defaults_state), FAKE_DEFAULTS_LOG=str(self.defaults_log),
                   FAKE_MARKER=str(self.root / 'ended'), FAKE_LOCAL_HOST=host, STAND_IN_ROOT=str(self.root),
                   ATTIC_AIR_INPUT_MODES='1' if authorized else '0',
                   ATTIC_AIR_INPUT_MODES_STATE=str(self.run_state),
                   ATTIC_AIR_INPUT_MODES_LOCK=str(self.lock), ATTIC_AIR_INPUT_MODES_GRACE='2', **extra)
        return env

    def prepare(self, initial, leave):
        """`initial` is the setting before the run (None: absent; ...: as it
        is); `leave` presets the state file a killed earlier run left."""
        if initial is not ...:
            self.defaults_state.write_text(json.dumps(initial))
        if leave is not None:
            self.run_state.parent.mkdir(parents=True, exist_ok=True)
            self.run_state.write_text(leave + '\n')

    def run_air(self, mode, child, initial=None, leave=None, **env):
        self.prepare(initial, leave)
        command = ['/bin/bash', str(self.AIR), mode] + ([sys.executable, '-c', child] if child else [])
        return subprocess.run(command, env=self.env(**env), capture_output=True, text=True, timeout=60)

    def start_air(self, mode, initial=None, **env):
        """Starts the wrapper on the stand-in run and returns once it is READY."""
        self.prepare(initial, None)
        process = subprocess.Popen(['/bin/bash', str(self.AIR), mode, sys.executable, '-c', STAND_IN_RUN],
                                   env=self.env(**env), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.processes.append(process)
        self.output = b''
        deadline = time.monotonic() + 20
        while b'READY' not in self.output:
            self.assertLess(time.monotonic(), deadline, self.output.decode())
            ready, _, _ = select.select([process.stdout], [], [], 0.2)
            if ready:
                chunk = os.read(process.stdout.fileno(), 4096)
                self.assertTrue(chunk, 'the wrapper ended before its run was ready: ' + self.output.decode())
                self.output += chunk
        return process

    def finish(self, process, within):
        began = time.monotonic()
        rest, _ = process.communicate(timeout=within + 10)
        self.output += rest
        return time.monotonic() - began

    def pid(self, name):
        return int((self.root / name).read_text())

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
                self.assertEqual(self.changes(), [])
                self.assertFalse(self.run_state.exists())

    def test_the_previous_value_is_on_disk_before_the_setting_changes(self):
        result = self.run_air('fka', self.REPORT, None)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.changes()[0], 'write 3 state=True ended=False')
        self.assertIsNone(self.setting())

    def test_a_signal_reaches_the_whole_run_and_the_restore_waits_for_it_to_end(self):
        for name in ['SIGHUP', 'SIGINT', 'SIGTERM']:
            with self.subTest(signal=name):
                for leftover in ('ended', 'defaults.log'):
                    (self.root / leftover).unlink(missing_ok=True)
                process = self.start_air('fka', 2)
                run, worker = self.pid('run.pid'), self.pid('worker.pid')
                os.kill(process.pid, getattr(signal, name))
                time.sleep(0.3)
                self.assertFalse(self.lock_is_free(), 'the lock stays held while the run winds down')
                self.assertTrue(alive(run), 'the run is still winding down')
                self.finish(process, within=10)
                self.assertEqual(process.returncode, 128 + getattr(signal, name), self.output.decode())
                self.assertTrue((self.root / 'ended').exists(), 'the run got the signal and ended')
                self.assertFalse(alive(run))
                self.assertFalse(alive(worker), 'the signal reached the whole group')
                self.assertEqual(self.changes(), ['write 3 state=True ended=False', 'write 2 state=True ended=True'],
                                 'the restore waited for the run to end')
                self.assertEqual(self.setting(), 2)
                self.assertFalse(self.run_state.exists())
                self.assertTrue(self.lock_is_free())

    def test_a_run_that_ignores_term_is_killed_after_the_grace(self):
        process = self.start_air('fka', None, STAND_IN='ignore-term')
        run, worker = self.pid('run.pid'), self.pid('worker.pid')
        os.kill(process.pid, signal.SIGTERM)
        took = self.finish(process, within=10)
        self.assertEqual(process.returncode, 143, self.output.decode())
        self.assertGreater(took, 1.5, 'it waited the grace first')
        self.assertIn(b'sending KILL', self.output)
        self.assertFalse(alive(run))
        self.assertFalse(alive(worker))
        self.assertIsNone(self.setting())
        self.assertFalse(self.run_state.exists())

    def test_part_of_a_run_left_behind_is_ended_before_the_restore(self):
        process = self.start_air('fka', 2, STAND_IN='leave-worker')
        worker = self.pid('worker.pid')
        self.finish(process, within=10)
        self.assertEqual(process.returncode, 0, self.output.decode())
        self.assertFalse(alive(worker))
        self.assertEqual(self.setting(), 2)

    def test_nothing_the_run_detaches_keeps_the_build_lock(self):
        process = self.start_air('fka', 2, STAND_IN='leave-worker', DETACH='1')
        worker = self.pid('worker.pid')
        self.finish(process, within=10)
        self.assertEqual(process.returncode, 0, self.output.decode())
        self.assertTrue(alive(worker), 'a detached worker is outside the run\'s group')
        self.assertTrue(self.lock_is_free(), 'and it does not hold the build lock')
        self.assertEqual(self.setting(), 2)

    def test_the_wrapper_and_lockf_hold_the_same_build_lock(self):
        holder = self.hold_lock(2)
        process = self.start_air('fka', None)
        self.assertIsNotNone(holder.poll(), 'the run started only after lockf let go')
        self.assertIn(b'waiting for the build lock', self.output)
        self.assertFalse(self.lock_is_free(), 'lockf cannot take the lock during the run')
        os.kill(process.pid, signal.SIGTERM)
        self.finish(process, within=10)
        self.assertTrue(self.lock_is_free())
        self.assertIsNone(self.setting())

    def test_a_killed_run_is_restored_before_the_next_run_does_anything(self):
        child = self.REPORT + 'import signal; os.kill(os.getppid(), signal.SIGKILL)'
        killed = self.run_air('fka', child, None)
        self.assertEqual(killed.returncode, -9)
        self.assertEqual(self.setting(), 3, 'SIGKILL skips every trap')
        self.assertEqual(self.run_state.read_text().strip(), 'absent', 'the old value survives on disk')
        probe = self.REPORT + 'import subprocess; print("SEEN=" + subprocess.run(["defaults","read","-g","AppleKeyboardUIMode"], capture_output=True, text=True).stdout.strip())'
        result = self.run_air('normal', probe, ...)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        out = result.stdout
        self.assertLess(out.index('restored keyboard=absent'), out.index('before keyboard=absent'))
        self.assertIn('SEEN=0', out)
        self.assertIsNone(self.setting())
        self.assertFalse(self.run_state.exists())

    def test_restore_puts_a_leftover_back_only_while_no_run_holds_the_lock(self):
        self.prepare(3, '2')
        holder = self.hold_lock(30)
        refused = self.run_air('restore', None, ...)
        self.assertEqual(refused.returncode, 75, refused.stdout + refused.stderr)
        self.assertIn('refusing to restore', refused.stderr)
        self.assertEqual(self.setting(), 3)
        self.assertTrue(self.run_state.exists())
        holder.kill()
        holder.wait()
        result = self.run_air('restore', None, ...)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.setting(), 2)
        self.assertFalse(self.run_state.exists())
        result = self.run_air('restore', None, ...)
        self.assertEqual(result.returncode, 0)
        self.assertIn('nothing to restore', result.stdout)

    def test_a_leftover_that_will_not_restore_stops_the_run_and_keeps_its_state(self):
        result = self.run_air('fka', self.REPORT, 3, leave='not-a-mode')
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('CHILD_MODE=', result.stdout)
        self.assertEqual(self.setting(), 3)
        self.assertTrue(self.run_state.exists())

    def test_the_air_branch_runs_the_wrapper_without_lockf_and_never_on_ci(self):
        wrapper = SCRIPT.with_name('xcodebuild_locked.sh').read_text()
        blocks = wrapper.split('\nif ')
        ci = next(b for b in blocks if 'with_ci_input_modes.sh' in b)
        air = next(b for b in blocks if 'with_air_input_modes.sh' in b)
        self.assertNotIn('with_air_input_modes.sh', ci)
        condition = air.split('\n', 1)[0]
        self.assertIn('"${GITHUB_ACTIONS:-}" != true', condition)
        self.assertIn('"${ATTIC_AIR_INPUT_MODES:-}" = 1', condition)
        body = air.split('test|test-without-building)', 1)[1].split(';;', 1)[0]
        self.assertIn('exec "$script_dir/with_air_input_modes.sh"', body)
        self.assertNotIn('lockf', body, 'the wrapper takes the lock itself; lockf around it would deadlock')
        self.assertIn('ATTIC_AIR_INPUT_MODES_LOCK:-/tmp/attic-xcodebuild.lock', self.AIR.read_text())


if __name__ == '__main__':
    unittest.main()
