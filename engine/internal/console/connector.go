package console

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// DRMRoot is where the kernel publishes connector state. A variable so tests
// can point it at a fixture.
var DRMRoot = "/sys/class/drm"

// ConnectorReady reports whether a display is present and has told the kernel
// what it can do.
//
// Both halves matter. "connected" alone appears before the EDID has been read,
// and a connector with no modes is one gamescope will enumerate and then refuse
// to select.
func ConnectorReady(root, connector string) bool {
	if strings.TrimSpace(connector) == "" {
		return false
	}
	dirs, err := filepath.Glob(filepath.Join(root, "card*-"+connector))
	if err != nil {
		return false
	}
	for _, dir := range dirs {
		status, err := os.ReadFile(filepath.Join(dir, "status"))
		if err != nil || strings.TrimSpace(string(status)) != "connected" {
			continue
		}
		modes, err := os.ReadFile(filepath.Join(dir, "modes"))
		if err != nil || strings.TrimSpace(string(modes)) == "" {
			continue
		}
		return true
	}
	return false
}

// AwaitConnector waits for a display to be ready to drive.
//
// This exists because of a black screen that cost an evening. Booting straight
// into the console started gamescope six seconds after the driver loaded, before
// the displays had presented themselves; gamescope enumerated the connectors,
// found none it could use, and -- this is the part that turns a slow start into a
// dead machine -- never looked again. It sat there until a physical replug
// produced a KMS change event six minutes later. The same boot on a slower path,
// where the desktop came up first, was fine.
//
// Waiting is cheap and only happens on the way into the console. Giving up after
// the deadline is deliberate: a TV that is switched off never becomes ready, and
// refusing to start the console for that reason would be worse than starting it
// on a display the user is about to switch on.
func AwaitConnector(ctx context.Context, connector string, within time.Duration, logf func(string, ...any)) bool {
	if connector == "" || ConnectorReady(DRMRoot, connector) {
		return true
	}
	if logf != nil {
		logf("console: waiting for %s to be ready", connector)
	}
	deadline := time.Now().Add(within)
	for {
		select {
		case <-ctx.Done():
			return false
		case <-time.After(200 * time.Millisecond):
		}
		if ConnectorReady(DRMRoot, connector) {
			if logf != nil {
				logf("console: %s is ready", connector)
			}
			return true
		}
		if time.Now().After(deadline) {
			if logf != nil {
				logf("console: %s never became ready; starting anyway", connector)
			}
			return false
		}
	}
}
