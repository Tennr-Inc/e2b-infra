//go:build linux

package sandbox

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/e2b-dev/infra/packages/orchestrator/pkg/sandbox/envd"
	"github.com/e2b-dev/infra/packages/orchestrator/pkg/sandbox/network"
	"github.com/e2b-dev/infra/packages/orchestrator/pkg/template/metadata"
)

func TestEnvdTemplateDefaults(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		context metadata.Context
		envd    EnvdMetadata
		user    string
		workdir *string
	}{
		{name: "legacy template", user: "user"},
		{name: "root template", context: metadata.Context{User: "root"}, user: "root"},
		{
			name:    "custom template",
			context: metadata.Context{User: "developer", WorkDir: new("/workspace")},
			user:    "developer", workdir: new("/workspace"),
		},
		{
			name:    "explicit settings",
			context: metadata.Context{User: "user", WorkDir: new("/workspace")},
			envd:    EnvdMetadata{DefaultUser: new("root"), DefaultWorkdir: new("/build")},
			user:    "root", workdir: new("/build"),
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			got := tt.envd.WithTemplateDefaults(tt.context)
			require.NotNil(t, got.DefaultUser)
			assert.Equal(t, tt.user, *got.DefaultUser)
			assert.Equal(t, tt.workdir, got.DefaultWorkdir)
		})
	}
}

// A live upgrade replaces envd with a process whose initial default is root.
// Both the first /init and the post-upgrade /init must restore the template
// settings, even if the snapshot already contains the wrong in-memory defaults.
func TestEnvdInitRestoresTemplateDefaults(t *testing.T) { //nolint:paralleltest
	sbx := newTestSandboxWithBundle("")
	sbx.Config.Envd = sbx.Config.Envd.WithTemplateDefaults(metadata.Context{
		User: "user", WorkDir: new("/sandbox/tennr"),
	})

	var captured []envd.PostInitJSONBody
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body envd.PostInitJSONBody
		assert.NoError(t, json.NewDecoder(r.Body).Decode(&body))
		captured = append(captured, body)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	orig := sandboxHttpClient
	sandboxHttpClient = http.Client{Timeout: 5 * time.Second}
	defer func() { sandboxHttpClient = orig }()

	for range 2 {
		resp, _, err := sbx.doRequestWithInfiniteRetries(t.Context(), http.MethodPost, server.URL+"/init")
		require.NoError(t, err)
		require.NoError(t, resp.Body.Close())
	}

	require.Len(t, captured, 2)
	for _, body := range captured {
		assert.Equal(t, "user", body.DefaultUser)
		assert.Equal(t, "/sandbox/tennr", body.DefaultWorkdir)
	}
}

func TestClassifyEnvdInitExit(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		err  error
		want envdInitExitType
	}{
		{"nil", nil, envdInitExitSuccess},
		{"deadline_exceeded", context.DeadlineExceeded, envdInitExitTimeout},
		{"wrapped_deadline", fmt.Errorf("init: %w", context.DeadlineExceeded), envdInitExitTimeout},
		{"wait_for_envd_timeout", ErrWaitForEnvdTimeout, envdInitExitTimeout},
		{
			"wrapped_wait_for_envd_timeout",
			// Mirrors doRequestWithInfiniteRetries: ctx.Err() is Canceled, the
			// cause is the timeout sentinel, both wrapped together.
			fmt.Errorf("%w with cause: %w", context.Canceled, ErrWaitForEnvdTimeout),
			envdInitExitTimeout,
		},
		{"canceled", context.Canceled, envdInitExitCanceled},
		{"wrapped_canceled", fmt.Errorf("init: %w", context.Canceled), envdInitExitCanceled},
		{"fc_process_exited", ErrFcProcessExited, envdInitExitOther},
		{
			"wrapped_fc_process_exited",
			// Mirrors doRequestWithInfiniteRetries: ctx.Err() is Canceled, the
			// cause is the fc-exit sentinel, both wrapped together. Must not be
			// misclassified as canceled.
			fmt.Errorf("%w with cause: %w", context.Canceled, ErrFcProcessExited),
			envdInitExitOther,
		},
		{"other", errors.New("connection refused"), envdInitExitOther},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			assert.Equal(t, tt.want, classifyEnvdInitExit(tt.err))
		})
	}
}

// mockEgressProxy is a test EgressProxy that returns a fixed CA bundle string.
type mockEgressProxy struct {
	network.NoopEgressProxy

	bundle string
}

func (m *mockEgressProxy) CABundle() string { return m.bundle }

// newTestSandboxWithBundle builds a minimal Sandbox with CABundle set —
// mirroring what Factory.CreateSandbox does with f.egressProxy.CABundle().
func newTestSandboxWithBundle(bundle string) *Sandbox {
	return &Sandbox{
		Metadata: &Metadata{
			internalConfig: internalConfig{EnvdInitRequestTimeout: 5 * time.Second},
			Config:         NewConfig(Config{}),
			Runtime:        RuntimeMetadata{SandboxID: "test-sandbox"},
		},
		CABundle: bundle,
	}
}

// TestEnvdInitSendsCaBundle verifies the full injection chain:
// EgressProxy.CABundle() → Sandbox.CABundle → POST /init body caBundle field.
//
// Not parallel: overrides the package-level sandboxHttpClient.
func TestEnvdInitSendsCaBundle(t *testing.T) { //nolint:paralleltest
	const pemBundle = "-----BEGIN CERTIFICATE-----\nPROXY\n-----END CERTIFICATE-----\n" +
		"-----BEGIN CERTIFICATE-----\nCUSTOM\n-----END CERTIFICATE-----\n"

	proxy := &mockEgressProxy{bundle: pemBundle}
	sbx := newTestSandboxWithBundle(proxy.CABundle())

	var captured envd.PostInitJSONBody
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, http.MethodPost, r.Method)
		assert.Equal(t, "/init", r.URL.Path)

		err := json.NewDecoder(r.Body).Decode(&captured)
		assert.NoError(t, err)

		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	orig := sandboxHttpClient
	sandboxHttpClient = http.Client{Timeout: 5 * time.Second}
	defer func() { sandboxHttpClient = orig }()

	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()

	resp, _, err := sbx.doRequestWithInfiniteRetries(ctx, http.MethodPost, server.URL+"/init")
	require.NoError(t, err)
	defer resp.Body.Close()

	assert.NotEmpty(t, captured.CaBundle, "caBundle should be non-empty")
	assert.Contains(t, captured.CaBundle, "-----BEGIN CERTIFICATE-----\nPROXY\n-----END CERTIFICATE-----")
	assert.Contains(t, captured.CaBundle, "-----BEGIN CERTIFICATE-----\nCUSTOM\n-----END CERTIFICATE-----")
}

func TestEnvdInitEmptyCaBundle(t *testing.T) { //nolint:paralleltest
	sbx := newTestSandboxWithBundle("")

	var captured envd.PostInitJSONBody
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&captured)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	orig := sandboxHttpClient
	sandboxHttpClient = http.Client{Timeout: 5 * time.Second}
	defer func() { sandboxHttpClient = orig }()

	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()

	resp, _, err := sbx.doRequestWithInfiniteRetries(ctx, http.MethodPost, server.URL+"/init")
	require.NoError(t, err)
	defer resp.Body.Close()

	assert.Empty(t, captured.CaBundle, "caBundle should be omitted when empty")
}
