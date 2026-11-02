# Safe AWS sandbox scale-in

The AWS target-tracking policies remain **scale-out only**, and instances remain
protected from ordinary ASG scale-in. A separate controller retires one named
sandbox host at a time. It never forces a sandbox to pause, kills a running
sandbox, or treats a timeout as permission to terminate a host.

## Safety protocol

1. Require a stable ASG and 30 minutes of low CPU and sandbox-capacity pressure.
   Keep at least two hosts by default, or the ASG minimum if higher. Fleet pressure
   must remain below the controller's conservative thresholds after removal.
2. Inspect hosts through a fixed SSM document. Old binaries, missing telemetry,
   malformed responses, and unknown snapshot history do not authorize removal.
3. Persist the candidate in DynamoDB before requesting its drain. Only one Lambda
   invocation runs at a time. Existing target tracking can continue scaling out.
4. The orchestrator persists a drain fence and rejects new capacity reservations.
   This uses the same lock as create/resume admission, including starts and
   teardown. Its discovery status becomes standby; running commands keep running.
5. Wait for natural sandbox completion and successful resource cleanup. A new
   snapshot obligation is fsynced before snapshot creation and cleared only after
   its complete remote upload succeeds. Failed and interrupted attempts remain in
   the journal across restarts. An unresolved obligation blocks removal indefinitely.
6. If demand returns, capacity changes, or a drain exceeds six hours, cancel the
   unsealed drain. This restores admission without interrupting existing work.
7. Seal only when commitments and pending uploads are both zero and snapshot
   history is verified. Sealing permanently fences admission through the API and
   survives orchestrator restarts. It cannot be cancelled through the endpoint.
8. Recheck ASG capacity and headroom, then call
   `TerminateInstanceInAutoScalingGroup` for that exact instance with desired
   capacity decrement enabled. The controller does not separately reduce desired
   capacity or remove protection from other nodes. Persist the candidate until it
   disappears, including after an uncertain AWS response.
9. Wait 35 minutes after confirmed removal before considering another candidate.
   This replaces the full metric history with samples from the smaller fleet;
   repeated removals must not reuse averages collected across more nodes.

The proof covers sandbox data owned by the orchestrator. It does not turn EC2
hardware failures, manual forced termination, or arbitrary binary downgrades into
safe operations. Once enrolled, every binary that can start on that host must
honor the journal and fence; use immutable artifact keys and retain the guard on
rollback. Do not mix a non-journaling binary into an enrolled host's history.

## Deployment

The implementation is opt-in:

```sh
CLIENT_SAFE_SCALE_IN_ENABLED=true
CLIENT_RETIREMENT_HISTORY_ENABLED=false
CLIENT_SCALE_IN_DRY_RUN=true
CLIENT_SCALE_IN_MINIMUM_NODES=2
```

The default for `CLIENT_SAFE_SCALE_IN_ENABLED` is false. Dry-run is true by
default. Both the normal Terraform configuration and the Makefile forward these
settings. Native ASG protection stays enabled even after dry-run is disabled.

Deploy and test the journal-capable orchestrator **before** enabling fresh-node
journal initialization in the launch template. The separate
`CLIENT_RETIREMENT_HISTORY_ENABLED` flag defaults to false, so deploying SSM and
the controller cannot accidentally verify a fresh node running an older binary.
Enable it only once the jobs eligible for new workers all honor the journal. Do not roll the entire live fleet
by replacing its shared artifact or restarting all allocations. Validate a new
isolated node first, including live commands through drain/cancel, refused
create/resume after fencing, pending upload refusal, and restart persistence.

The controller uses EventBridge, Lambda, DynamoDB, and an SSM Command document.
Worker bootstrap installs the Amazon SSM agent and grants its standard managed
instance permissions. The controller's own role can invoke only the retirement
SSM document on the designated worker Name tag; it cannot run arbitrary shell
commands. Its termination permission is scoped to the sandbox ASG. Installing
SSM on an existing worker does not require restarting its orchestrator.

