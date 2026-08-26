package grpc

import (
	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const sandboxCapacityReason = "SANDBOX_CAPACITY_EXHAUSTED"

// SandboxCapacityExhausted distinguishes a full worker from a short-lived
// startup semaphore refusal. Placement should try other workers for this request.
func SandboxCapacityExhausted(message string) error {
	base := status.New(codes.ResourceExhausted, message)
	detailed, err := base.WithDetails(&errdetails.ErrorInfo{
		Reason: sandboxCapacityReason,
		Domain: "orchestrator.e2b.dev",
	})
	if err != nil {
		return base.Err()
	}

	return detailed.Err()
}

func IsSandboxCapacityExhausted(s *status.Status) bool {
	if s.Code() != codes.ResourceExhausted {
		return false
	}
	for _, detail := range s.Details() {
		if info, ok := detail.(*errdetails.ErrorInfo); ok && info.Reason == sandboxCapacityReason && info.Domain == "orchestrator.e2b.dev" {
			return true
		}
	}

	return false
}
