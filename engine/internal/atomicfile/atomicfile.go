// Package atomicfile writes a file in one step, so a reader never sees a
// half-written one.
//
// Adapted from hyprmoncfg's internal/config, which is MIT-licensed and by the
// same author. Copyright (c) 2026 Gustavo Belo.
package atomicfile

import (
	"os"
	"path/filepath"
	"strings"
)

// Write replaces the file at path with content, atomically.
func Write(path string, content []byte, perm os.FileMode) error {
	// Write through a symlink rather than over it. Dotfile managers point
	// config directories at a file they own, and renaming onto the link would
	// silently replace their link with a plain file of ours.
	path = resolveSymlink(path)

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	tmp, err := os.CreateTemp(filepath.Dir(path), ".open-couch-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)

	if _, err := tmp.Write(content); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(perm); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpPath, path)
}

// resolveSymlink returns what path points at, or path itself when it is not a
// link or cannot be resolved.
func resolveSymlink(path string) string {
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil || strings.TrimSpace(resolved) == "" {
		return path
	}
	return resolved
}
