package tests

import (
	"database/sql"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/e2b-dev/infra/packages/db/pkg/testutils"
)

func TestBaseTierProvidesLargeTemplateBuildCapacity(t *testing.T) {
	t.Parallel()

	db := testutils.SetupDatabase(t)
	sqlDB, err := sql.Open("pgx", db.ConnStr())
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, sqlDB.Close()) })

	teamID := seedTeam(t, sqlDB, "large-template-build")

	var maxRamMB, legacyDiskMB, defaultFreeDiskMB, maxDiskMB int64
	err = sqlDB.QueryRowContext(t.Context(), `
		SELECT max_ram_mb, disk_mb, default_free_disk_size_mb, max_disk_size_mb
		FROM public.team_limits
		WHERE id = $1
	`, teamID).Scan(&maxRamMB, &legacyDiskMB, &defaultFreeDiskMB, &maxDiskMB)
	require.NoError(t, err)

	require.GreaterOrEqual(t, maxRamMB, int64(24_576))
	require.GreaterOrEqual(t, legacyDiskMB, int64(15_360))
	require.GreaterOrEqual(t, defaultFreeDiskMB, int64(15_360))
	require.GreaterOrEqual(t, maxDiskMB, int64(51_200))
}
