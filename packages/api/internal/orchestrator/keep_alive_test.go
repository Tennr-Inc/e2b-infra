package orchestrator

import (
	"testing"
	"time"
)

func TestGetMaxTTLNormal(t *testing.T) {
	t.Parallel()
	now := time.Now()
	ttl := getMaxAllowedTTL(now, now, 2*time.Hour, 3*time.Hour)
	if ttl != 2*time.Hour {
		t.Fatalf("expected 2 hours, got %v", ttl)
	}
}

func TestGetMaxTTLMax(t *testing.T) {
	t.Parallel()
	now := time.Now()
	ttl := getMaxAllowedTTL(now, now, 4*time.Hour, 3*time.Hour)
	if ttl != 3*time.Hour {
		t.Fatalf("expected 3 hours, got %v", ttl)
	}
}

func TestGetMaxTTLExpired(t *testing.T) {
	t.Parallel()
	now := time.Now()
	ttl := getMaxAllowedTTL(now, now.Add(-2*time.Hour), 4*time.Hour, time.Hour)
	if ttl != 0 {
		t.Fatalf("expected 0 hours, got %v", ttl)
	}
}

func TestGetMaxTTLUsesCapturedSandboxLifetime(t *testing.T) {
	t.Parallel()

	start := time.Date(2026, time.September, 18, 20, 0, 0, 0, time.UTC)
	for _, tc := range []struct {
		name     string
		age      time.Duration
		lifetime time.Duration
		want     time.Duration
	}{
		{"new sandbox", 0, 24 * time.Hour, 24 * time.Hour},
		{"past the old limit", 2 * time.Hour, 24 * time.Hour, 22 * time.Hour},
		{"near the new limit", 23*time.Hour + 30*time.Minute, 24 * time.Hour, 30 * time.Minute},
		{"at the new limit", 24 * time.Hour, 24 * time.Hour, 0},
		{"legacy sandbox", 50 * time.Minute, time.Hour, 10 * time.Minute},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			// Reconnecting requests another day, but never moves the deadline
			// beyond the lifetime captured at the original start time.
			ttl := getMaxAllowedTTL(start.Add(tc.age), start, 24*time.Hour, tc.lifetime)
			if ttl != tc.want {
				t.Fatalf("expected TTL %v, got %v", tc.want, ttl)
			}
		})
	}
}
