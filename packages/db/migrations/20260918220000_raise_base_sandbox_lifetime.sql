-- +goose Up
-- +goose StatementBegin

-- Base projects support day-long sandbox executions. Preserve longer lifetimes
-- configured by operators and leave all other quota dimensions unchanged.
UPDATE public.tiers
SET max_length_hours = 24
WHERE id = 'base_v1'
  AND max_length_hours < 24;

-- Explicit project limits take precedence over the tier in team_limits.
UPDATE public.project_limits AS limits
SET max_length_hours = 24,
    updated_at = now()
FROM public.teams AS teams
WHERE limits.team_id = teams.id
  AND teams.tier = 'base_v1'
  AND limits.max_length_hours < 24;

-- +goose StatementEnd

-- +goose Down
-- Previous operator-specific lifetimes cannot be reconstructed. Reduce limits
-- only through a deliberate forward change; existing sandboxes retain the
-- lifetime captured when they started regardless of later limit changes.
SELECT 1;
