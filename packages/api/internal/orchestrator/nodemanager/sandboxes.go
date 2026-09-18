package nodemanager

import (
	"cmp"
	"context"
	"fmt"

	"github.com/golang/protobuf/ptypes/empty"
	"github.com/google/uuid"
	"go.opentelemetry.io/otel"
	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/api/internal/sandbox"
	"github.com/e2b-dev/infra/packages/api/internal/utils"
	"github.com/e2b-dev/infra/packages/db/pkg/types"
	"github.com/e2b-dev/infra/packages/shared/pkg/grpc/orchestrator"
	"github.com/e2b-dev/infra/packages/shared/pkg/logger"
)

var tracer = otel.Tracer("github.com/e2b-dev/infra/packages/api/internal/orchestrator/nodemanager")

// GetOrphanCandidates lists the sandboxes the node reports as running, so the
// caller can compare them against the store and kill the ones it does not know
// about. Only the fields that decision needs are read; Redis is the source of
// truth for everything else.
//
// A sandbox missing either half of its store key — sandbox ID or a parseable
// team ID — is skipped rather than failing the whole call. Its store entry
// cannot be looked up, so it can be neither confirmed nor killed, and failing
// here would abort the node sync entirely.
func (n *Node) GetOrphanCandidates(ctx context.Context) ([]sandbox.NodeSandbox, error) {
	sandboxes, _, err := n.getSandboxInventory(ctx)

	return sandboxes, err
}

// getSandboxInventory reports whether the entire response can prove absence.
func (n *Node) getSandboxInventory(ctx context.Context) ([]sandbox.NodeSandbox, bool, error) {
	childCtx, childSpan := tracer.Start(ctx, "get-sandboxes-from-orchestrator")
	defer childSpan.End()

	client, childCtx := n.GetClient(childCtx)
	res, err := client.Sandbox.List(childCtx, &empty.Empty{})

	err = utils.UnwrapGRPCError(err)
	if err != nil {
		return nil, false, fmt.Errorf("failed to list sandboxes: %w", err)
	}

	if res == nil {
		return nil, false, nil
	}
	complete := true
	sandboxes := res.GetSandboxes()

	sandboxesInfo := make([]sandbox.NodeSandbox, 0, len(sandboxes))

	for _, sbx := range sandboxes {
		// config is deprecated and only read as a fallback for orchestrators
		// that predate the scalar fields. Proto getters are nil-safe.
		config := sbx.GetConfig() //nolint:staticcheck // rollout fallback

		sandboxID := cmp.Or(sbx.GetSandboxId(), config.GetSandboxId())
		rawTeamID := cmp.Or(sbx.GetTeamId(), config.GetTeamId())

		// An entry with no sandbox ID always misses its store lookup, so it
		// would be read as an orphan and killed — and the kill would subtract
		// its resources from the node's accounting for a sandbox that is still
		// running under some other identity.
		if sandboxID == "" {
			logger.L().Error(childCtx, "Skipping sandbox with no sandbox ID during node sync",
				zap.String("team_id", rawTeamID),
				logger.WithNodeID(n.ID),
			)

			complete = false
			continue
		}

		teamID, parseErr := uuid.Parse(rawTeamID)
		if parseErr != nil {
			logger.L().Error(childCtx, "Skipping sandbox with unparseable team ID during node sync",
				zap.Error(parseErr),
				zap.String("team_id", rawTeamID),
				logger.WithSandboxID(sandboxID),
				logger.WithNodeID(n.ID),
			)

			complete = false
			continue
		}

		if cmp.Or(sbx.GetExecutionId(), config.GetExecutionId()) == "" {
			complete = false
		}
		sandboxesInfo = append(sandboxesInfo, sandbox.NodeSandbox{
			SandboxID:   sandboxID,
			TeamID:      teamID,
			ExecutionID: cmp.Or(sbx.GetExecutionId(), config.GetExecutionId()),
			VCpu:        cmp.Or(sbx.GetVcpu(), config.GetVcpu()),
			RamMB:       cmp.Or(sbx.GetRamMb(), config.GetRamMb()),
			StartTime:   sbx.GetStartTime().AsTime(),
			NodeID:      n.ID,
			ClusterID:   n.ClusterID,
		})
	}

	return sandboxesInfo, complete, nil
}

func ConvertOrchestratorMountsToDatabaseMounts(mounts []*orchestrator.SandboxVolumeMount) []*types.SandboxVolumeMountConfig {
	var results []*types.SandboxVolumeMountConfig

	for _, item := range mounts {
		results = append(results, &types.SandboxVolumeMountConfig{
			ID:   item.GetId(),
			Type: item.GetType(),
			Name: item.GetName(),
			Path: item.GetPath(),
		})
	}

	return results
}

// ConfirmsSandboxMissing uses a complete, successful node response. It is called
// under the store lifecycle lock, after excluding create/resume and transitions.
func (n *Node) ConfirmsSandboxMissing(ctx context.Context, expected sandbox.Sandbox) (bool, error) {
	if expected.NodeID != n.ID || expected.ClusterID != n.ClusterID {
		return false, nil
	}
	items, complete, err := n.getSandboxInventory(ctx)
	if err != nil || !complete {
		return false, err
	}
	for _, item := range items {
		if item.SandboxID == expected.SandboxID {
			return false, nil
		}
	}

	return true, nil
}
