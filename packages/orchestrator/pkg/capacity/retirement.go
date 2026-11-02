package capacity

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
)

const RetirementPath = "/orchestrator/retirement.json"

// The journal lives with the NVMe data it protects. Missing history never means
// an empty node: pre-existing nodes require a separate durability audit before
// an operator may seed Verified. A failed snapshot remains pending indefinitely.
type retirementState struct {
	Version  int             `json:"version"`
	Verified bool            `json:"verified"`
	Mode     string          `json:"mode"`
	Pending  map[string]bool `json:"pending"`
}

type RetirementSnapshot struct {
	Snapshot
	Version        int    `json:"version"`
	Verified       bool   `json:"verified"`
	Mode           string `json:"mode"`
	PendingUploads int    `json:"pending_uploads"`
	Ready          bool   `json:"ready"`
	JournalError   bool   `json:"journal_error"`
}

// OpenRetirement must run before serving requests. Corruption refuses startup;
// absent history allows normal work but blocks automatic retirement.
func (t *Tracker) OpenRetirement(path string) error {
	if t == nil {
		return nil
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.retirementPath = path
	state := retirementState{Version: 1, Mode: "active", Pending: map[string]bool{}}
	data, err := os.ReadFile(path)
	if err == nil {
		if err = json.Unmarshal(data, &state); err != nil {
			return err
		}
		if state.Version != 1 || state.Pending == nil || (state.Mode != "active" && state.Mode != "draining" && state.Mode != "sealed") {
			return errors.New("invalid retirement journal")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	t.retirement = &state
	return t.saveRetirementLocked()
}

func (t *Tracker) saveRetirementLocked() error {
	data, err := json.Marshal(t.retirement)
	if err == nil {
		err = writeDurable(t.retirementPath, data)
	}
	// Sticky in this process. A later successful write must not hide lost history.
	if err != nil {
		t.retirementError = err
	}
	return err
}

func writeDurable(path string, data []byte) error {
	file, err := os.CreateTemp(filepath.Dir(path), ".retirement-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if _, err = file.Write(data); err != nil {
		return err
	}
	if err = file.Sync(); err != nil {
		return err
	}
	if err = file.Close(); err != nil {
		return err
	}
	if err = os.Rename(file.Name(), path); err != nil {
		return err
	}
	directory, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

// BeginSnapshot precedes snapshot creation, not just the asynchronous upload.
// Keeping failed attempts is conservative: only proven durable success clears
// an entry, including across process restarts.
func (t *Tracker) BeginSnapshot(buildID string) error {
	if t == nil {
		return nil
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.retirement == nil {
		return nil
	}
	if t.retirement.Mode == "sealed" {
		return errors.New("node is sealed")
	}
	if buildID == "" {
		return errors.New("missing snapshot build ID")
	}
	t.retirement.Pending[buildID] = true
	return t.saveRetirementLocked()
}

func (t *Tracker) SnapshotUploaded(buildID string) error {
	if t == nil {
		return nil
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.retirement == nil {
		return nil
	}
	delete(t.retirement.Pending, buildID)
	return t.saveRetirementLocked()
}

func (t *Tracker) retirementSnapshotLocked() RetirementSnapshot {
	state := t.retirement
	return RetirementSnapshot{
		Snapshot: t.state, Version: 1, Verified: state.Verified,
		Mode: state.Mode, PendingUploads: len(state.Pending),
		JournalError: t.retirementError != nil,
		Ready: state.Verified && t.retirementError == nil && state.Mode != "active" &&
			len(state.Pending) == 0 && t.state.SandboxesCommitted == 0 && t.state.MemoryCommittedMiB == 0,
	}
}

// TransitionRetirement and Acquire share a lock, closing the race between
// observing an empty node and a concurrent create/resume obtaining capacity.
// Sealing is irreversible via the API and survives restarts. AWS may therefore
// retry termination after an uncertain response without reopening admission.
func (t *Tracker) TransitionRetirement(action string) (RetirementSnapshot, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.retirement == nil {
		return RetirementSnapshot{}, errors.New("retirement unavailable")
	}
	state := t.retirement
	switch action {
	case "":
	case "drain":
		if !state.Verified || t.retirementError != nil {
			return t.retirementSnapshotLocked(), errors.New("unverified snapshot history")
		}
		if state.Mode == "active" {
			state.Mode = "draining"
		}
	case "cancel":
		if state.Mode == "sealed" {
			return t.retirementSnapshotLocked(), errors.New("sealed node cannot reopen")
		}
		state.Mode = "active"
	case "seal":
		if !t.retirementSnapshotLocked().Ready {
			return t.retirementSnapshotLocked(), errors.New("node still owns work or undurable snapshots")
		}
		state.Mode = "sealed"
	default:
		return RetirementSnapshot{}, fmt.Errorf("unknown retirement action %q", action)
	}
	if action != "" {
		if err := t.saveRetirementLocked(); err != nil {
			return t.retirementSnapshotLocked(), err
		}
	}
	return t.retirementSnapshotLocked(), nil
}

// This control surface is reachable only from the host (the controller uses
// SSM). Never expose it through sandbox ports or the public API.
func (t *Tracker) RetirementHandler(changed func(string)) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil || !net.ParseIP(host).IsLoopback() {
			http.Error(w, "local access only", http.StatusForbidden)
			return
		}
		if t == nil {
			http.Error(w, "admission disabled", http.StatusServiceUnavailable)
			return
		}
		action := ""
		switch r.Method {
		case http.MethodGet:
		case http.MethodPost:
			action = r.URL.Query().Get("action")
			if action == "" {
				http.Error(w, "action required", http.StatusBadRequest)
				return
			}
		default:
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		state, err := t.TransitionRetirement(action)
		if err != nil {
			http.Error(w, err.Error(), http.StatusConflict)
			return
		}
		if action != "" {
			changed(state.Mode)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(state)
	})
}

// StopAdmission fences creates before graceful shutdown begins. Cancellation
// of an autoscaler drain must not reopen a process that is shutting down.
func (t *Tracker) StopAdmission() {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.stopping = true
}
