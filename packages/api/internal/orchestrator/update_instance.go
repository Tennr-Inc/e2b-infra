package orchestrator

import (
	"context"
	"fmt"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/zap"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	"github.com/e2b-dev/infra/packages/api/internal/sandbox"
	"github.com/e2b-dev/infra/packages/api/internal/utils"
	"github.com/e2b-dev/infra/packages/shared/pkg/grpc/orchestrator"
	"github.com/e2b-dev/infra/packages/shared/pkg/logger"
	"github.com/e2b-dev/infra/packages/shared/pkg/telemetry"
)

func (o *Orchestrator) UpdateSandbox(
	ctx context.Context,
	sbx sandbox.Sandbox,
) error {
	ctx, span := tracer.Start(ctx, "update-sandbox",
		trace.WithAttributes(
			attribute.String("instance.id", sbx.SandboxID),
		),
	)
	defer span.End()

	node := o.getOrConnectNode(ctx, sbx.ClusterID, sbx.NodeID)
	if node == nil {
		return fmt.Errorf("node '%s' not found", sbx.NodeID)
	}

	client, ctx := node.GetClient(ctx)
	_, err := client.Sandbox.Update(
		ctx, &orchestrator.SandboxUpdateRequest{
			SandboxId: sbx.SandboxID,
			EndTime:   timestamppb.New(sbx.EndTime),
		},
	)
	if err != nil {
		grpcErr, ok := status.FromError(err)
		if ok && grpcErr.Code() == codes.NotFound {
			if node.IsClusterNode() {
				// Remote routing belongs to the enterprise edge, outside this
				// API's catalog. Preserve its existing NotFound behavior.
				return ErrSandboxNotFound
			}
			// The RPC used this exact execution's owning node. A second check
			// under the lifecycle lock excludes checkpoint/pause races.
			removed, cleanupErr := o.sandboxStore.RetireMissing(ctx, sbx, node.ConfirmsSandboxMissing)
			if cleanupErr != nil {
				logger.L().Error(ctx, "Failed to retire missing sandbox", zap.Error(cleanupErr), logger.WithSandboxID(sbx.SandboxID))

				return fmt.Errorf("failed to reconcile missing sandbox: %w", cleanupErr)
			}
			if !removed {
				// A transition or newer execution makes the earlier NotFound
				// inconclusive. Do not invite callers to replace live compute.
				return fmt.Errorf("sandbox changed during absence reconciliation: %w", ErrSandboxOperationFailed)
			}
			return ErrSandboxNotFound
		}

		err = utils.UnwrapGRPCError(err)

		return fmt.Errorf("failed to update sandbox '%s': %w", sbx.SandboxID, err)
	}

	telemetry.ReportEvent(ctx, "Updated sandbox")

	return nil
}
