package types

import (
	"testing"

	"github.com/stretchr/testify/assert"

	authqueries "github.com/e2b-dev/infra/packages/db/pkg/auth/queries"
)

func TestNewTeamLimitsPreservesTemplateDiskEntitlements(t *testing.T) {
	t.Parallel()

	limits := newTeamLimits(&authqueries.TeamLimit{
		DiskMb:                512,
		DefaultFreeDiskSizeMb: 15_360,
		MaxDiskSizeMb:         51_200,
	})

	assert.Equal(t, int64(512), limits.DiskMb)
	assert.Equal(t, int64(15_360), limits.DefaultFreeDiskSizeMb)
	assert.Equal(t, int64(51_200), limits.MaxDiskSizeMb)
}
