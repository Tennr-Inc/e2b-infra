package commands

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestCopyScratchPaths(t *testing.T) {
	t.Parallel()

	t.Run("uses rootfs-backed scratch instead of tmpfs", func(t *testing.T) {
		t.Parallel()

		scratch, archive, unpack, err := copyScratchPaths("abc123")
		require.NoError(t, err)
		assert.Equal(t, "/var/lib/e2b/template-build/abc123", scratch)
		assert.Equal(t, "/var/lib/e2b/template-build/abc123/layer.tar.gz", archive)
		assert.Equal(t, "/var/lib/e2b/template-build/abc123/unpack", unpack)
		assert.NotContains(t, scratch, "/tmp/")
	})

	for _, filesHash := range []string{".", "..", "../escape", "nested/hash", `nested\\hash`} {
		filesHash := filesHash
		t.Run("rejects_"+strings.NewReplacer("/", "_", `\\`, "_").Replace(filesHash), func(t *testing.T) {
			t.Parallel()

			_, _, _, err := copyScratchPaths(filesHash)
			require.ErrorContains(t, err, "single path component")
		})
	}
}
