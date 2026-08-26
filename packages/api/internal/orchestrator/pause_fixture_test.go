package orchestrator

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"go.opentelemetry.io/otel/metric/noop"

	analyticscollector "github.com/e2b-dev/infra/packages/api/internal/analytics_collector"
	snapshotcache "github.com/e2b-dev/infra/packages/api/internal/cache/snapshots"
	"github.com/e2b-dev/infra/packages/api/internal/orchestrator/nodemanager"
	"github.com/e2b-dev/infra/packages/api/internal/sandbox"
	redisreservations "github.com/e2b-dev/infra/packages/api/internal/sandbox/reservations/redis"
	sandboxredis "github.com/e2b-dev/infra/packages/api/internal/sandbox/storage/redis"
	redisutils "github.com/e2b-dev/infra/packages/shared/pkg/redis"
	e2bcatalog "github.com/e2b-dev/infra/packages/shared/pkg/sandbox-catalog"
	"github.com/e2b-dev/infra/packages/shared/pkg/smap"
)

type pauseRemovalFixture struct {
	o   *Orchestrator
	sbx sandbox.Sandbox
}

// Adapt the upstream cancellation/drain tests to this fork's pre-refusal-restore
// storage interface. Use real Redis transitions and snapshot DB writes.
func newPauseRemovalFixture(t *testing.T) pauseRemovalFixture {
	t.Helper()

	o, db, node, sbx := newPauseFixture(t, nil)
	redisClient := redisutils.SetupInstance(t)
	storage, err := sandboxredis.NewStorage(redisClient, noop.NewMeterProvider(), nil)
	require.NoError(t, err)
	go storage.Start(t.Context())
	t.Cleanup(func() { storage.Close(context.WithoutCancel(t.Context())) })

	posthog, err := analyticscollector.NewPosthogClient(t.Context(), "")
	require.NoError(t, err)
	o.posthogClient = posthog
	o.analytics = &analyticscollector.Analytics{}
	o.sandboxStore = sandbox.NewStore(
		storage,
		redisreservations.NewReservationStorage(redisClient, storage.Notifier()),
		sandbox.Callbacks{AddSandboxToRoutingTable: func(context.Context, sandbox.Sandbox) {}},
	)
	o.routingCatalog = e2bcatalog.NewRedisSandboxCatalog(redisClient)
	o.snapshotCache = snapshotcache.NewSnapshotCache(db.SqlcClient, redisClient)
	node.ClusterID = sbx.ClusterID
	o.nodes = smap.New[*nodemanager.Node]()
	o.nodes.Insert(o.scopedNodeID(sbx.ClusterID, node.ID), node)

	sbx.NodeID = node.ID
	sbx.TemplateID = sbx.BaseTemplateID
	sbx.ExecutionID = uuid.NewString()
	sbx.MaxInstanceLength = time.Hour
	sbx.EndTime = time.Now().Add(time.Hour)
	sbx.State = sandbox.StateRunning
	require.NoError(t, o.sandboxStore.Add(t.Context(), sbx, nil))

	return pauseRemovalFixture{o: o, sbx: sbx}
}
