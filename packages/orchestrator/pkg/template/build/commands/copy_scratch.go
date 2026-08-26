package commands

import (
	"errors"
	"path/filepath"
	"strings"
)

// copyScratchRoot is deliberately on the root filesystem. The guest mounts
// /tmp as tmpfs, so staging a large compressed layer and its expanded copy
// there caps COPY at roughly half of the build VM's RAM.
const copyScratchRoot = "/var/lib/e2b/template-build"

func copyScratchPaths(filesHash string) (scratchPath, archivePath, unpackPath string, err error) {
	if filesHash == "." || filesHash == ".." || filepath.Base(filesHash) != filesHash || strings.ContainsAny(filesHash, `/\\`) {
		return "", "", "", errors.New("files hash must be a single path component")
	}

	scratchPath = filepath.Join(copyScratchRoot, filesHash)
	archivePath = filepath.Join(scratchPath, "layer.tar.gz")
	unpackPath = filepath.Join(scratchPath, "unpack")

	return scratchPath, archivePath, unpackPath, nil
}
