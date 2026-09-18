package orchestrator

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"go.opentelemetry.io/otel/metric/noop"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"

	"github.com/e2b-dev/infra/packages/api/internal/api"
	"github.com/e2b-dev/infra/packages/api/internal/orchestrator/nodemanager"
	"github.com/e2b-dev/infra/packages/api/internal/sandbox"
	reservations "github.com/e2b-dev/infra/packages/api/internal/sandbox/reservations/redis"
	sandboxredis "github.com/e2b-dev/infra/packages/api/internal/sandbox/storage/redis"
	"github.com/e2b-dev/infra/packages/shared/pkg/consts"
	orchgrpc "github.com/e2b-dev/infra/packages/shared/pkg/grpc/orchestrator"
	redisutils "github.com/e2b-dev/infra/packages/shared/pkg/redis"
	catalog "github.com/e2b-dev/infra/packages/shared/pkg/sandbox-catalog"
	"github.com/e2b-dev/infra/packages/shared/pkg/smap"
)

type missingRuntimeClient struct {
	orchgrpc.SandboxServiceClient

	updateError error
	list        func() (*orchgrpc.SandboxListResponse, error)
}

func (c *missingRuntimeClient) Update(context.Context, *orchgrpc.SandboxUpdateRequest, ...grpc.CallOption) (*emptypb.Empty, error) {
	return nil, c.updateError
}

func (c *missingRuntimeClient) List(context.Context, *emptypb.Empty, ...grpc.CallOption) (*orchgrpc.SandboxListResponse, error) {
	return c.list()
}

func TestMissingRuntimeReconciliation(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"connect", "connect-race", "connect-remote", "background", "background-remote", "unavailable", "partial-list", "failed-list", "nil-list", "checkpoint-returned", "new-execution", "routing-failure"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			ctx := t.Context()
			client := redisutils.SetupInstance(t)
			storage, err := sandboxredis.NewStorage(client, noop.NewMeterProvider(), nil)
			require.NoError(t, err)
			t.Cleanup(func() { storage.Close(context.WithoutCancel(ctx)) })
			routes := catalog.NewRedisSandboxCatalog(client)
			node := nodemanager.NewTestNode("owner", api.NodeStatusReady, 0, 2)
			if scenario != "connect-remote" && scenario != "background-remote" {
				node.ClusterID = consts.LocalClusterID
			}
			o := &Orchestrator{nodes: smap.New[*nodemanager.Node](), routingCatalog: routes}
			deleteCalls := 0
			o.sandboxStore = sandbox.NewStore(storage, reservations.NewReservationStorage(client, storage.Notifier()), sandbox.Callbacks{
				AddSandboxToRoutingTable: func(context.Context, sandbox.Sandbox) {},
				KillOrphanSandbox:        func(context.Context, sandbox.NodeSandbox) { t.Error("must not kill runtimes") },
				RemoveMissingSandboxRoute: func(ctx context.Context, sbx sandbox.Sandbox) error {
					deleteCalls++
					if scenario == "routing-failure" {
						return context.DeadlineExceeded
					}

					return routes.DeleteSandbox(ctx, sbx.SandboxID, sbx.ExecutionID)
				},
			})
			sbx := sandbox.Sandbox{
				SandboxID: "crashed", TeamID: uuid.New(), ExecutionID: uuid.NewString(), NodeID: node.ID, ClusterID: node.ClusterID,
				State: sandbox.StateRunning, StartTime: time.Now().Add(-time.Minute), EndTime: time.Now().Add(time.Hour), MaxInstanceLength: 2 * time.Hour,
			}
			require.NoError(t, o.sandboxStore.Add(ctx, sbx, nil))
			require.NoError(t, routes.StoreSandbox(ctx, sbx.SandboxID, &catalog.SandboxInfo{ExecutionID: sbx.ExecutionID}, time.Hour))
			o.registerNode(node)
			calls := 0
			expected := sbx.ExecutionID
			rpc := &missingRuntimeClient{updateError: status.Error(codes.NotFound, "missing"), list: func() (*orchgrpc.SandboxListResponse, error) {
				calls++
				switch scenario {
				case "partial-list":
					return &orchgrpc.SandboxListResponse{Sandboxes: []*orchgrpc.RunningSandbox{{SandboxId: "invalid", TeamId: "malformed"}}}, nil
				case "nil-list":
					return nil, nil
				case "failed-list":
					return nil, status.Error(codes.Unavailable, "node unavailable")
				case "connect-race":
					return &orchgrpc.SandboxListResponse{Sandboxes: []*orchgrpc.RunningSandbox{{SandboxId: sbx.SandboxID, TeamId: sbx.TeamID.String(), ExecutionId: sbx.ExecutionID}}}, nil
				case "checkpoint-returned":
					if calls > 1 {
						return &orchgrpc.SandboxListResponse{Sandboxes: []*orchgrpc.RunningSandbox{{SandboxId: sbx.SandboxID, TeamId: sbx.TeamID.String(), ExecutionId: sbx.ExecutionID}}}, nil
					}
				case "new-execution":
					if calls == 2 {
						fresh := sbx
						fresh.ExecutionID = uuid.NewString()
						expected = fresh.ExecutionID
						require.NoError(t, storage.Add(ctx, fresh))
						require.NoError(t, routes.StoreSandbox(ctx, sbx.SandboxID, &catalog.SandboxInfo{ExecutionID: fresh.ExecutionID}, time.Hour))
					}
				}

				return &orchgrpc.SandboxListResponse{}, nil
			}}
			node.SetSandboxClient(rpc)
			if scenario == "connect" || scenario == "connect-race" || scenario == "connect-remote" || scenario == "unavailable" {
				if scenario == "unavailable" {
					rpc.updateError = status.Error(codes.Unavailable, "unavailable")
				}
				err = o.UpdateSandbox(ctx, sbx)
				if scenario == "connect" || scenario == "connect-remote" {
					require.ErrorIs(t, err, ErrSandboxNotFound)
				} else {
					require.Error(t, err)
					require.NotErrorIs(t, err, ErrSandboxNotFound)
					if scenario == "unavailable" {
						require.Zero(t, calls)
					}
				}
			} else {
				require.NoError(t, node.Sync(ctx, o.sandboxStore, sbx))
			}
			_, storeErr := storage.Get(ctx, sbx.TeamID, sbx.SandboxID)
			info, routeErr := routes.GetSandbox(ctx, sbx.SandboxID)
			if scenario == "connect" || scenario == "background" {
				require.ErrorIs(t, storeErr, sandbox.ErrNotFound)
				require.ErrorIs(t, routeErr, catalog.ErrSandboxNotFound)
				require.Equal(t, 1, deleteCalls)
			} else {
				require.NoError(t, storeErr)
				require.NoError(t, routeErr)
				require.Equal(t, expected, info.ExecutionID)
			}
		})
	}
}
