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

The proof covers sandbox data owned by the orchestrator. It does not turn EC2
hardware failures, manual forced termination, or arbitrary binary downgrades into
safe operations. Once enrolled, every binary that can start on that host must
honor the journal and fence; use immutable artifact keys and retain the guard on
rollback. Do not mix a non-journaling binary into an enrolled host's history.

## Deployment

The implementation is opt-in:

```sh
CLIENT_SAFE_SCALE_IN_ENABLED=true
CLIENT_SCALE_IN_DRY_RUN=true
CLIENT_SCALE_IN_MINIMUM_NODES=2
```

The default for `CLIENT_SAFE_SCALE_IN_ENABLED` is false. Dry-run is true by
default. Both the normal Terraform configuration and the Makefile forward these
settings. Native ASG protection stays enabled even after dry-run is disabled.

Deploy and test the journal-capable orchestrator **before** enabling fresh-node
journal initialization in the launch template. Do not roll the entire live fleet
by replacing its shared artifact or restarting all allocations. Validate a new
isolated node first, including live commands through drain/cancel, refused
create/resume after fencing, pending upload refusal, and restart persistence.

The controller uses EventBridge, Lambda, DynamoDB, and an SSM Command document.
Worker bootstrap installs the Amazon SSM agent and grants its standard managed
instance permissions. The controller's own role can invoke only the retirement
SSM document on the designated worker Name tag; it cannot run arbitrary shell
commands. Its termination permission is scoped to the sandbox ASG. Installing
SSM on an existing worker does not require restarting its orchestrator.

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
retirement or a separate audited recovery. Never restore an older orchestrator
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
