package tests

import (
	"database/sql"
	"os"
	"path/filepath"
	"testing"

	"github.com/google/uuid"
	"github.com/pressly/goose/v3"
	"github.com/pressly/goose/v3/database"
	"github.com/stretchr/testify/require"

	"github.com/e2b-dev/infra/packages/db/pkg/testutils"
)

func TestBaseSandboxLifetimeMigration(t *testing.T) {
	t.Parallel()

	db := testutils.SetupDatabase(t)
	ctx := t.Context()
	sqlDB, err := sql.Open("pgx", db.ConnStr())
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, sqlDB.Close()) })

	store, err := database.NewStore(goose.DialectPostgres, testutils.TrackingTable)
	require.NoError(t, err)
	migrations, err := goose.NewProvider("", sqlDB,
		os.DirFS(filepath.Join("..", "..", "migrations")), goose.WithStore(store))
	require.NoError(t, err)

	const previousVersion = 20260831170000
	const lifetimeVersion = 20260918220000
	_, err = migrations.DownTo(ctx, previousVersion)
	require.NoError(t, err)

	// Reproduce the deployed one-hour base tier before applying the migration.
	_, err = sqlDB.ExecContext(ctx, `
		UPDATE public.tiers SET max_length_hours = 1 WHERE id = 'base_v1';
		INSERT INTO public.tiers (
			id, name, disk_mb, concurrent_instances, max_length_hours,
			default_free_disk_size_mb, max_disk_size_mb
		) VALUES ('lifetime-other', 'Other tier', 10000, 7, 2, 8000, 20000);
	`)
	require.NoError(t, err)

	cases := []struct {
		name     string
		tier     string
		override int64
		want     int64
		teamID   uuid.UUID
	}{
		{name: "base-default", tier: "base_v1", want: 24},
		{name: "base-override", tier: "base_v1", override: 1, want: 24},
		{name: "base-longer", tier: "base_v1", override: 48, want: 48},
		{name: "other-default", tier: "lifetime-other", want: 2},
		{name: "other-override", tier: "lifetime-other", override: 3, want: 3},
	}
	for i := range cases {
		tc := &cases[i]
		tc.teamID = seedTeam(t, sqlDB, tc.name)
		_, err = sqlDB.ExecContext(ctx, `UPDATE public.teams SET tier = $1 WHERE id = $2`, tc.tier, tc.teamID)
		require.NoError(t, err)
		seedAddon(t, sqlDB, tc.teamID)
		if tc.override == 0 {
			continue
		}

		_, err = sqlDB.ExecContext(ctx, `
			INSERT INTO public.project_limits (
				team_id, max_length_hours, concurrent_sandboxes, concurrent_template_builds,
				max_vcpu, max_ram_mb, disk_mb, events_ttl_days,
				default_free_disk_size_mb, max_disk_size_mb
			)
			SELECT id, $2, concurrent_sandboxes, concurrent_template_builds,
				max_vcpu, max_ram_mb, disk_mb, events_ttl_days,
				default_free_disk_size_mb, max_disk_size_mb
			FROM public.team_limits WHERE id = $1
		`, tc.teamID, tc.override)
		require.NoError(t, err)
	}

	const unrelatedLimitsQuery = `
		SELECT jsonb_agg(to_jsonb(limits) - 'max_length_hours' ORDER BY id)::text
		FROM public.team_limits limits
	`
	var before, after string
	require.NoError(t, sqlDB.QueryRowContext(ctx, unrelatedLimitsQuery).Scan(&before))

	_, err = migrations.UpTo(ctx, lifetimeVersion)
	require.NoError(t, err)
	for _, tc := range cases {
		var hours int64
		err = sqlDB.QueryRowContext(ctx, `SELECT max_length_hours FROM public.team_limits WHERE id = $1`, tc.teamID).Scan(&hours)
		require.NoError(t, err)
		require.Equal(t, tc.want, hours, tc.name)
	}
	require.NoError(t, sqlDB.QueryRowContext(ctx, unrelatedLimitsQuery).Scan(&after))
	require.JSONEq(t, before, after, "all other effective limits, including add-ons, must be preserved")

	const allLimitsQuery = `SELECT jsonb_agg(to_jsonb(limits) ORDER BY id)::text FROM public.team_limits limits`
	require.NoError(t, sqlDB.QueryRowContext(ctx, allLimitsQuery).Scan(&before))
	_, err = migrations.DownTo(ctx, previousVersion)
	require.NoError(t, err)
	require.NoError(t, sqlDB.QueryRowContext(ctx, allLimitsQuery).Scan(&after))
	require.JSONEq(t, before, after, "rollback must not guess the previous lifetimes")

	// Reapplying must preserve an operator's longer base-tier lifetime too.
	_, err = sqlDB.ExecContext(ctx, `UPDATE public.tiers SET max_length_hours = 72 WHERE id = 'base_v1'`)
	require.NoError(t, err)
	require.NoError(t, sqlDB.QueryRowContext(ctx, allLimitsQuery).Scan(&before))
	_, err = migrations.UpTo(ctx, lifetimeVersion)
	require.NoError(t, err)
	require.NoError(t, sqlDB.QueryRowContext(ctx, allLimitsQuery).Scan(&after))
	require.JSONEq(t, before, after)
}
