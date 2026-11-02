import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('install-ssm.sh')

class InstallSSMTests(unittest.TestCase):
    def run_installer(self, mode):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / 'systemctl'
            fake.write_text('''#!/bin/sh
if [ "$1" = list-unit-files ]; then
  case "$SSM_TEST_MODE:$2" in
    snap:snap.amazon-ssm-agent.amazon-ssm-agent.service) echo "$2 enabled enabled" ;;
    deb:amazon-ssm-agent.service) echo "$2 enabled enabled" ;;
  esac
else
  echo "$*" >> "$SSM_TEST_LOG"
fi
''')
            fake.chmod(0o755)
            for command in ('curl', 'dpkg'):
                fake = root / command
                fake.write_text('#!/bin/sh\necho '+command+' >> "$SSM_TEST_LOG"\n')
                fake.chmod(0o755)
            fake = root / 'uname'
            fake.write_text('#!/bin/sh\necho x86_64\n')
            fake.chmod(0o755)
            log = root / 'commands'
            env = dict(os.environ, PATH=directory+':'+os.environ['PATH'], SSM_TEST_MODE=mode, SSM_TEST_LOG=str(log))
            result = subprocess.run(['bash', '-c', SCRIPT.read_text()+'\necho bootstrap-continues\n'], env=env, text=True, capture_output=True, check=True)
            self.assertIn('bootstrap-continues', result.stdout)
            return log.read_text()

    def test_reuses_snap_without_installing_debian(self):
        self.assertEqual(self.run_installer('snap'), 'enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service\n')

    def test_reuses_debian_agent(self):
        self.assertEqual(self.run_installer('deb'), 'enable --now amazon-ssm-agent.service\n')

    def test_installs_only_when_neither_agent_exists(self):
        self.assertEqual(self.run_installer('none'), 'curl\ndpkg\nenable --now amazon-ssm-agent.service\n')

if __name__ == '__main__':
    unittest.main()
