from pathlib import Path
import os
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("hugepages.sh")


class HugepageStartupTests(unittest.TestCase):
    def plan(self, total_mib, reserved_mib, percentage):
        return subprocess.run(
            ["bash", str(SCRIPT), "plan", str(total_mib), str(reserved_mib), str(percentage)],
            capture_output=True, text=True,
        )

    def test_shared_pool_preserves_total_budget_and_host_reserve(self):
        result = self.plan(65536, 4096, 50)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "4096 15360 15360")

    def test_default_and_full_pool_use_the_same_budget(self):
        for percentage, expected in [(0, "4096 0 30720"), (100, "4096 30720 0")]:
            with self.subTest(percentage=percentage):
                result = self.plan(65536, 4096, percentage)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)

    def test_rounding_does_not_drop_a_page_or_exceed_the_budget(self):
        result = self.plan(65535, 4096, 10)
        self.assertEqual(result.returncode, 0, result.stderr)
        reserve, base, surplus = map(int, result.stdout.split())
        self.assertEqual((reserve, base, surplus), (4096, 3071, 27648))
        self.assertEqual((base + surplus) * 2, 65535 - reserve - 1)

    def test_build_reserve_policy_is_preserved(self):
        for total, expected in [
            (16384, "4096 3686 2458"),
            (65536, "10485 16515 11010"),
            (524288, "43008 144384 96256"),
        ]:
            with self.subTest(total=total):
                result = self.plan(total, 0, 60)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)

    def test_invalid_settings_fail_before_allocation(self):
        for total, reserve, percentage in [
            (65536, 4096, -1), (65536, 4096, 101), (65536, 4096, 1.5),
            (4096, 4096, 10), (2048, 0, 10), (65536, -1, 10),
        ]:
            with self.subTest(total=total, reserve=reserve, percentage=percentage):
                result = self.plan(total, reserve, percentage)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def verify(self, actual_base, actual_surplus):
        # Fake only the read-only sysctl command. Never write host kernel settings.
        with tempfile.TemporaryDirectory() as directory:
            sysctl = Path(directory) / "sysctl"
            sysctl.write_text(
                '#!/bin/sh\n'
                'test "$1" = "-n" || exit 2\n'
                'case "$2" in\n'
                f'  vm.nr_hugepages) echo {actual_base} ;;\n'
                f'  vm.nr_overcommit_hugepages) echo {actual_surplus} ;;\n'
                '  *) exit 2 ;;\n'
                'esac\n'
            )
            sysctl.chmod(0o755)
            return subprocess.run(
                ["bash", str(SCRIPT), "verify", "3072", "27648"],
                env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"]},
                capture_output=True, text=True,
            )

    def test_allocated_pool_passes_the_startup_gate(self):
        result = self.verify(3072, 27648)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("base requested=3072 actual=3072", result.stdout)

    def test_partial_allocation_blocks_startup_with_diagnostics(self):
        result = self.verify(2048, 27648)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("base requested=3072 actual=2048", result.stdout)
        self.assertIn("refusing to start Nomad", result.stderr)

    def test_incorrect_budget_blocks_startup(self):
        for base, surplus in [(4096, 27648), (3072, 30720), (3072, 0)]:
            with self.subTest(base=base, surplus=surplus):
                result = self.verify(base, surplus)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("refusing to start Nomad", result.stderr)


if __name__ == "__main__":
    unittest.main()