For the existing AWS pool, `CLIENT_RETIREMENT_NODE_IDS` selects exact Nomad node
UUIDs for a separate `orchestrator-<environment>-retirement` job. The original
job excludes those nodes while retaining its artifact on every other worker.
`CLIENT_RETIREMENT_ARTIFACT_KEY` must identify the immutable, validated S3 binary.
Add a node only after standby has propagated, its natural drain is complete,
and its legacy cache and snapshot dependencies have passed the durability audit.
Review the Nomad plan: only that node may have a destructive allocation update.
Keep these settings in the deployment environment so later applies retain the
split. Without a separate fresh-worker pool, new workers continue using the
original job; leave fresh-history initialization off while that job uses the old
binary. If long-running legacy sessions remain, set `CLIENT_RETIREMENT_NODE_POOL` to a
new pool such as `retirement-ready`. Terraform registers the immutable fresh-worker
job before updating the ASG launch template. Only future instances join that
pool; existing allocations stay in place. Once this job is registered, fresh-disk
history initialization can be enabled without trusting legacy binaries. API
service discovery spans both pools. Verify that every `orchestrator` service
registration has a nonempty address, and confirm actual placement on the new
pool before allowing scale-in. Host health alone does not establish API
reachability. Continue auditing and migrating old workers
as they empty; a busy legacy host remains protected indefinitely.

Alternatively, once every legacy allocation has moved, set `CLIENT_ORCHESTRATOR_ARTIFACT_KEY`
to the same immutable key. The original job then serves fresh workers with the
validated runtime, while enrolled nodes keep their separate job. Verify the
scheduler plan has no destructive allocation updates before applying this
promotion, then enable `CLIENT_RETIREMENT_HISTORY_ENABLED` for future blank disks.
Do not revert either runtime job to a binary that ignores the journal.

Observe a candidate in dry-run, review actual capacity and snapshot obligations,
then set `CLIENT_SCALE_IN_DRY_RUN=false`. Retire one verified host and validate
resume from its uploaded snapshot on a surviving host before broad enrollment.
There is no automatic reduction to the warm floor: observed demand and successful
drains determine how far the fleet can shrink.

## Existing hosts and failed uploads

`/orchestrator/retirement.json` is stored on the same NVMe filesystem as local
snapshots. The initializer marks history verified **only immediately after it
formats a fresh instance-store disk**. It never formats an occupied disk or
infers verification from an empty cache, a zero VM count, process exit, or a reboot.

An existing disk without a journal starts with `verified: false`. The new runtime
records subsequent snapshot obligations but cannot prove earlier uploads. Such a
host remains ineligible until its legacy snapshots and dependencies have been
audited in durable storage. There is deliberately no HTTP action that bypasses
this audit or clears failed uploads. Do not flip `verified` merely to make the
controller proceed. An operator must reconcile durable snapshot artifacts and
unfinished local work before migrating the host; copying the journal from another
host is invalid.

A failed snapshot attempt can leave an obligation even if no resumable snapshot
was published. This conservatism is intentional: review the build and its storage
outcome before reconciling the journal. Never delete pending entries because they
are old. Journal write errors block retirement for the current process. Corrupt
journals prevent startup, preserving the data for investigation.

## Observation and rollback

The Lambda's log group is `/aws/lambda/<prefix>safe-scale-in`. Events identify the
candidate, insufficient headroom, cancelled drains, and requested termination.
An AWS/Lambda Errors alarm identifies failures requiring investigation. No external
notification destination is configured automatically; connect this alarm to the
existing operations notification path when deploying.

The DynamoDB item keyed by the ASG name holds the active phase, candidate, and SSM
command ID. Never delete an active candidate's state without checking its host.
An SSM error or missing proof blocks progress; investigate and reconcile the
command before clearing state. A sealed host that cannot yet be removed remains
sealed and protected, rather than reopening and invalidating the proof.

To stop new scale-in actions, set dry-run true or disable the EventBridge rule.
This does not reopen an already draining/sealed node. An unsealed drain can be
cancelled through the fixed SSM document's `cancel` action after checking that no
seal command is still in flight. A sealed node requires completion of the safe
retirement or a separate audited recovery. If scale-out occurs after sealing, the
controller waits for the current fleet to stabilize and pass its capacity checks;
it does not remain pinned to the earlier desired count. Never restore an older orchestrator
that ignores the persistent fence.

## Verification

