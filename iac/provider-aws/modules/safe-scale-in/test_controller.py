import copy
import json
import unittest
from unittest.mock import Mock, patch

from controller import Controller, SCALE_IN_COOLDOWN_SECONDS, validate_node


def node(**updates):
    result = dict(version=1, verified=True, journal_error=False, ready=False,
                  mode="active", pending_uploads=0, sandboxes_committed=0, memory_committed_mib=0)
    result.update(updates)
    return result


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.c = Controller.__new__(Controller)
        self.c.asg = "sandbox-only"
        self.c.minimum = 2
        self.c.dry_run = False
        self.c.aws = Mock()
        self.c.db = Mock()
        self.c.cw = Mock()
        self.c.command = Mock(return_value="command")
        self.c.results = Mock(return_value={"a": node(mode="sealed", ready=True)})
        self.c.emit = Mock()
        self.c.save = Mock()
        self.c.clear = Mock()
        self.c.headroom = Mock(return_value=True)
        self.group = dict(MinSize=1, DesiredCapacity=3, SuspendedProcesses=[], Instances=[
            dict(InstanceId=i, LifecycleState="InService", HealthStatus="Healthy", ProtectedFromScaleIn=True)
            for i in ["a", "b", "c"]])
        self.c.group = Mock(return_value=self.group)
        self.state = dict(phase="terminate", candidate="a", ids=["a", "b", "c"], desired=3, command="command", started=100)

    def run_state(self):
        self.c.db.get_item.return_value = {"Item": {"state": json.dumps(self.state)}}
        self.c.step()

    def test_only_named_sealed_node_is_terminated(self):
        self.run_state()
        self.c.aws.terminate_instance_in_auto_scaling_group.assert_called_once_with(InstanceId="a", ShouldDecrementDesiredCapacity=True)
        self.c.clear.assert_not_called()  # intent retained until AWS confirms removal

    def test_lost_termination_response_cannot_select_another_victim(self):
        self.group["Instances"] = self.group["Instances"][1:]
        self.group["DesiredCapacity"] = 2
        with patch("controller.time.time", return_value=1000):
            self.run_state()
        self.c.aws.terminate_instance_in_auto_scaling_group.assert_not_called()
        self.c.clear.assert_not_called()
        self.c.save.assert_called_once_with({"phase": "cooldown", "until": 1000 + SCALE_IN_COOLDOWN_SECONDS})

    def test_cooldown_prevents_reusing_larger_fleet_averages(self):
        self.state = {"phase": "cooldown", "until": 3100}
        with patch("controller.time.time", return_value=3099):
            self.run_state()
        self.c.command.assert_not_called()
        self.c.headroom.assert_not_called()
        self.c.clear.assert_not_called()
        self.c.aws.terminate_instance_in_auto_scaling_group.assert_not_called()

    def test_expired_cooldown_requires_new_observation(self):
        self.state = {"phase": "cooldown", "until": 3100}
        with patch("controller.time.time", return_value=3100):
            self.run_state()
        self.c.clear.assert_called_once()
        self.c.command.assert_not_called()
        self.c.aws.terminate_instance_in_auto_scaling_group.assert_not_called()

    def test_never_terminate_without_durable_proof(self):
        for status in (node(), node(mode="draining"), node(mode="draining", pending_uploads=1),
                       node(mode="draining", sandboxes_committed=1)):
            self.c.results.return_value = {"a": status}
            with self.assertRaises(RuntimeError):
                self.run_state()
        self.c.aws.terminate_instance_in_auto_scaling_group.assert_not_called()

    def test_new_scale_out_blocks_termination(self):
        self.group["DesiredCapacity"] = 4
        self.run_state()
        self.c.aws.terminate_instance_in_auto_scaling_group.assert_not_called()

    def test_dry_run_cannot_terminate_preexisting_candidate(self):
        self.c.dry_run = True
        self.run_state()
        self.c.aws.terminate_instance_in_auto_scaling_group.assert_not_called()

    def test_cancel_drain_when_demand_returns_without_touching_work(self):
        self.state["phase"] = "poll"
        self.c.results.return_value = {"a": node(mode="draining", sandboxes_committed=2, memory_committed_mib=8192)}
        self.c.headroom.return_value = False
        self.run_state()
        self.c.command.assert_called_once_with(["a"], "cancel")
        self.c.aws.terminate_instance_in_auto_scaling_group.assert_not_called()

    def test_pending_command_cannot_authorize_termination(self):
        self.c.results.return_value = None
        self.run_state()
        self.c.aws.terminate_instance_in_auto_scaling_group.assert_not_called()

    def test_inconsistent_or_missing_status_rejected(self):
        for status in ({}, node(ready=True), node(ready=True, mode="sealed", verified=False),
                       node(ready=True, mode="sealed", journal_error=True), node(pending_uploads=-1)):
            with self.assertRaises(ValueError):
                validate_node(status)

    def test_missing_metrics_and_floor_block_scale_in(self):
        c = self.c
        c.headroom = Controller.headroom.__get__(c)
        c.cw.get_metric_statistics.return_value = {"Datapoints": []}
        self.assertFalse(c.headroom(self.group, 3))
        points = [dict(Average=10, SampleCount=15) for _ in range(6)]
        c.cw.get_metric_statistics.return_value = {"Datapoints": points}
        self.assertTrue(c.headroom(self.group, 3))
        for point in points:
            point["Average"] = 50
        self.assertFalse(c.headroom(self.group, 3))
        group = copy.deepcopy(self.group)
        group["Instances"] = group["Instances"][:2]
        self.assertFalse(c.headroom(group, 2))

    def test_observe_does_not_drain_unverified_nodes(self):
        self.state["phase"] = "observe"
        self.c.results.return_value = {i: node(verified=False) for i in self.state["ids"]}
        self.run_state()
        self.c.command.assert_not_called()
        self.c.clear.assert_called_once()


if __name__ == "__main__":
    unittest.main()
