//go:build linux

package commands

import (
	"bytes"
	"context"
	_ "embed"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	txtTemplate "text/template"
	"time"

	"github.com/bmatcuk/doublestar/v4"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"

	"github.com/e2b-dev/infra/packages/orchestrator/pkg/proxy"
	"github.com/e2b-dev/infra/packages/orchestrator/pkg/template/build/sandboxtools"
	"github.com/e2b-dev/infra/packages/orchestrator/pkg/template/build/storage/paths"
	"github.com/e2b-dev/infra/packages/orchestrator/pkg/template/metadata"
	templatemanager "github.com/e2b-dev/infra/packages/shared/pkg/grpc/template-manager"
	"github.com/e2b-dev/infra/packages/shared/pkg/logger"
	"github.com/e2b-dev/infra/packages/shared/pkg/storage"
	"github.com/e2b-dev/infra/packages/shared/pkg/utils"
)

type Copy struct {
	FilesStorage storage.StorageProvider
	CacheScope   string
}

var _ Command = (*Copy)(nil)

const copyCleanupTimeout = 30 * time.Second

type copyScriptData struct {
	SourcePath  string
	TargetPath  string
	Owner       string
	Permissions string

	// Workdir is the working directory for the target path resolution if relative.
	Workdir string
	// User is used for filling the workdir if empty.
	User string
}

//go:embed copy_script.sh
var copyScriptFile string
var copyScriptTemplate = txtTemplate.Must(txtTemplate.New("copy-script-template").Parse(copyScriptFile))

// Execute implements the Copy command.
// It works in the following steps:
// 1) Downloads the layer tar file from the storage to the local filesystem
// 2) Copies the file to a rootfs-backed scratch directory in the sandbox
// 3) Extracts it in that scratch directory and removes the compressed archive
// 4) Moves the extracted files to the target path in the sandbox
//   - If the source is a file, it creates the parent directories and moves the file
//   - If the source is a directory, it merges its contents into the target
//     directory (Docker COPY semantics: existing directories are merged into,
//     existing files are overwritten)

