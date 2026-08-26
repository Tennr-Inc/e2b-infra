package logs

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"connectrpc.com/connect"
	"github.com/rs/zerolog"
	"github.com/stretchr/testify/require"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/structpb"
)

func TestRPCLogsOmitPayloads(t *testing.T) {
	t.Parallel()

	// Include a credential under an innocuous name: filtering only keys named
	// TOKEN or PASSWORD would still expose arbitrary injected credentials.
	payload, err := structpb.NewStruct(map[string]any{
		"process": map[string]any{
			"envs": map[string]any{
				"GH_TOKEN":  "github-credential-sentinel",
				"ordinary":  "custom-credential-sentinel",
				"PUBLIC_ID": "public-value-sentinel",
			},
		},
		"input": "stdin-credential-sentinel",
	})
	require.NoError(t, err)

	for _, transport := range []string{"unary", "server_stream", "client_stream"} {
		for _, fail := range []bool{false, true} {
			name := transport + "/success"
			if fail {
				name = transport + "/error"
			}

			t.Run(name, func(t *testing.T) {
				t.Parallel()
				testRPCLogPayloads(t, transport, fail, payload)
			})
		}
	}
}

func testRPCLogPayloads(t *testing.T, transport string, fail bool, payload *structpb.Struct) {
	t.Helper()

	var output bytes.Buffer
	logger := zerolog.New(&output).Level(zerolog.DebugLevel)
	const procedure = "/test.Logging/Call"

	checkRequest := func(ctx context.Context, message *structpb.Struct) error {
		if !proto.Equal(payload, message) {
			return connect.NewError(connect.CodeInternal, errors.New("handler payload changed"))
		}
		if id, ok := ctx.Value(OperationIDKey).(string); !ok || id == "" {
			return connect.NewError(connect.CodeInternal, errors.New("missing operation ID"))
		}
		if fail {
			return connect.NewError(connect.CodePermissionDenied, errors.New("request denied"))
		}

		return nil
	}

	var handler http.Handler
	switch transport {
	case "unary":
		handler = connect.NewUnaryHandler(procedure,
			func(ctx context.Context, req *connect.Request[structpb.Struct]) (*connect.Response[structpb.Struct], error) {
				if err := checkRequest(ctx, req.Msg); err != nil {
					return nil, err
				}

				return connect.NewResponse(req.Msg), nil
			}, connect.WithInterceptors(NewUnaryLogInterceptor(&logger)))
	case "server_stream":
		handler = connect.NewServerStreamHandler(procedure,
			func(ctx context.Context, req *connect.Request[structpb.Struct], stream *connect.ServerStream[structpb.Struct]) error {
				return LogServerStreamWithoutEvents(ctx, &logger, req, stream,
					func(ctx context.Context, req *connect.Request[structpb.Struct], stream *connect.ServerStream[structpb.Struct]) error {
						if err := checkRequest(ctx, req.Msg); err != nil {
							return err
						}

						return stream.Send(req.Msg)
					})
			})
	case "client_stream":
		handler = connect.NewClientStreamHandler(procedure,
			func(ctx context.Context, stream *connect.ClientStream[structpb.Struct]) (*connect.Response[structpb.Struct], error) {
				return LogClientStreamWithoutEvents(ctx, &logger, stream,
					func(ctx context.Context, stream *connect.ClientStream[structpb.Struct]) (*connect.Response[structpb.Struct], error) {
						if !stream.Receive() {
							return nil, connect.NewError(connect.CodeInternal, errors.New("missing request"))
						}
						message := stream.Msg()
						if err := checkRequest(ctx, message); err != nil {
							return nil, err
						}
						if stream.Receive() {
							return nil, connect.NewError(connect.CodeInternal, errors.New("unexpected request"))
						}
						if err := stream.Err(); err != nil {
							return nil, err
						}

						return connect.NewResponse(message), nil
					})
			})
	}

	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	client := connect.NewClient[structpb.Struct, structpb.Struct](server.Client(), server.URL+procedure)

	var response *structpb.Struct
	var callErr error
	switch transport {
	case "unary":
		result, err := client.CallUnary(t.Context(), connect.NewRequest(payload))
		callErr = err
		if result != nil {
			response = result.Msg
		}
	case "server_stream":
		stream, err := client.CallServerStream(t.Context(), connect.NewRequest(payload))
		require.NoError(t, err)
		for stream.Receive() {
			response = stream.Msg()
		}
		callErr = stream.Err()
		require.NoError(t, stream.Close())
	case "client_stream":
		stream := client.CallClientStream(t.Context())
		require.NoError(t, stream.Send(payload))
		result, err := stream.CloseAndReceive()
		callErr = err
		if result != nil {
			response = result.Msg
		}
	}

	// Wait for the handler's final log write before inspecting its output.
	server.Close()
	if fail {
		require.Equal(t, connect.CodePermissionDenied, connect.CodeOf(callErr))
	} else {
		require.NoError(t, callErr)
		require.True(t, proto.Equal(payload, response), "caller must receive the unchanged payload")
	}

	require.NotContains(t, output.String(), "sentinel")
	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	expectedLines := 1
	if transport != "unary" {
		expectedLines = 2
	}
	require.Len(t, lines, expectedLines)

	var recordedOperationID string
	for i, line := range lines {
		var event map[string]any
		require.NoError(t, json.Unmarshal([]byte(line), &event))
		require.Equal(t, "POST "+procedure, event["method"])
		require.NotContains(t, event, "request")
		require.NotContains(t, event, "response")
		if i == 0 {
			recordedOperationID, _ = event["operation_id"].(string)
			require.NotEmpty(t, recordedOperationID)
		}
		require.Equal(t, recordedOperationID, event["operation_id"])
		if fail && i == len(lines)-1 {
			require.Equal(t, "error", event["level"])
			require.Equal(t, float64(connect.CodePermissionDenied), event["error_code"])
		}
	}
}
