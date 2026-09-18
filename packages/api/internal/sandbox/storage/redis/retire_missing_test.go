package redis

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
	"github.com/stretchr/testify/require"

	"github.com/e2b-dev/infra/packages/api/internal/sandbox/sandboxtypes"
	redisutils "github.com/e2b-dev/infra/packages/shared/pkg/redis"
)

func TestRetireMissing_RemovesOnlyConfirmedExecution(t *testing.T) {
	t.Parallel()
	storage, client := setupTestStorage(t)
	sbx := createTestSandbox("crashed")
	require.NoError(t, storage.Add(t.Context(), sbx))
	calls := 0
	removed, err := storage.RetireMissing(t.Context(), sbx, func(_ context.Context, current sandboxtypes.Sandbox) (bool, error) {
		calls++
		require.Equal(t, sbx.ExecutionID, current.ExecutionID)

		return true, nil
	})
	require.NoError(t, err)
	require.True(t, removed)
	require.Equal(t, 1, calls)
	_, err = storage.Get(t.Context(), sbx.TeamID, sbx.SandboxID)
	require.ErrorIs(t, err, sandboxtypes.ErrNotFound)
	require.Empty(t, client.SMembers(t.Context(), GetSandboxStorageTeamIndexKey(sbx.TeamID.String())).Val())
	require.Empty(t, client.ZRange(t.Context(), globalExpirationSet, 0, -1).Val())
}

func TestRetireMissing_ProtectsLifecycleOperations(t *testing.T) {
	t.Parallel()
	for _, kind := range []string{"create", "pause", "checkpoint", "kill", "transition", "new-execution", "moved-node", "unknown-execution"} {
		t.Run(kind, func(t *testing.T) {
			t.Parallel()
			storage, client := setupTestStorage(t)
			sbx := createTestSandbox("protected")
			expected := sbx
			switch kind {
			case "pause":
				sbx.State = sandboxtypes.StatePausing
			case "checkpoint":
				sbx.State = sandboxtypes.StateSnapshotting
			case "kill":
				sbx.State = sandboxtypes.StateKilling
			case "new-execution":
				sbx.ExecutionID = uuid.NewString()
			case "moved-node":
				sbx.NodeID = "other-node"
			case "unknown-execution":
				expected.ExecutionID = ""
			}
			require.NoError(t, storage.Add(t.Context(), sbx))
			if kind == "create" {
				require.NoError(t, client.ZAdd(t.Context(), GetSandboxReservationPendingKey(sbx.TeamID.String()), redis.Z{Member: sbx.SandboxID, Score: 1}).Err())
			}
			if kind == "transition" {
				require.NoError(t, client.Set(t.Context(), getTransitionKey(sbx.TeamID.String(), sbx.SandboxID), "in-flight", 0).Err())
			}
			removed, err := storage.RetireMissing(t.Context(), expected, func(context.Context, sandboxtypes.Sandbox) (bool, error) {
				t.Fatal("an ineligible observation must not touch the node or routing catalog")

				return true, nil
			})
			require.NoError(t, err)
			require.False(t, removed)
			got, err := storage.Get(t.Context(), sbx.TeamID, sbx.SandboxID)
			require.NoError(t, err)
			require.Equal(t, sbx.ExecutionID, got.ExecutionID)
			require.Equal(t, sbx.State, got.State)
		})
	}
}

func TestRetireMissing_RechecksAfterConfirmation(t *testing.T) {
	t.Parallel()
	for _, kind := range []string{"new-execution", "expired-lock", "node-present", "node-failed", "route-failed"} {
		t.Run(kind, func(t *testing.T) {
			t.Parallel()
			storage, client := setupTestStorage(t)
			sbx := createTestSandbox("raced")
			require.NoError(t, storage.Add(t.Context(), sbx))
			expectedExecution := sbx.ExecutionID
			failure := errors.New(kind)
			removed, err := storage.RetireMissing(t.Context(), sbx, func(ctx context.Context, _ sandboxtypes.Sandbox) (bool, error) {
				switch kind {
				case "new-execution":
					newExecution := sbx
					newExecution.ExecutionID = uuid.NewString()
					expectedExecution = newExecution.ExecutionID
					require.NoError(t, storage.Add(ctx, newExecution))
				case "expired-lock":
					require.NoError(t, client.Del(ctx, redisutils.GetLockKey(getSandboxKey(sbx.TeamID.String(), sbx.SandboxID))).Err())
				case "node-present":
					return false, nil
				case "node-failed", "route-failed":
					return false, failure
				}

				return true, nil
			})
			if kind == "node-failed" || kind == "route-failed" {
				require.ErrorIs(t, err, failure)
			} else {
				require.NoError(t, err)
			}
			require.False(t, removed)
			got, err := storage.Get(t.Context(), sbx.TeamID, sbx.SandboxID)
			require.NoError(t, err)
			require.Equal(t, expectedExecution, got.ExecutionID)
			require.True(t, client.SIsMember(t.Context(), GetSandboxStorageTeamIndexKey(sbx.TeamID.String()), sbx.SandboxID).Val())
		})
	}
}
