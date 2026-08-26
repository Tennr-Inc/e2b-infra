-- +goose Up
-- +goose StatementBegin

-- Self-hosted builds commonly copy dependency stores that are several GiB
-- compressed and larger once expanded. Give base projects enough RAM to opt
-- into a larger builder and enough rootfs headroom to stage and install those
-- dependencies. GREATEST preserves any operator-configured value above these
-- floors.
UPDATE public.tiers
SET max_ram_mb = GREATEST(max_ram_mb, 24576),
    disk_mb = GREATEST(disk_mb, 15360),
    default_free_disk_size_mb = GREATEST(default_free_disk_size_mb, 15360),
    max_disk_size_mb = GREATEST(max_disk_size_mb, 51200)
WHERE id = 'base_v1';

-- An explicit project row takes precedence over its tier in team_limits. Raise
-- existing base-tier overrides too so the effective value seen by the API is
-- never left at the old 8 GiB RAM / sub-15 GiB disk settings.
UPDATE public.project_limits AS limits
SET max_ram_mb = GREATEST(limits.max_ram_mb, 24576),
    disk_mb = GREATEST(limits.disk_mb, 15360),
    default_free_disk_size_mb = GREATEST(limits.default_free_disk_size_mb, 15360),
    max_disk_size_mb = GREATEST(limits.max_disk_size_mb, 51200),
    updated_at = now()
FROM public.teams AS teams
WHERE limits.team_id = teams.id
  AND teams.tier = 'base_v1';

-- +goose StatementEnd

-- +goose Down
-- Capacity floors are intentionally not reduced on rollback. Existing builds
-- and templates may rely on the larger values, and the prior operator-specific
-- values cannot be reconstructed after a GREATEST update.
SELECT 1;
