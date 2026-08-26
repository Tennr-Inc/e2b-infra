package capacity

import (
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"testing"
)

func newTracker(t *testing.T) *Tracker {
	t.Helper()
	tracker, err := New(Limits{MemoryMiB: 32768, Sandboxes: 8, HugepageHeadroomMiB: 2048})
	if err != nil {
		t.Fatal(err)
	}
	return tracker
}

func TestConcurrentAdmission(t *testing.T) {
	for _, memoryMiB := range []int64{1024, 4096, 8192} {
		t.Run(fmt.Sprintf("%dGiB", memoryMiB/1024), func(t *testing.T) {
			tracker := newTracker(t)
			releases := make(chan *Lease, 64)
			var wg sync.WaitGroup
			for range 64 {
				wg.Go(func() {
					release, err := tracker.Acquire(memoryMiB)
					if errors.Is(err, ErrExhausted) {
						return
					}
					if err != nil {
						t.Error(err)
						return
					}
					releases <- release
				})
			}
			wg.Wait()
			close(releases)
			want := min(int64(8), 32768/memoryMiB)
			if state := tracker.Snapshot(); state.SandboxesCommitted != want || state.MemoryCommittedMiB != want*memoryMiB {
				t.Fatalf("concurrent starts exceeded or underfilled capacity: %+v", state)
			}
			for release := range releases {
				release.Release()
				release.Release() // Repeated cleanup must not return the same budget twice.
			}
			if state := tracker.Snapshot(); state.MemoryCommittedMiB != 0 || state.SandboxesCommitted != 0 {
				t.Fatalf("capacity leaked after cleanup: %+v", state)
			}
		})
	}
}

func TestMixedGuestSizesAndRelease(t *testing.T) {
	tracker := newTracker(t)
	for _, size := range []int64{12288, 12288} {
		if _, err := tracker.Acquire(size); err != nil {
			t.Fatal(err)
		}
	}
	release, err := tracker.Acquire(8192)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tracker.Acquire(1); !errors.Is(err, ErrExhausted) {
		t.Fatalf("admitted beyond full RAM budget: %v", err)
	}
	release.Release()
	if _, err := tracker.Acquire(4096); err != nil {
		t.Fatal(err)
	}
}

func TestCapacityCheckpointHandoff(t *testing.T) {
	tracker := newTracker(t)
	old, err := tracker.Acquire(32768)
	if err != nil {
		t.Fatal(err)
	}
	handoff, err := old.Retain()
	if err != nil {
		t.Fatal(err)
	}
	old.Release() // Old VM has finished teardown.
	if _, err := tracker.Acquire(4096); !errors.Is(err, ErrExhausted) {
		t.Fatal("concurrent start stole checkpoint capacity")
	}
	replacement, err := handoff.Retain()
	if err != nil {
		t.Fatal(err)
	}
	handoff.Release()
	if got := tracker.Snapshot(); got.MemoryCommittedMiB != 32768 || got.SandboxesCommitted != 1 {
		t.Fatalf("replacement lost or duplicated commitment: %+v", got)
	}
	replacement.Release()
	if _, err := old.Retain(); err == nil {
		t.Fatal("released capacity must not be resurrected")
	}
	if got := tracker.Snapshot(); got.MemoryCommittedMiB != 0 || got.SandboxesCommitted != 0 {
		t.Fatalf("replacement leaked commitment: %+v", got)
	}
}

func TestCapacityValidation(t *testing.T) {
	tracker := newTracker(t)
	for _, size := range []int64{0, -1} {
		if _, err := tracker.Acquire(size); err == nil {
			t.Fatal("accepted invalid guest memory")
		}
	}
	if _, err := tracker.Acquire(32769); !errors.Is(err, ErrExhausted) {
		t.Fatalf("accepted oversized guest: %v", err)
	}
	if err := tracker.Snapshot().Limits.ValidateBudget(32768); err == nil {
		t.Fatal("headroom must fit within the total hugepage budget")
	}
	if err := tracker.Snapshot().Limits.ValidateBudget(59118); err != nil {
		t.Fatal(err)
	}
	if _, err := New(Limits{}); err == nil {
		t.Fatal("accepted invalid policy")
	}
	if disabled, err := Load(filepath.Join(t.TempDir(), "absent.json")); err != nil || disabled != nil {
		t.Fatalf("absent policy must preserve legacy behavior: %v", err)
	}
}

func TestCapacityEndpoint(t *testing.T) {
	for _, test := range []struct {
		name    string
		address string
		ready   bool
		enabled bool
		want    int
	}{
		{"ready", "127.0.0.1:1234", true, true, http.StatusOK},
		{"booting", "127.0.0.1:1234", false, true, http.StatusServiceUnavailable},
		{"disabled", "127.0.0.1:1234", true, false, http.StatusServiceUnavailable},
		{"remote", "10.40.1.2:1234", true, true, http.StatusForbidden},
	} {
		t.Run(test.name, func(t *testing.T) {
			var tracker *Tracker
			if test.enabled {
				tracker = newTracker(t)
			}
			req := httptest.NewRequest(http.MethodGet, "/capacity", nil)
			req.RemoteAddr = test.address
			response := httptest.NewRecorder()
			tracker.Handler(func() bool { return test.ready }).ServeHTTP(response, req)
			if response.Code != test.want {
				t.Fatalf("status = %d, want %d", response.Code, test.want)
			}
		})
	}
}
