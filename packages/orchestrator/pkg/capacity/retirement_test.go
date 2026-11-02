package capacity

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func retirementTracker(t *testing.T, verified bool) (*Tracker, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "retirement.json")
	state := retirementState{Version: 1, Verified: verified, Mode: "active", Pending: map[string]bool{}}
	data, _ := json.Marshal(state)
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	tracker := newTracker(t)
	if err := tracker.OpenRetirement(path); err != nil {
		t.Fatal(err)
	}
	return tracker, path
}

func TestRetirementWaitsForTeardownAndDurability(t *testing.T) {
	tracker, path := retirementTracker(t, true)
	lease, err := tracker.Acquire(4096)
	if err != nil {
		t.Fatal(err)
	}
	if err := tracker.BeginSnapshot("snapshot"); err != nil {
		t.Fatal(err)
	}
	if _, err := tracker.TransitionRetirement("drain"); err != nil {
		t.Fatal(err)
	}
	if _, err := tracker.Acquire(4096); !errors.Is(err, ErrExhausted) {
		t.Fatalf("admitted during drain: %v", err)
	}
	lease.Release()
	if _, err := tracker.TransitionRetirement("seal"); err == nil {
		t.Fatal("sealed before upload completed")
	}
	// A restart cannot erase an unfinished/failed upload.
	restarted := newTracker(t)
	if err := restarted.OpenRetirement(path); err != nil {
		t.Fatal(err)
	}
	state, _ := restarted.TransitionRetirement("")
	if state.Ready || state.PendingUploads != 1 {
		t.Fatalf("lost pending upload: %+v", state)
	}
	if err := restarted.SnapshotUploaded("snapshot"); err != nil {
		t.Fatal(err)
	}
	state, err = restarted.TransitionRetirement("seal")
	if err != nil || !state.Ready || state.Mode != "sealed" {
		t.Fatalf("cannot seal durable empty node: %+v, %v", state, err)
	}
	if _, err := restarted.TransitionRetirement("cancel"); err == nil {
		t.Fatal("reopened a sealed node")
	}
	again := newTracker(t)
	if err := again.OpenRetirement(path); err != nil {
		t.Fatal(err)
	}
	if _, err := again.Acquire(4096); !errors.Is(err, ErrExhausted) {
		t.Fatal("restart reopened admission")
	}
}

func TestRetirementDrainRacesAdmission(t *testing.T) {
	for range 50 {
		tracker, _ := retirementTracker(t, true)
		var lease *Lease
		var wg sync.WaitGroup
		wg.Go(func() { lease, _ = tracker.Acquire(4096) })
		wg.Go(func() { _, _ = tracker.TransitionRetirement("drain") })
		wg.Wait()
		state, err := tracker.TransitionRetirement("seal")
		if lease != nil && err == nil {
			t.Fatalf("sealed with outstanding lease: %+v", state)
		}
		if lease == nil && err != nil {
			t.Fatal(err)
		}
		lease.Release()
	}
}

func TestRetirementUnknownHistoryAndDiskErrorsFailClosed(t *testing.T) {
	tracker, path := retirementTracker(t, false)
	if _, err := tracker.TransitionRetirement("drain"); err == nil {
		t.Fatal("drained unverified history")
	}
	tracker, path = retirementTracker(t, true)
	// Make future durable writes impossible without relying on uid permissions.
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(path, 0700); err != nil {
		t.Fatal(err)
	}
	if err := tracker.BeginSnapshot("pending"); err == nil {
		t.Fatal("ignored journal error")
	}
	if _, err := tracker.TransitionRetirement("drain"); err == nil {
		t.Fatal("drained after journal error")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	_ = tracker.SnapshotUploaded("pending")
	if _, err := tracker.TransitionRetirement("drain"); err == nil {
		t.Fatal("forgot journal error after a successful write")
	}
}

func TestRetirementRejectsRemoteCallers(t *testing.T) {
	tracker, _ := retirementTracker(t, true)
	req := httptest.NewRequest(http.MethodPost, "/retirement?action=drain", nil)
	req.RemoteAddr = "10.0.0.1:1234"
	res := httptest.NewRecorder()
	tracker.RetirementHandler(func(string) { t.Fatal("remote request changed state") }).ServeHTTP(res, req)
	if res.Code != http.StatusForbidden {
		t.Fatal(res.Code)
	}
}

func TestRetirementCannotSealWhileCleanupOwnsCapacity(t *testing.T) {
	tracker, _ := retirementTracker(t, true)
	lease, _ := tracker.Acquire(4096)
	retained, _ := lease.Retain()
	_, _ = tracker.TransitionRetirement("drain")
	lease.Release()
	if _, err := tracker.TransitionRetirement("seal"); err == nil {
		t.Fatal("sealed while checkpoint cleanup still owns memory")
	}
	retained.Release()
	if _, err := tracker.TransitionRetirement("seal"); err != nil {
		t.Fatal(err)
	}
}

func TestRetirementCancellationCannotReopenShutdown(t *testing.T) {
	tracker, _ := retirementTracker(t, true)
	_, _ = tracker.TransitionRetirement("drain")
	tracker.StopAdmission()
	_, _ = tracker.TransitionRetirement("cancel")
	if _, err := tracker.Acquire(4096); !errors.Is(err, ErrExhausted) {
		t.Fatal("cancellation reopened shutdown")
	}
}
