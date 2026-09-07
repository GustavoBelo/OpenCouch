package console

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"github.com/GustavoBelo/OpenCouch/engine/internal/atomicfile"
)

// A countdown the user did not ask for, left where the graphical app can find
// it.
//
// The notification is the warning for a machine with nobody watching the
// screen; the app's own countdown is the one that is already in front of
// somebody at a desk. Both have to show the same clock and either has to be
// able to call the whole thing off, and they are different processes, so the
// runtime directory is what they share -- the same channel the request and the
// cancel files already use.
const pendingFile = "open-couch-entry-pending"

// TriggerController is what asked, as a key rather than a sentence. The engine
// is not translated and the app is: it turns this into whatever language the
// user reads, and an English string travelling from here would arrive as the
// one untranslated line in the interface.
const TriggerController = "controller"

type PendingEntry struct {
	// Deadline is when the entry happens, in RFC 3339. A deadline rather than a
	// number of seconds: the app may read this a moment or a minute after it
	// was written, and a countdown that starts over on every read is not a
	// countdown.
	Deadline string `json:"deadline"`
	Trigger  string `json:"trigger"`
	Display  string `json:"display"`
}

func PendingPath(runtimeDir string) string { return filepath.Join(runtimeDir, pendingFile) }

func WritePending(runtimeDir string, entry PendingEntry) error {
	if runtimeDir == "" {
		return nil
	}
	data, err := json.Marshal(entry)
	if err != nil {
		return err
	}
	return atomicfile.Write(PendingPath(runtimeDir), append(data, '\n'), 0o600)
}

func ClearPending(runtimeDir string) {
	if runtimeDir == "" {
		return
	}
	_ = os.Remove(PendingPath(runtimeDir))
}

// ReadPending returns the announcement, if there is one that has not already
// run out. An expired file is ignored rather than deleted: the countdown that
// wrote it clears it when it ends, and a reader racing that would otherwise
// take the file away from a countdown still using it.
func ReadPending(runtimeDir string) (PendingEntry, bool) {
	data, err := os.ReadFile(PendingPath(runtimeDir))
	if err != nil {
		return PendingEntry{}, false
	}
	var entry PendingEntry
	if json.Unmarshal(data, &entry) != nil {
		return PendingEntry{}, false
	}
	deadline, err := time.Parse(time.RFC3339, entry.Deadline)
	if err != nil || !time.Now().Before(deadline) {
		return PendingEntry{}, false
	}
	return entry, true
}
