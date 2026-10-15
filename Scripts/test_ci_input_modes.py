import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('with_ci_input_modes.sh')


class InputModesTests(unittest.TestCase):
    def invoke(self, initial, mode='normal', child_status=0, hosted=True, ignore_write=False):
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
                FAKE_IGNORE_WRITE='1' if ignore_write else '0')
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


if __name__ == '__main__':
    unittest.main()