The capacity tests exercise concurrent admission/drain, pending uploads across
restarts, failed journal writes, retained teardown leases, irreversible sealing,
loopback-only control, and cancellation during process shutdown. Controller tests
cover missing/inconsistent proofs, lost AWS responses, new scale-out, dry-run,
load-triggered cancellation, unsupported history, and the capacity floor. Mocked
Terraform tests verify native scale-in and protection stay unchanged with the
controller enabled. Real AWS/SSM and sandbox pause/resume validation are separate
rollout requirements; passing unit tests does not establish those live results.


## Production-account canary: 2026-11-02

The isolated canary used the production AMI, `m8id.4xlarge`, the production
artifact buckets, and a separate Nomad pool with no API service registration.
The validated orchestrator SHA-256 was
`a271fd7f28cdf9fe68254be00b0b2a4226aa3fa71e4747341324f291a96f027e`.

Observed results:

- An existing 20-second command completed through drain. New sandbox admission
  returned `ResourceExhausted`, and sealing an occupied node returned HTTP 409.
- Cancelling an unsealed drain restored admission. A sealed fence survived a
  process restart and refused cancellation with HTTP 409.
- After pause released the VM, a pending snapshot upload still blocked sealing
  with HTTP 409. The journal cleared only when upload completed.
- After terminating the original host, a fresh host resumed the uploaded snapshot.
  A 128 MiB random file retained its SHA-256, the marker and counter survived,
  and a pre-pause background process resumed advancing its heartbeat.
- The first boot exposed a preinstalled Snap SSM agent conflicting with Debian
  installation. The installer now reuses either existing service. A second fresh
  host completed cloud-init with the corrected installer.

Both temporary canary instances were terminated and the isolated runtime job was
removed after their journals reported sealed, empty, and fully uploaded. The
controller was deployed with `DRY_RUN=true`; the production ASG remained at ten
protected workers. Live retirement of a production worker is a separate rollout
step and is not established by these canary results.


## Staged production rollout: 2026-11-02

After the canary, five existing workers were enrolled individually. Each was
first put in standby and allowed to finish its sandboxes. While the old process
was still available, the operator audited cached and node-origin snapshot builds,
including inherited rootfs/memory dependencies, against S3. Only then was the
empty worker stopped, its verified journal initialized, and its runtime replaced.
Nomad plans showed one old allocation removed and one new allocation placed,
without restarting previously enrolled workers. Seven snapshots produced by the
first enrolled production worker also passed the durability audit.

One pre-existing failed build had no artifacts in S3, its local directory, open
file descriptors, or the old process's peer-cache API. It was explicitly recorded
as a historical failure with no host-owned artifacts; it was not marked uploaded,
and no database records were changed. Failed builds are not generally exempt
from auditing.

The controller is active with a temporary minimum of nine workers. A production
retirement has not yet been observed. Missing capacity samples during manual
standby correctly block selection; the quiet-window requirement has not been
bypassed. During migration, reduced available capacity triggered native scale-out
from ten to seventeen workers. The remaining manual drains were cancelled,
restoring admission without interrupting their existing sessions.

The launch template now directs future workers to `retirement-ready`, with a
separate job using the same immutable runtime and fresh-disk journal initialization.
Existing instances were not replaced. Busy legacy workers retain their original
runtime and scale-in protection until they can be audited safely.

The seven automatically added workers joined the fresh pool with verified
journals. Together with the five migrated workers, twelve workers are eligible
for safe retirement; five legacy workers remain protected and ineligible. All
seventeen workers subsequently reported healthy capacity, with no pending uploads
or journal errors on the twelve enrolled workers. These counts describe the
rollout observation, not fixed deployment capacity.


The placement check exposed a pre-existing jobspec error: numeric service ports
registered empty addresses. Default-pool discovery masked it for old workers,
but the API ignored the fresh pool. Retirement was returned to dry-run while the
services were changed to named network ports. Review the Nomad plan for zero
destructive updates; service registration can be corrected in place without
restarting the runtime. Do not count a new pool as available capacity merely
because its hosts and local health endpoints are healthy.

The correction was applied to all three production jobs. Nomad planned seven,
five, and five in-place service updates respectively, with zero destructive
updates; running task start times and restart counts were unchanged. Both service
catalogs then contained seventeen nonempty addresses. Real sandbox placements
were observed on three fresh-pool workers before retirement was re-enabled.
