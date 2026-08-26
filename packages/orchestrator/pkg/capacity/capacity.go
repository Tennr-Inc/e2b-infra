// Package capacity accounts for full guest RAM, including starts and teardown.
// It deliberately does not rely on resident memory: lazy guests can grow later.
package capacity

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
)

const DefaultConfigPath = "/etc/e2b/sandbox-capacity.json"

var ErrExhausted = errors.New("sandbox capacity exhausted")

type Limits struct {
	MemoryMiB           int64 `json:"memory_limit_mib"`
	Sandboxes           int64 `json:"sandbox_limit"`
	HugepageHeadroomMiB int64 `json:"hugepage_headroom_mib"`
}

type Snapshot struct {
	Limits
	MemoryCommittedMiB int64 `json:"memory_committed_mib"`
	SandboxesCommitted int64 `json:"sandboxes_committed"`
}

type Tracker struct {
	mu    sync.Mutex
	state Snapshot
}

type reservation struct {
	mu        sync.Mutex
	owners    int
	memoryMiB int64
	release   func()
}

// Lease keeps a commitment across a checkpoint replacement. Each owner releases
// once; the budget returns only after the old VM and the replacement release it.
type Lease struct {
	reservation *reservation
	once        sync.Once
}

func (l *Lease) Retain() (*Lease, error) {
	if l == nil {
		return nil, nil
	}
	r := l.reservation
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.owners == 0 {
		return nil, errors.New("capacity lease already released")
	}
	r.owners++
	return &Lease{reservation: r}, nil
}

func (l *Lease) Release() {
	if l == nil {
		return
	}
	l.once.Do(func() {
		r := l.reservation
		r.mu.Lock()
		defer r.mu.Unlock()
		r.owners--
		if r.owners == 0 {
			r.release()
		}
	})
}

func (l *Lease) MemoryMiB() int64 {
	return l.reservation.memoryMiB
}

func New(limits Limits) (*Tracker, error) {
	if limits.MemoryMiB <= 0 || limits.Sandboxes <= 0 || limits.HugepageHeadroomMiB < 0 {
		return nil, errors.New("capacity limits must be positive and headroom nonnegative")
	}

	return &Tracker{state: Snapshot{Limits: limits}}, nil
}

// Load leaves other providers and build pools unchanged when no policy exists.
// A present but invalid policy must prevent the node from accepting work.
func Load(path string) (*Tracker, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	var limits Limits
	if err := json.Unmarshal(data, &limits); err != nil {
		return nil, fmt.Errorf("read sandbox capacity policy: %w", err)
	}

	tracker, err := New(limits)
	if err != nil {
		return nil, err
	}
	base, err := os.ReadFile("/proc/sys/vm/nr_hugepages")
	if err != nil {
		return nil, err
	}
	pages, err := strconv.ParseInt(strings.TrimSpace(string(base)), 10, 64)
	if err != nil {
		return nil, err
	}
	surplus, err := os.ReadFile("/proc/sys/vm/nr_overcommit_hugepages")
	if err != nil {
		return nil, err
	}
	surplusPages, err := strconv.ParseInt(strings.TrimSpace(string(surplus)), 10, 64)
	if err != nil {
		return nil, err
	}
	// AWS workers use 2 MiB hugepages. The configured commitment limit may
	// deliberately exceed the base pool, but never the total host budget.
	// Surplus is permission to allocate; it is not guaranteed physical backing.
	if pages*2 <= limits.HugepageHeadroomMiB || surplusPages < 0 {
		return nil, errors.New("capacity admission requires a preallocated pool larger than its scaling headroom")
	}
	if err := limits.ValidateBudget((pages + surplusPages) * 2); err != nil {
		return nil, err
	}

	return tracker, nil
}

func (l Limits) ValidateBudget(poolMiB int64) error {
	if poolMiB < l.HugepageHeadroomMiB || l.MemoryMiB > poolMiB-l.HugepageHeadroomMiB {
		return fmt.Errorf("sandbox RAM budget %d MiB plus headroom %d MiB exceeds total hugepage budget %d MiB",
			l.MemoryMiB, l.HugepageHeadroomMiB, poolMiB)
	}

	return nil
}

// Acquire reserves both resources atomically before any VM is started. The
// returned lease must be released only after successful teardown.
// A nil tracker preserves the behavior of pools without an admission policy.
func (t *Tracker) Acquire(memoryMiB int64) (*Lease, error) {
	if t == nil {
		return nil, nil
	}
	if memoryMiB <= 0 {
		return nil, errors.New("guest memory must be positive")
	}

	t.mu.Lock()
	defer t.mu.Unlock()
	if t.state.SandboxesCommitted >= t.state.Sandboxes || memoryMiB > t.state.MemoryMiB-t.state.MemoryCommittedMiB {
		return nil, fmt.Errorf("%w: committed %d/%d MiB and %d/%d sandboxes; requested %d MiB",
			ErrExhausted, t.state.MemoryCommittedMiB, t.state.MemoryMiB,
			t.state.SandboxesCommitted, t.state.Sandboxes, memoryMiB)
	}
	t.state.MemoryCommittedMiB += memoryMiB
	t.state.SandboxesCommitted++

	reserved := &reservation{
		owners:    1,
		memoryMiB: memoryMiB,
		release: func() {
			t.mu.Lock()
			defer t.mu.Unlock()
			t.state.MemoryCommittedMiB -= memoryMiB
			t.state.SandboxesCommitted--
		},
	}

	return &Lease{reservation: reserved}, nil
}

func (t *Tracker) Snapshot() Snapshot {
	t.mu.Lock()
	defer t.mu.Unlock()

	return t.state
}

// Handler serves the node-local capacity reporter on the existing HTTP port.
// Missing admission or readiness never produces a misleading idle sample.
func (t *Tracker) Handler(ready func() bool) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil || !net.ParseIP(host).IsLoopback() {
			http.Error(w, "local access only", http.StatusForbidden)
			return
		}
		if r.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if t == nil || !ready() {
			http.Error(w, "sandbox capacity unavailable", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(t.Snapshot()); err != nil {
			http.Error(w, "encode sandbox capacity", http.StatusInternalServerError)
		}
	})
}