// The scratch directory is removed explicitly because it is part of the rootfs
// and would otherwise be captured in the resulting template layer.
func (c *Copy) Execute(
	ctx context.Context,
	logger logger.Logger,
	_ zapcore.Level,
	proxy *proxy.SandboxProxy,
	sandboxID string,
	_ string,
	step *templatemanager.TemplateStep,
	cmdMetadata metadata.Context,
) (metadata.Context, error) {
	cmdType := strings.ToUpper(step.GetType())
	args, err := parseCopyArgs(step.GetArgs(), cmdMetadata.User)
	if err != nil {
		return metadata.Context{}, err
	}

	if step.FilesHash == nil || step.GetFilesHash() == "" {
		return metadata.Context{}, fmt.Errorf("%s requires files hash to be set", cmdType)
	}

	sbxScratchPath, sbxTargetPath, sbxUnpackPath, err := copyScratchPaths(step.GetFilesHash())
	if err != nil {
		return metadata.Context{}, fmt.Errorf("invalid files hash for %s: %w", cmdType, err)
	}

	// 1) Download the layer tar file from the storage to the local filesystem
	obj, err := c.FilesStorage.OpenBlob(ctx, paths.GetLayerFilesCachePath(c.CacheScope, step.GetFilesHash()))
	if err != nil {
		return metadata.Context{}, fmt.Errorf("failed to open files object from storage: %w", err)
	}

	pr, pw := io.Pipe()
	// Start writing tar data to the pipe writer in a goroutine
	go func() {
		defer pw.Close()
		if _, err := obj.WriteTo(ctx, pw); err != nil {
			pw.CloseWithError(err)
		}
	}()

	tmpFile, err := os.CreateTemp("", "layer-file-*.tar")
	if err != nil {
		return metadata.Context{}, fmt.Errorf("failed to create temporary file for layer tar: %w", err)
	}
	defer os.Remove(tmpFile.Name())
	defer tmpFile.Close()

	_, err = io.Copy(tmpFile, pr)
	if err != nil {
		return metadata.Context{}, fmt.Errorf("failed to copy layer tar data to temporary file: %w", err)
	}

	// Create rootfs-backed scratch space and report both filesystems before the
	// upload. These diagnostics make it explicit that COPY capacity comes from /
	// rather than the RAM-backed /tmp mount.
	err = sandboxtools.RunCommandWithLogger(
		ctx,
		proxy,
		logger,
		zapcore.InfoLevel,
		"copy-space-before",
		sandboxID,
		fmt.Sprintf(`mkdir -p "%s" && df -Pk / /tmp`, sbxScratchPath),
		cmdMetadata.WithUser("root"),
	)
	if err != nil {
		return metadata.Context{}, fmt.Errorf("failed to prepare COPY scratch space: %w", err)
	}

	cleanupNeeded := true
	defer func() {
		if !cleanupNeeded {
			return
		}

		cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), copyCleanupTimeout)
		defer cancel()
		if cleanupErr := sandboxtools.RunCommand(
			cleanupCtx,
			proxy,
			sandboxID,
			fmt.Sprintf(`rm -rf -- "%s"`, sbxScratchPath),
			cmdMetadata.WithUser("root"),
		); cleanupErr != nil && logger != nil {
			logger.Warn(cleanupCtx, "failed to clean COPY scratch space", zap.Error(cleanupErr), zap.String("path", sbxScratchPath))
		}
	}()

	// 2) Copy the tar file to the sandbox rootfs scratch directory.
	err = sandboxtools.CopyFile(ctx, proxy, sandboxID, "root", tmpFile.Name(), sbxTargetPath)
	if err != nil {
		return metadata.Context{}, fmt.Errorf("failed to copy layer tar data to sandbox: %w", err)
	}

	// 3) Extract on the rootfs, then immediately remove the compressed archive.
	// The expanded tree remains for Docker-compatible merge semantics in step 4.
	err = sandboxtools.RunCommand(
		ctx,
		proxy,
		sandboxID,
		fmt.Sprintf(`mkdir -p "%s" && tar -xzf "%s" -C "%s" && rm -f -- "%s"`, sbxUnpackPath, sbxTargetPath, sbxUnpackPath, sbxTargetPath),
		cmdMetadata.WithUser("root"),
	)
	if err != nil {
		return metadata.Context{}, fmt.Errorf("failed to extract files: %w", err)
	}
	err = sandboxtools.RunCommandWithLogger(
		ctx,
		proxy,
		logger,
		zapcore.InfoLevel,
		"copy-space-after-extract",
		sandboxID,
		`df -Pk / /tmp`,
		cmdMetadata.WithUser("root"),
	)
	if err != nil {
		return metadata.Context{}, fmt.Errorf("failed to report COPY space after extraction: %w", err)
	}

	var moveScript bytes.Buffer
	err = copyScriptTemplate.Execute(&moveScript, copyScriptData{
		Workdir: utils.DerefOrDefault(cmdMetadata.WorkDir, ""),
		User:    cmdMetadata.User,

		SourcePath: filepath.Join(sbxUnpackPath, args.SourcePath),
		TargetPath: args.TargetPath,
		Owner:      args.Owner,
		// Optional permissions
		Permissions: args.Permissions,
	})
	if err != nil {
		return metadata.Context{}, fmt.Errorf("failed to execute copy script template: %w", err)
	}

	// Run the move script as root so it can chown files to any user
	// The script handles both ownership and permissions on the source before moving
	err = sandboxtools.RunCommandWithLogger(
		ctx,
		proxy,
		logger,
		zapcore.DebugLevel,
		"unpack",
		sandboxID,
		moveScript.String(),
		cmdMetadata.WithUser("root"),
	)
	if err != nil {
		return metadata.Context{}, fmt.Errorf("failed to move files in sandbox: %w", err)
	}

	// Rootfs-backed scratch survives a sandbox restart, so successful cleanup is
	// part of COPY correctness. Also emit the final rootfs/tmpfs capacity after
	// the target contains the copied data.
	err = sandboxtools.RunCommandWithLogger(
		ctx,
		proxy,
		logger,
		zapcore.InfoLevel,
		"copy-space-after-cleanup",
		sandboxID,
		fmt.Sprintf(`rm -rf -- "%s" && df -Pk / /tmp`, sbxScratchPath),
		cmdMetadata.WithUser("root"),
	)
	if err != nil {
		return metadata.Context{}, fmt.Errorf("failed to clean COPY scratch space: %w", err)
	}
	cleanupNeeded = false

	return cmdMetadata, nil
}

func ensureTrailingSlash(s string) string {
	if strings.HasSuffix(s, "/") {
		return s
	}

	return s + "/"
}

type copyArgs struct {
	SourcePath  string
	TargetPath  string
	Owner       string
	Permissions string
}

func parseCopyArgs(args []string, defaultUser string) (*copyArgs, error) {
	// Validate minimum arguments
	// args: [localPath containerPath optional_owner optional_permissions]
	if len(args) < 2 {
		return nil, errors.New("COPY requires a local path and a container path argument")
	}

	// Remove all glob patterns, they are handled on the client side already
	// Add / always at the end to ensure the last file/directory is also included if it doesn't contain a glob pattern
	sourcePath, _ := doublestar.SplitPattern(ensureTrailingSlash(args[0]))

	// Parse target path
	targetPath := args[1]

	// Determine owner (default to defaultUser:defaultUser)
	owner := fmt.Sprintf("%s:%s", defaultUser, defaultUser)
	if len(args) >= 3 && args[2] != "" {
		owner = args[2]
		// If no group specified, use the same as user
		if !strings.Contains(owner, ":") {
			owner = fmt.Sprintf("%s:%s", owner, owner)
		}
	}

	// Parse optional permissions
	permissions := ""
	if len(args) >= 4 {
		permissions = args[3]
	}

	return &copyArgs{
		SourcePath:  sourcePath,
		TargetPath:  targetPath,
		Owner:       owner,
		Permissions: permissions,
	}, nil
}
