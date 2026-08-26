# 24-hour sandbox lifetime rollout

E2B enforces two bounds: the client's requested timeout and a maximum lifetime captured from
`public.team_limits.max_length_hours` when a runtime starts. Reconnecting can extend the timeout
only as far as the original start time plus that captured lifetime.

Migration `20260918220000_raise_base_sandbox_lifetime.sql` raises `base_v1.max_length_hours` and
existing base-tier `project_limits.max_length_hours` values below 24 to 24. It preserves longer
lifetimes, other tiers, and all RAM, disk, concurrency, and retention limits. The `team_limits`
view continues to prefer a project override over its tier. Future project-limit syncs still take
precedence: if a service manages those overrides, its desired lifetime must also be at least 24.

The companion Tennr change sets Tot's E2B adapter default and maximum requested timeout to
86,400,000 ms for creation, reconnection, and recreation from snapshots. Shorter explicit adapter
timeouts remain valid. Idle suspension, snapshots, kill-on-timeout, session grants, and command
credential expiry retain their existing behavior. Expiry itself does not create a snapshot.

## Deployment order

These are operator rollout instructions; preparing this change does not apply migrations or
deploy services.

1. Record the current tier, project override, and effective limits in the target environment.
   Use the read-only query below. In the production evidence from September 18, 2026,
   `Tennr production` (`9464bf05-3af4-4990-8215-1d4320ada4ca`) has tier `base_v1`, an effective
   one-hour lifetime, and no project override.
2. Publish and deploy the E2B API's matching `db-migrator` image using the
   [existing AWS release procedure](aws-private-shared.md). The API job's migrator prestart task
   must apply `20260918220000` successfully. No template rebuild, orchestrator change, or
   infrastructure resizing is required for the lifetime change.
3. Confirm the effective target-team lifetime is at least 24 and all unrelated limits match the
   recorded values. Allow the shared Redis auth cache to refresh before deploying Tot: entries
   expire after five minutes and reads can trigger refresh after one minute. Restarting API
   instances alone does not clear this shared cache. A successful fresh 24-hour allocation is
   the final check that admission sees the new limit.
4. Deploy the companion Tot Worker through its normal deployment procedure. Deploying Tot first
   causes its 24-hour create/connect requests to be rejected while the team limit remains one hour.
5. Create a fresh synthetic Tot session against the intended E2B team. Inspect its sandbox
   `startedAt` and `endAt`; they should be 24 hours apart with the default adapter timeout.
   Reconnect and verify that `endAt` never exceeds `startedAt + 24 hours`. If idle suspension
   happens first, a restore should allocate a new runtime with a fresh lifetime. Terminate the
   synthetic runtime when verification is complete.

Run this query through the approved database access path before and after migration:

```sql
SELECT teams.id,
       teams.name,
       teams.tier,
       tiers.max_length_hours AS tier_max_length_hours,
       project.max_length_hours AS project_max_length_hours,
       to_jsonb(limits) AS effective_limits
FROM public.teams AS teams
JOIN public.tiers AS tiers ON tiers.id = teams.tier
JOIN public.team_limits AS limits ON limits.id = teams.id
LEFT JOIN public.project_limits AS project ON project.team_id = teams.id
WHERE teams.id = '9464bf05-3af4-4990-8215-1d4320ada4ca';
```

## Existing sandboxes and rollback

A runtime started with a one-hour `MaxInstanceLength` keeps that bound after both deployments;
even a successful reconnect with a 24-hour request is clamped to its original one-hour deadline.
Allow active work to finish, or use Tot's normal idle/suspend path to persist a snapshot before
expiry. Restoring that snapshot creates a new runtime that captures the new limit. Do not kill
an existing runtime merely to adopt the longer lifetime: files and processes since its last
snapshot would be lost. A runtime that already expired cannot be revived by the limit change.

Rolling Tot back restores its one-hour request default for subsequent provider calls; it does
not retroactively rewrite existing runtime deadlines or E2B's captured limits. The migration's
Down is deliberately a no-op because prior operator-specific lifetimes are not recoverable.
If a reduction is required, roll Tot back first and use a reviewed forward migration based on
the recorded pre-rollout values. That reduction likewise applies to newly started runtimes,
not to the maximum lifetime already captured by running ones.
