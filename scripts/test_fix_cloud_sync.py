#!/usr/bin/env python3
"""Offline regression tests; all configuration and build outputs use temporary files."""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('fix_cloud_sync.sh')
PUBLIC = 'sb_publishable_' + 'a' * 32


def jwt(role):
    encode = lambda value: base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')
    return encode({'alg': 'HS256'}) + '.' + encode({'role': role}) + '.' + base64.urlsafe_b64encode(b'x' * 32).decode().rstrip('=')


class FixCloudSyncTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'scripts').mkdir()
        (self.root / 'android').mkdir()
        self.script = self.root / 'scripts/fix_cloud_sync.sh'
        shutil.copy2(SCRIPT, self.script)
        (self.root / 'pubspec.yaml').write_text('version: 0.1.0+713\n')
        self.local = self.root / 'android/local.properties'
        self.local.write_text('# keep\nsdk.dir=/some/sdk\nSUPABASE_ANON_KEY=old\nSUPABASE_ANON_KEY:duplicate\nCLOUD_SYNC_ENABLED=false\nPRIVATE_SETTING=untouched\n')
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('SUPABASE_')}

    def run_script(self, *args, success=True):
        result = subprocess.run(['bash', str(self.script), *args], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        self.assertNotIn(PUBLIC, result.stdout + result.stderr)
        return result

    def test_idempotence_and_preservation(self):
        config = self.root / 'car_env.json'
        config.write_text('{"OTHER": "preserved", "SUPABASE_SERVICE_ROLE_KEY": "untouched"}')
        self.run_script(PUBLIC, '--configure-only')
        first = (self.local.read_bytes(), config.read_bytes())
        self.run_script(PUBLIC, '--configure-only')
        self.assertEqual(first, (self.local.read_bytes(), config.read_bytes()))
        self.assertEqual(self.local.read_text().count('SUPABASE_ANON_KEY='), 1)
        self.assertIn('sdk.dir=/some/sdk', self.local.read_text())
        data = json.loads(config.read_text())
        self.assertEqual(data['OTHER'], 'preserved')
        self.assertEqual(data['SUPABASE_SERVICE_ROLE_KEY'], 'untouched')
        self.assertEqual(data['SUPABASE_PUBLISHABLE_KEY'], PUBLIC)
        self.run_script(PUBLIC, '--configure-only', '--no-update-car-env')
        self.assertEqual(first, (self.local.read_bytes(), config.read_bytes()))

    def test_reject_invalid_and_private_before_writing(self):
        initial = self.local.read_bytes()
        for key in ['', 'bad', 'sb_secret_' + 'x' * 32, jwt('service_role'), jwt('authenticated')]:
            self.run_script(key, '--configure-only', success=False)
            self.assertEqual(initial, self.local.read_bytes())
            self.assertFalse((self.root / 'car_env.json').exists())

    def test_legacy_and_environment(self):
        self.env['SUPABASE_ANON_KEY'] = jwt('anon')
        self.run_script('--configure-only')
        self.assertIn(self.env['SUPABASE_ANON_KEY'], self.local.read_text())

    def test_invalid_json_and_no_update_mismatch(self):
        initial = self.local.read_bytes()
        self.run_script(PUBLIC, '--configure-only', '--no-update-car-env', success=False)
        (self.root / 'car_env.json').write_text('{bad')
        self.run_script(PUBLIC, '--configure-only', success=False)
        self.assertEqual(initial, self.local.read_bytes())

    def test_build_sequence_and_apk_path(self):
        fake = self.root / 'flutter'
        fake.write_text('#!/bin/bash\nset -eu\nprintf "%s\\n" "$*" >> calls\nif [[ "$1" == build ]]; then\n mkdir -p build/app/outputs/flutter-apk\n touch build/app/outputs/flutter-apk/app-release.apk\nfi\n')
        fake.chmod(0o755)
        self.env['FLUTTER_BIN'] = str(fake)
        result = self.run_script(PUBLIC)
        self.assertEqual((self.root / 'calls').read_text().splitlines(), ['clean', 'pub get', 'build apk --release --target-platform android-arm64 --build-name=0.1.0-debug --dart-define-from-file=car_env.json'])
        delivery = self.root / 'build/app/outputs/flutter-apk/Eaglemetry_v01_test.apk'
        self.assertTrue(delivery.is_file())
        self.assertIn(str(delivery), result.stdout)


if __name__ == '__main__':
    unittest.main()
