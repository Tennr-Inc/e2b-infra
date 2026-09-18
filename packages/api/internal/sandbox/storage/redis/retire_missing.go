package redis

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/api/internal/sandbox/sandboxtypes"
	"github.com/e2b-dev/infra/packages/shared/pkg/logger"
	redisutils "github.com/e2b-dev/infra/packages/shared/pkg/redis"
)

// RetireMissing revalidates an observation under the lifecycle lock, then deletes
// only that execution. The callback must confirm absence on the owning node and
// remove its execution-scoped route; uncertainty must return false or an error.
func (s *Storage) RetireMissing(ctx context.Context, expected sandboxtypes.Sandbox, confirm func(context.Context, sandboxtypes.Sandbox) (bool, error)) (bool, error) {
	if expected.ExecutionID == "" {
		return false, nil
	}

	// Bound network confirmation well within the lock lease. The Lua guard also
	// checks lock ownership, protecting against a stalled process losing its lease.
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	team := expected.TeamID.String()
	key := getSandboxKey(team, expected.SandboxID)
	lockKey := redisutils.GetLockKey(key)
	lock, err := s.locker.Obtain(ctx, lockKey, lockTimeout)
	if err != nil {
		return false, err
	}
	defer func() {
		if err := lock.Release(context.WithoutCancel(ctx)); err != nil {
			logger.L().Warn(ctx, "Failed to release missing sandbox lock", zap.Error(err))
		}
	}()

	raw, err := s.redisClient.Get(ctx, key).Result()
	if errors.Is(err, redis.Nil) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	var current sandboxtypes.Sandbox
	if err := json.Unmarshal([]byte(raw), &current); err != nil {
		return false, err
	}
	if current.ExecutionID != expected.ExecutionID || current.NodeID != expected.NodeID ||
		current.ClusterID != expected.ClusterID || current.State != sandboxtypes.StateRunning {
		return false, nil
	}

	keys := []string{
		key, GetSandboxStorageTeamIndexKey(team), getTransitionKey(team, expected.SandboxID),
		GetSandboxReservationPendingKey(team), lockKey,
	}
	args := []any{raw, expected.SandboxID, lock.Token(), false}
	eligible, err := retireMissingScript.Run(ctx, s.redisClient, keys, args...).Bool()
	if err != nil || !eligible {
		return false, err
	}
	missing, err := confirm(ctx, current)
	if err != nil || !missing {
		return false, err
	}

	args[3] = true
	removed, err := retireMissingScript.Run(ctx, s.redisClient, keys, args...).Bool()
	if err != nil {
		return false, fmt.Errorf("retire missing sandbox: %w", err)
	}
	if removed {
		if err := s.redisClient.ZRem(ctx, globalExpirationSet, sandboxExpirationMember(current)).Err(); err != nil {
			// The expiration sweeper can recover this execution-scoped index entry.
			logger.L().Warn(ctx, "Failed to unindex missing sandbox", zap.Error(err), logger.WithSandboxID(current.SandboxID))
		}
	}

	return removed, nil
}

// Compare the complete record as well as the lock: Add does not take the lock,
// and a delayed observation must never delete a newly resumed execution.
var retireMissingScript = redis.NewScript(`
	if redis.call('GET', KEYS[1]) ~= ARGV[1] or
	   redis.call('GET', KEYS[5]) ~= ARGV[3] or
	   redis.call('EXISTS', KEYS[3]) == 1 or
	   redis.call('ZSCORE', KEYS[4], ARGV[2]) then
		return 0
	end
	if ARGV[4] == '1' then
		redis.call('DEL', KEYS[1])
		redis.call('SREM', KEYS[2], ARGV[2])
	end
	return 1
`)
