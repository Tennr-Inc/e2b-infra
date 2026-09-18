package sandbox

import (
	"context"
	"errors"
	"net/http"
	"sync"
	"time"

	"github.com/google/uuid"
	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/api/internal/sandbox/sandboxtypes"
	"github.com/e2b-dev/infra/packages/shared/pkg/logger"
	sbxlogger "github.com/e2b-dev/infra/packages/shared/pkg/logger/sandbox"
)

type CreationMetadata struct {
	IsResume       bool
	TeamName       string
	RequestHeader  http.Header
	MCPServerNames []string
}

type (
	InsertCallback   func(ctx context.Context, sbx Sandbox)
	OrphanCallback   func(ctx context.Context, sbx NodeSandbox)
	CreationCallback func(ctx context.Context, sbx Sandbox, meta CreationMetadata)
)

const sbxRemoveTimeout = 10 * time.Second

// Storage and ReservationStorage are re-exported from sandboxtypes so external
// callers can continue to use sandbox.Storage / sandbox.ReservationStorage.
// They live in sandboxtypes (a leaf package) so storage backends can implement
// them without creating an import cycle back into package sandbox.
type (
	Storage            = sandboxtypes.Storage
	ReservationStorage = sandboxtypes.ReservationStorage
)

type Callbacks struct {
	// AddSandboxToRoutingTable should be called sync to prevent race conditions where we would know where to route the sandbox
	AddSandboxToRoutingTable InsertCallback
	// AsyncNewlyCreatedSandbox is called asynchronously for newly created sandboxes (Add called with non-nil CreationMetadata).
	AsyncNewlyCreatedSandbox CreationCallback
	// KillOrphanSandbox kills an orphaned sandbox on the orchestrator node via gRPC.
	// Used during sync when the Redis backend detects sandboxes running on a node but not present in the store.
	KillOrphanSandbox OrphanCallback
	// RemoveMissingSandboxRoute removes only the observed execution's routing entry.
	RemoveMissingSandboxRoute func(context.Context, Sandbox) error
}

type Store struct {
	storage   Storage
	callbacks Callbacks

	reservations ReservationStorage
}

func NewStore(
	backend Storage,
	reservations ReservationStorage,
	callbacks Callbacks,
) *Store {
	return &Store{
		storage:      backend,
		reservations: reservations,
		callbacks:    callbacks,
	}
}

// Add inserts a sandbox into the store. A non-nil creation argument fires the
// AsyncNewlyCreatedSandbox callback; nil indicates a sync/reconcile re-add.
func (s *Store) Add(ctx context.Context, sandbox Sandbox, creation *CreationMetadata) error {
	sbxlogger.I(sandbox).Debug(ctx, "Adding sandbox to cache",
		zap.Bool("newly_created", creation != nil),
		logger.Time("start_time", sandbox.StartTime),
		logger.Time("end_time", sandbox.EndTime),
	)

	endTime := sandbox.EndTime

	if endTime.Sub(sandbox.StartTime) > sandbox.MaxInstanceLength {
		sandbox.EndTime = sandbox.StartTime.Add(sandbox.MaxInstanceLength)
	}

	err := s.storage.Add(ctx, sandbox)
	if err != nil {
		return err
	}
	s.callbacks.AddSandboxToRoutingTable(ctx, sandbox)

	if creation != nil {
		meta := *creation
		go s.callbacks.AsyncNewlyCreatedSandbox(context.WithoutCancel(ctx), sandbox, meta)
	}

	return nil
}

func (s *Store) Get(ctx context.Context, teamID uuid.UUID, sandboxID string) (Sandbox, error) {
	return s.storage.Get(ctx, teamID, sandboxID)
}

