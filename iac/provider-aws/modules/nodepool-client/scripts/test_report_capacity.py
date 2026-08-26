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
    def test_idle_shared_ten_percent_pool_is_not_workload(self):
        value = report_capacity.memory_utilization(
            meminfo(MemAvailable=54 * 1024 * 1024, HugePages_Total=3072, HugePages_Free=3072),
            3072, 27648,
        )
        self.assertEqual(value, 6.25)

    def test_shared_pool_and_dynamic_pages_share_one_capacity_budget(self):
        value = report_capacity.memory_utilization(
            meminfo(HugePages_Total=24576, HugePages_Free=4096, HugePages_Rsvd=4096),
            3072, 27648,
        )
        self.assertEqual(value, 80)

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


class CommitmentUtilizationTests(unittest.TestCase):
    def utilization(self, **overrides):
        capacity = {
            "memory_limit_mib": 32768,
            "sandbox_limit": 8,
            "hugepage_headroom_mib": 2048,
            "memory_committed_mib": 0,
            "sandboxes_committed": 0,
        }
        capacity.update(overrides)
        return report_capacity.capacity_utilization(
            # 64 GiB worker, 50% of eligible RAM preallocated. No guest has
            # faulted or reserved a single page, as with lazy MAP_NORESERVE.
            meminfo(MemTotal=64 * 1024 * 1024, MemAvailable=30 * 1024 * 1024,
                    HugePages_Total=15360, HugePages_Free=15360),
            15360, capacity,
        )

    def test_six_lazy_four_gib_guests_trigger_scale_out(self):
        self.assertEqual(self.utilization(memory_committed_mib=24576,
                                         sandboxes_committed=6), 75)

    def test_eight_guests_use_the_full_budget(self):
        self.assertEqual(self.utilization(memory_committed_mib=32768,
                                         sandboxes_committed=8), 100)

    def test_large_guests_scale_on_bytes_before_slots(self):
        self.assertEqual(self.utilization(memory_committed_mib=24576,
                                         sandboxes_committed=3), 75)

    def test_small_guests_scale_on_slots_before_bytes(self):
        self.assertEqual(self.utilization(memory_committed_mib=6144,
                                         sandboxes_committed=6), 75)

    def test_idle_pool_does_not_trigger_scale_out(self):
        self.assertEqual(self.utilization(), 6.25)

    def test_invalid_capacity_does_not_become_idle(self):
        for field, value in [("sandbox_limit", 0), ("memory_limit_mib", 0),
                             ("memory_committed_mib", -1), ("sandboxes_committed", "6"),
                             ("hugepage_headroom_mib", 65536)]:
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                self.utilization(**{field: value})
        with self.assertRaises(KeyError):
            report_capacity.capacity_utilization(meminfo(), 31744, {})


if __name__ == "__main__":
    unittest.main()
