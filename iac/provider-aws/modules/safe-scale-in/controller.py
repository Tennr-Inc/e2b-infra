"""Conservative, single-candidate retirement. AWS target tracking stays scale-out only.

Each invocation advances at most one step. SSM command IDs and the candidate are
persisted before any subsequent step, so retries never pick a second victim.
A node must seal its durable admission fence before AWS may terminate it.
"""
import datetime as dt
import json
import math
import os
import time

import boto3

# Fleet averages from before a removal used a larger denominator. Wait for the
# entire 30-minute metric window, its two-minute lag, and bucket alignment to
# clear before choosing another host. Otherwise several quick removals could
# repeatedly reuse deceptively low historical averages.
SCALE_IN_COOLDOWN_SECONDS = 35 * 60


class Controller:
    def __init__(self, asg, table, document, minimum=2, dry_run=True):
        self.asg = asg
        self.table = table
        self.document = document
        self.minimum = minimum
        self.dry_run = dry_run
        self.aws = boto3.client("autoscaling")
        self.cw = boto3.client("cloudwatch")
        self.ssm = boto3.client("ssm")
        self.db = boto3.resource("dynamodb").Table(table)

    def group(self):
        groups = self.aws.describe_auto_scaling_groups(AutoScalingGroupNames=[self.asg])["AutoScalingGroups"]
        if len(groups) != 1:
            raise RuntimeError("expected exactly one configured ASG")
        return groups[0]

    def save(self, state):
        self.db.put_item(Item={"id": self.asg, "state": json.dumps(state)})

    def clear(self):
        self.db.delete_item(Key={"id": self.asg})

    def emit(self, event, **fields):
        print(json.dumps({"event": event, "asg": self.asg, **fields}))

    def command(self, ids, action):
        result = self.ssm.send_command(
            InstanceIds=ids, DocumentName=self.document,
            Parameters={"action": [action]}, TimeoutSeconds=60,
            MaxConcurrency="10", MaxErrors="0",
        )
        return result["Command"]["CommandId"]

    def results(self, command, ids, allow_unsupported=False):
        results = {}
        for instance in ids:
            try:
                result = self.ssm.get_command_invocation(CommandId=command, InstanceId=instance)
            except self.ssm.exceptions.InvocationDoesNotExist:
                return None
            status = result["Status"]
            if status in ("Pending", "InProgress", "Delayed", "Cancelling"):
                return None
            if status != "Success":
                raise RuntimeError(f"SSM {status} for {instance}; no termination authorized")
            result = json.loads(result["StandardOutputContent"])
            if allow_unsupported and result == {"version": 0}:
                continue
            validate_node(result)
            results[instance] = result
        return results

    def headroom(self, group, reporting_nodes):
        """Require complete, fresh minute samples and a 30-minute quiet period.

        CPU and admission/backing pressure are both checked. Missing data never
        counts as idle. The projected fleet load remains below 60% after removal.
        """
        end = dt.datetime.now(dt.timezone.utc).replace(second=0, microsecond=0) - dt.timedelta(minutes=2)
        start = end - dt.timedelta(minutes=30)
        count = len(group["Instances"])
        if count <= max(self.minimum, group["MinSize"]):
            return False
        for namespace, metric in (("AWS/EC2", "CPUUtilization"), ("E2B/Capacity", "SandboxCapacityUtilization")):
            # EC2 basic monitoring may publish only every five minutes. Use
            # five-minute buckets for both, with at least one sample per node.
            response = self.cw.get_metric_statistics(
                Namespace=namespace, MetricName=metric,
                Dimensions=[{"Name": "AutoScalingGroupName", "Value": self.asg}],
                StartTime=start, EndTime=end, Period=300,
                Statistics=["Average", "SampleCount"],
            )
            points = response["Datapoints"]
            if len(points) != 6:
                return False
            for point in points:
                value = point["Average"]
                if not math.isfinite(value) or not 0 <= value <= 100:
                    return False
                required_samples = reporting_nodes * (4.8 if namespace == "E2B/Capacity" else 1)
                if point["SampleCount"] < required_samples or value > 45 or value * count / (count - 1) > 60:
                    return False
        return True

    def stable(self, group, desired=None):
        nodes = group["Instances"]
        return (len(nodes) == group["DesiredCapacity"]
                and (desired is None or desired == group["DesiredCapacity"])
                and all(n["LifecycleState"] == "InService" and n["HealthStatus"] == "Healthy"
                        and n["ProtectedFromScaleIn"] for n in nodes)
                and not group["SuspendedProcesses"])

    def step(self):
        group = self.group()
        item = self.db.get_item(Key={"id": self.asg}, ConsistentRead=True).get("Item")
        state = json.loads(item["state"]) if item else None
        ids = [n["InstanceId"] for n in group["Instances"]]
        if not state:
            if not self.stable(group) or not self.headroom(group, len(ids)):
                self.emit("scale_in.waiting_for_headroom")
                return
            command = self.command(ids, "status")
            self.save({"phase": "observe", "ids": ids, "desired": group["DesiredCapacity"], "command": command, "started": time.time()})
            return

        phase = state["phase"]
        candidate = state.get("candidate")
        if candidate and candidate not in ids:
            # Includes a successful termination whose response was lost. Never
            # compensate by terminating a different node or decrementing twice.
            self.emit("scale_in.candidate_gone", instance=candidate)
            self.save({"phase": "cooldown", "until": time.time() + SCALE_IN_COOLDOWN_SECONDS})
            return
        if phase == "cooldown":
            if time.time() < state["until"]:
                self.emit("scale_in.waiting_for_fresh_fleet_metrics")
            else:
                self.clear()
            return
        if phase == "observe":
            if set(ids) != set(state["ids"]) or not self.stable(group, state["desired"]):
                self.clear()
                return
            nodes = self.results(state["command"], ids, allow_unsupported=True)
            if nodes is None:
                return
            candidates = [(v["sandboxes_committed"], k) for k, v in nodes.items()
                          if v["verified"] and not v["journal_error"] and v["mode"] == "active"
                          and v["pending_uploads"] == 0]
            if not candidates or not self.headroom(group, len(ids)):
                self.emit("scale_in.no_safe_candidate")
                self.clear()
                return
            _, candidate = min(candidates)
            self.emit("scale_in.candidate", instance=candidate, dry_run=self.dry_run)
            if self.dry_run:
                self.clear()
                return
            # Persist intent before changing the host. A timed-out SSM request
            # can be reconciled by status on the next tick.
            self.save({**state, "phase": "drain", "candidate": candidate, "started": time.time()})
            return

        if self.dry_run and phase not in ("cancel", "terminate"):
            self.emit("scale_in.mutations_disabled", instance=candidate)
            return

        if phase == "drain":
            # Idempotent across a lost SendCommand response.
            command = self.command([candidate], "drain")
            self.save({**state, "phase": "poll", "command": command})
            return
        if phase == "poll":
            nodes = self.results(state["command"], [candidate])
            if nodes is None:
                return
            node = nodes[candidate]
            if node["mode"] == "sealed":
                self.save({**state, "phase": "terminate"})
                return
            # Leave ongoing work alone, including long-lived commands. If load
            # returns or a drain takes too long, reopen admission instead.
            if (not self.stable(group, state["desired"])
                    or not self.headroom(group, max(1, len(ids) - 1))
                    or time.time() - state["started"] > 6 * 3600):
                command = self.command([candidate], "cancel")
                self.save({**state, "phase": "cancel", "command": command})
                return
            if node["ready"]:
                command = self.command([candidate], "seal")
            else:
                command = self.command([candidate], "status")
            self.save({**state, "command": command})
            return
        if phase == "cancel":
            result = self.results(state["command"], [candidate])
            if result is not None and result[candidate]["mode"] == "active":
                self.emit("scale_in.cancelled", instance=candidate)
                self.clear()
            return
        if phase == "terminate":
            # A seal proof is permanent; no timeout ever becomes permission to
            # kill a running VM. Keep protection on every other node.
            result = self.results(state["command"], [candidate])
            if result is None:
                return
            node = result[candidate]
            if not (node["ready"] and node["mode"] == "sealed"):
                raise RuntimeError("missing durable seal proof")
            # Once sealed, this host cannot reopen. A later scale-out must not
            # strand it forever at the old desired count: require the current
            # fleet to stabilize and pass headroom checks before retiring it.
            if not self.stable(group) or not self.headroom(group, max(1, len(ids) - 1)):
                self.emit("scale_in.sealed_waiting_for_headroom", instance=candidate)
                return
            if self.dry_run:
                self.emit("scale_in.termination_disabled", instance=candidate)
                return
            # This API explicitly removes the named instance, even with scale-in
            # protection. Do not lower desired capacity separately (AWS could
            # choose a different host). On uncertainty retain this same intent.
            self.aws.terminate_instance_in_auto_scaling_group(InstanceId=candidate, ShouldDecrementDesiredCapacity=True)
            self.emit("scale_in.termination_requested", instance=candidate)
            return
        raise RuntimeError(f"unknown controller phase {phase}")


def validate_node(node):
    if node.get("version") != 1 or node.get("mode") not in ("active", "draining", "sealed"):
        raise ValueError("unsupported retirement status")
    for key in ("verified", "journal_error", "ready"):
        if type(node.get(key)) is not bool:
            raise ValueError(f"invalid {key}")
    for key in ("pending_uploads", "sandboxes_committed", "memory_committed_mib"):
        if type(node.get(key)) is not int or node[key] < 0:
            raise ValueError(f"invalid {key}")
    if node["ready"] and (not node["verified"] or node["journal_error"] or node["mode"] == "active"
                          or node["pending_uploads"] or node["sandboxes_committed"] or node["memory_committed_mib"]):
        raise ValueError("inconsistent retirement proof")


def handler(event, context):
    Controller(os.environ["ASG_NAME"], os.environ["STATE_TABLE"], os.environ["SSM_DOCUMENT"],
               int(os.environ.get("MINIMUM_NODES", "2")), os.environ.get("DRY_RUN", "true") != "false").step()
