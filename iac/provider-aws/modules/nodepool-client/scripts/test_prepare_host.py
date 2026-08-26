from pathlib import Path
import os
import shlex
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("prepare-host.sh")
NOMAD_SCRIPT = SCRIPT.parents[3] / "nomad-cluster/scripts/run-nomad.sh"
TARGETS = ["/fc-envd", "/fc-kernels", "/fc-versions", "/fc-busybox", "/mnt/hugepages"]


class HostPreparationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls"
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        TEST_ROOT=str(self.root), TEST_LOG=str(self.log))
        self.command("modprobe", 'echo "module $*" >> "$TEST_LOG"; exit "${FAIL_MODULE:-0}"')
        self.command("mountpoint", 'test -f "$TEST_ROOT/mounted-${2##*/}"')
        self.command("mount", '\n'.join([
            'echo "mount $1" >> "$TEST_LOG"',
            'test "${FAIL_MOUNT:-}" != "$1" || exit 1',
            'if [ "${RETRY_ONCE:-}" = "$1" ] && [ ! -f "$TEST_ROOT/retried" ]; then',
            '  touch "$TEST_ROOT/retried"; exit 1',
            'fi',
            'touch "$TEST_ROOT/mounted-${1##*/}"',
        ]))
        self.command("sleep", "exit 0")

    def command(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def prepare(self, **overrides):
        return subprocess.run(["bash", str(SCRIPT)], env=dict(self.env, **overrides),
                              capture_output=True, text=True)

    def test_restores_module_and_all_mounts(self):
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text().splitlines(),
                         ["module nbd nbds_max=4096"] + ["mount " + p for p in TARGETS])

    def test_existing_mounts_are_preserved(self):
        for target in TARGETS:
            (self.root / ("mounted-" + target.rsplit("/", 1)[1])).touch()
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text().splitlines(), ["module nbd nbds_max=4096"])

    def test_mount_retries_allow_dns_to_start(self):
        result = self.prepare(RETRY_ONCE="/fc-envd")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text().splitlines().count("mount /fc-envd"), 2)

    def test_missing_module_or_mount_blocks_startup(self):
        result = self.prepare(FAIL_MODULE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("mount ", self.log.read_text())
        result = self.prepare(FAIL_MOUNT="/fc-envd")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to start Nomad", result.stderr)
        self.assertNotIn("mount /fc-kernels", self.log.read_text())

    def render_nomad_command(self):
        # Source only the production function definitions; never run metadata,
        # service configuration, or Supervisor commands on the test host.
        source = self.root / "run-nomad-functions.sh"
        source.write_text(NOMAD_SCRIPT.read_text().rsplit('\nrun "$@"', 1)[0])
        config = self.root / "nomad.conf"
        subprocess.run([
            "bash", "-c", 'source "$1"; generate_supervisor_config "$2" /config /data "$3" /logs root false',
            "test", str(source), str(config), str(self.bin),
        ], check=True, capture_output=True, text=True)
        return next(line.removeprefix("command=") for line in config.read_text().splitlines()
                    if line.startswith("command="))

    def test_nodes_without_hook_keep_original_command(self):
        self.assertEqual(self.render_nomad_command(),
                         f"{self.bin}/nomad agent -config /config -data-dir /data")

    def test_hook_runs_before_nomad_and_failure_blocks_it(self):
        self.command("nomad", 'echo "nomad $*" >> "$TEST_LOG"')
        self.command("prepare-host.sh", 'echo prepare >> "$TEST_LOG"; exit "${FAIL_PREPARE:-0}"')
        command = shlex.split(self.render_nomad_command())
        result = subprocess.run(command, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text().splitlines(),
                         ["prepare", "nomad agent -config /config -data-dir /data"])
        self.log.unlink()
        result = subprocess.run(command, env=dict(self.env, FAIL_PREPARE="1"),
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.log.read_text().splitlines(), ["prepare"])


if __name__ == "__main__":
    unittest.main()
