import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("report_capacity", Path(__file__).with_name("report-capacity.py"))
report_capacity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report_capacity)


def meminfo(**overrides):
    values = {
        "MemTotal": 64 * 1024 * 1024,
        "MemAvailable": 60 * 1024 * 1024,
        "Hugepagesize": 2048,
        "HugePages_Total": 0,
        "HugePages_Free": 0,
        "HugePages_Rsvd": 0,
    }
    values.update(overrides)
    return "\n".join(f"{key}: {value}" for key, value in values.items())


class MemoryUtilizationTests(unittest.TestCase):
    def test_idle_preallocated_pool_is_not_workload(self):
        value = report_capacity.memory_utilization(
            meminfo(MemAvailable=28 * 1024 * 1024, HugePages_Total=16384, HugePages_Free=16384),
            16384, 8192,
        )
        self.assertEqual(value, 6.25)

    def test_unfaulted_guest_reservations_trigger_scaling(self):
        value = report_capacity.memory_utilization(
            meminfo(HugePages_Total=24576, HugePages_Free=24576, HugePages_Rsvd=24576),
            0, 30720,
        )
        self.assertEqual(value, 80)

    def test_used_and_reserved_pages_both_consume_capacity(self):
        value = report_capacity.memory_utilization(
            meminfo(HugePages_Total=16384, HugePages_Free=12288, HugePages_Rsvd=12288),
            0, 32768,
        )
        self.assertEqual(value, 50)

    def test_ordinary_memory_pressure_can_trigger_scaling(self):
        self.assertEqual(
            report_capacity.memory_utilization(meminfo(MemAvailable=8 * 1024 * 1024), 0, 30720),
            87.5,
        )

    def test_surplus_is_not_added_to_the_limit_twice(self):
        value = report_capacity.memory_utilization(
            meminfo(HugePages_Total=16384, HugePages_Free=15191, HugePages_Rsvd=15191),
            15940, 10626,
        )
        self.assertAlmostEqual(value, 100 * 16384 / 26566)

    def test_missing_or_invalid_counters_never_publish_zero(self):
        with self.assertRaises(KeyError):
            report_capacity.memory_utilization("MemTotal: 100", 1, 1)
        with self.assertRaises(ValueError):
            report_capacity.memory_utilization(meminfo(), 0, 0)
        with self.assertRaises(ValueError):
            report_capacity.memory_utilization(meminfo(HugePages_Free=1), 0, 1)


if __name__ == "__main__":
    unittest.main()