func (s *Store) Remove(ctx context.Context, teamID uuid.UUID, sandboxID string) {
	err := s.storage.Remove(ctx, teamID, sandboxID)
	if err != nil {
		logger.L().Error(ctx, "Failed to remove sandbox from storage", zap.Error(err), logger.WithSandboxID(sandboxID))
	}

	err = s.reservations.Release(ctx, teamID, sandboxID)
	if err != nil {
		logger.L().Error(ctx, "Failed to release reservation", zap.Error(err), logger.WithSandboxID(sandboxID))
	}
}

func (s *Store) TeamItems(ctx context.Context, teamID uuid.UUID, states []State) ([]Sandbox, error) {
	return s.storage.TeamItems(ctx, teamID, states)
}

func (s *Store) ExpiredItems(ctx context.Context) ([]Sandbox, error) {
	return s.storage.ExpiredItems(ctx)
}

func (s *Store) AllRunningItems(ctx context.Context) ([]Sandbox, error) {
	return s.storage.AllRunningItems(ctx)
}

// RetireMissing confirms absence while lifecycle transitions are excluded. Route
// cleanup precedes record removal so failed cleanup remains discoverable on retry.
// Snapshots and reservation results are not part of runtime retirement.
func (s *Store) RetireMissing(ctx context.Context, expected Sandbox, confirm func(context.Context, Sandbox) (bool, error)) (bool, error) {
	return s.storage.RetireMissing(ctx, expected, func(ctx context.Context, current Sandbox) (bool, error) {
		missing, err := confirm(ctx, current)
		if err != nil || !missing {
			return false, err
		}
		if err := ctx.Err(); err != nil {
			return false, err
		}
		if s.callbacks.RemoveMissingSandboxRoute == nil {
			return false, errors.New("missing sandbox routing cleanup is not configured")
		}
		if err := s.callbacks.RemoveMissingSandboxRoute(ctx, current); err != nil {
			return false, err
		}

		return true, nil
	})
}

func (s *Store) TeamsWithSandboxes(ctx context.Context) (map[uuid.UUID]int64, error) {
	return s.storage.TeamsWithSandboxCount(ctx)
}

func (s *Store) Update(ctx context.Context, teamID uuid.UUID, sandboxID string, updateFunc func(sandbox Sandbox) (Sandbox, error)) (Sandbox, error) {
	return s.storage.Update(ctx, teamID, sandboxID, updateFunc)
}

func (s *Store) StartRemoving(ctx context.Context, teamID uuid.UUID, sandboxID string, opts RemoveOpts) (Sandbox, bool, func(context.Context, error), error) {
	return s.storage.StartRemoving(ctx, teamID, sandboxID, opts)
}

func (s *Store) WaitForStateChange(ctx context.Context, teamID uuid.UUID, sandboxID string) error {
	return s.storage.WaitForStateChange(ctx, teamID, sandboxID)
}

func (s *Store) Reconcile(ctx context.Context, sandboxes []NodeSandbox, nodeID string) {
	// Redis is the source of truth — divergent sandboxes are orphans running
	// on the node but not present in the store. Kill them.
	orphans := s.storage.Reconcile(ctx, sandboxes, nodeID)

	wg := sync.WaitGroup{}
	for _, sbx := range orphans {
		wg.Go(func() {
			ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), sbxRemoveTimeout)
			defer cancel()
			s.callbacks.KillOrphanSandbox(ctx, sbx)
		})
	}

	wg.Wait()
}

func (s *Store) Reserve(ctx context.Context, teamID uuid.UUID, sandboxID string, limit int) (finishStart func(Sandbox, error), waitForStart func(ctx context.Context) (Sandbox, error), err error) {
	finishStart, waitForStart, err = s.reservations.Reserve(ctx, teamID, sandboxID, limit)
	if err != nil {
		if errors.Is(err, ErrAlreadyExists) {
			// Try to get the sandbox from the storage if already exists
			return nil, func(ctx context.Context) (Sandbox, error) {
				return s.storage.Get(ctx, teamID, sandboxID)
			}, nil
		}

		return nil, nil, err
	}

	return finishStart, waitForStart, nil
}
