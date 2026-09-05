package console

import (
	"os"
	"path/filepath"
	"strings"
	"time"
)

// StateDir is where the wrapper keeps what has to survive a session switch.
//
// The process that asks for a switch is killed by the switch it asked for, so
// nothing can be held in memory. Both the wrapper and the daemon read this, and
// they have to agree about where it is.
func StateDir() (string, error) {
	dir, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	dir = filepath.Join(dir, "open-couch")
	return dir, os.MkdirAll(dir, 0o755)
}

// failureFile is how the wrapper leaves word that the console did not start.
const failureFile = "console-failure"

// failureMaxAge is how long the news is still news.
//
// The wrapper writes this immediately before starting the desktop, and the
// daemon starts with that desktop, so it is read within seconds. Anything much
// older belongs to a session that has already been left behind -- a machine
// switched off before the daemon ever ran, say -- and announcing it days later
// would be a popup about something the user has long since worked around.
const failureMaxAge = 10 * time.Minute

func failurePath(stateDir string) string { return filepath.Join(stateDir, failureFile) }

// RecordFailure leaves word that the console session could not be started.
//
// It exists because there is nobody to tell at the moment it happens. The
// desktop compositor has already been stopped, which takes the notification
// server with it, so a notification sent here goes nowhere. What the user sees
// instead is their desktop restart with everything they had open gone and no
// explanation -- and the only account of it in a log file they have no reason to
// know exists.
func RecordFailure(stateDir, reason string) {
	if stateDir == "" {
		return
	}
	if reason = strings.TrimSpace(reason); reason == "" {
		return
	}
	_ = os.WriteFile(failurePath(stateDir), []byte(reason+"\n"), 0o600)
}

// TakeFailure returns what the wrapper left behind, and clears it.
//
// Clearing is the point: the news is worth one notification, not one per poll
// for the rest of the session.
func TakeFailure(stateDir string) (string, bool) {
	if stateDir == "" {
		return "", false
	}
	path := failurePath(stateDir)
	info, err := os.Stat(path)
	if err != nil {
		return "", false
	}
	data, err := os.ReadFile(path)
	_ = os.Remove(path)
	if err != nil || time.Since(info.ModTime()) > failureMaxAge {
		return "", false
	}
	reason := strings.TrimSpace(string(data))
	return reason, reason != ""
}
