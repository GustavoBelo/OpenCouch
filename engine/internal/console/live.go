package console

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// liveFile names the session the wrapper is running right now.
//
// It exists because the process that asks for a switch is killed by the switch
// it asked for, and so cannot watch for the result itself -- but it can watch
// long enough to know the request was taken up rather than swallowed. Verifying
// by effect matters: at least one compositor accepts a stop request, exits 0 and
// does nothing, and a caller trusting that exit code would report success and
// leave the user staring at an unchanged desktop.
//
// This is separate from the hosted marker on purpose. That one answers "is a
// wrapper alive", is written once per login and holds a PID that has to survive
// being read by a process which cannot trust it. This one answers "which session
// is running, and is it still the one I saw", and is rewritten on every switch.
// One file doing both would have to be correct about both at once.
const liveFile = "open-couch-live"

// Live is which session the wrapper is running, and how many it has run.
//
// Generation is what makes the answer usable. Without it a watcher cannot tell
// "the session I asked to end is still running" from "it ended and the next one
// started while I was not looking" -- the file exists and names a mode in both
// cases, and the switch takes well under the time it takes to notice.
type Live struct {
	Mode       Mode
	Generation int
}

func livePath(runtimeDir string) string { return filepath.Join(runtimeDir, liveFile) }

// WriteLive records the session about to start.
func WriteLive(runtimeDir string, live Live) error {
	if runtimeDir == "" {
		return nil
	}
	body := fmt.Sprintf("%s %d\n", live.Mode, live.Generation)
	return os.WriteFile(livePath(runtimeDir), []byte(body), 0o600)
}

// ClearLive removes the record. The wrapper does this when its loop ends, so a
// runtime directory that outlives the session does not claim one is running.
func ClearLive(runtimeDir string) { _ = os.Remove(livePath(runtimeDir)) }

// ReadLive reports the session the wrapper is running, if it says.
func ReadLive(runtimeDir string) (Live, bool) {
	data, err := os.ReadFile(livePath(runtimeDir))
	if err != nil {
		return Live{}, false
	}
	fields := strings.Fields(string(data))
	if len(fields) != 2 {
		return Live{}, false
	}
	generation, err := strconv.Atoi(fields[1])
	if err != nil {
		return Live{}, false
	}
	return Live{Mode: Mode(fields[0]), Generation: generation}, true
}

// AwaitSessionEnd waits for the session described by before to stop being the
// one that is running.
//
// Either answer is a real end: the file is gone because the wrapper's loop
// finished, or the generation moved because the next session already started.
func AwaitSessionEnd(ctx context.Context, runtimeDir string, before Live, within time.Duration) bool {
	deadline := time.Now().Add(within)
	for {
		current, ok := ReadLive(runtimeDir)
		if !ok || current.Generation != before.Generation {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		select {
		case <-ctx.Done():
			return false
		case <-time.After(200 * time.Millisecond):
		}
	}
}
