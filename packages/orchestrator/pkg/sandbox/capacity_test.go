//go:build linux

package sandbox

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/e2b-dev/infra/packages/orchestrator/pkg/capacity"
	"github.com/e2b-dev/infra/packages/orchestrator/pkg/sandbox/fc"
)

func TestCapacityRefusalPrecedesVMResources(t *testing.T) {
	tracker, err := capacity.New(capacity.Limits{MemoryMiB: 4096, Sandboxes: 1})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tracker.Acquire(4096); err != nil {
		t.Fatal(err)
	}
	factory := &Factory{capacity: tracker}
	config := &Config{RamMB: 4096}
	// All VM dependencies are nil: a full node must refuse before using them.
	_, err = factory.ResumeSandbox(t.Context(), nil, config, RuntimeMetadata{}, time.Time{}, time.Time{}, nil)
	if !errors.Is(err, capacity.ErrExhausted) {
		t.Fatalf("resume did not refuse at admission: %v", err)
	}
	_, err = factory.CreateSandbox(t.Context(), config, RuntimeMetadata{}, nil, time.Minute, "", fc.ProcessOptions{}, nil, nil)
	if !errors.Is(err, capacity.ErrExhausted) {
		t.Fatalf("cold boot did not refuse at admission: %v", err)
	}
}

func TestCapacityHeldUntilSuccessfulCleanup(t *testing.T) {
	for _, fail := range []bool{false, true} {
		tracker, err := capacity.New(capacity.Limits{MemoryMiB: 4096, Sandboxes: 1})
		if err != nil {
			t.Fatal(err)
		}
		release, err := tracker.Acquire(4096)
		if err != nil {
			t.Fatal(err)
		}
		cleanup := NewCleanup()
		cleanup.OnSuccess(release.Release)
		cleanup.Add(t.Context(), func(context.Context) error {
			if tracker.Snapshot().MemoryCommittedMiB != 4096 {
				t.Error("released RAM before teardown finished")
			}
			if fail {
				return errors.New("memory mapping still held")
			}
			return nil
		})
		_ = cleanup.Run(t.Context())
		_ = cleanup.Run(t.Context())
		want := int64(0)
		if fail {
			want = 4096
		}
		if got := tracker.Snapshot().MemoryCommittedMiB; got != want {
			t.Fatalf("remaining commitment = %d, want %d (cleanup failed: %t)", got, want, fail)
		}
	}
}
