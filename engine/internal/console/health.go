package console

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/GustavoBelo/OpenCouch/engine/internal/atomicfile"
)

// The hosting session is what the machine logs into, so anything that makes
// `host-session` exit in seconds makes the login collapse in seconds -- and on
// a greeter with no session picker, or with autologin, the machine offers the
// same broken session straight back. The short-run guard in session.go catches
// a restart storm inside one login; it cannot catch the storm that spans logins
// and reboots, because it counts in memory and every login starts it at zero.
//
// This is that counter, kept on disk. After enough logins that ended before
// they began, the wrapper hosts only the desktop -- a way in from which the
// setup can be fixed -- and says so, until a login lasts.

const (
	// hostHealthFile records when the hosting session has started and when it
	// last reached a login that worked. It lives in the state directory, not
	// the runtime one: the failure it exists for is a reboot loop, and the
	// runtime directory is wiped by the reboot that would reset the count.
	hostHealthFile = "host-health.json"

	// safeModeFile is present while the console is being withheld after a run
	// of failed logins. Unlike console-failure it is not read-once: `status`
	// reports it on every poll until a clean login clears it.
	safeModeFile = "safe-mode"

	// disabledMarker turns the console off without touching anything root owns.
	// It lives in the user's own config directory, so `open-couch-engine
	// disable` is a recovery that needs no password -- unlike removing the
	// session entry a login manager reads.
	disabledMarker = "disabled"
)

const (
	// failLoginWindow is how far back a run of failed logins still counts.
	// Long enough to span a few reboots, short enough that yesterday's trouble
	// does not hold the console back today.
	failLoginWindow = 10 * time.Minute
	// failLoginLimit is how many logins may die inside that window before the
	// wrapper stops offering the console. Three, not one: a television that is
	// slow to wake can lose the first switch on its own, and one short login is
	// not yet a pattern.
	failLoginLimit = 3
	// healthyRun is how long a desktop session has to last to count as a login
	// that worked. A wrapper that has hosted a desktop this long has given the
	// user somewhere to fix things from, which is all safe mode is protecting.
	healthyRun = 45 * time.Second
	// hostStartsKept caps the timestamps kept in the health file. Only the last
	// failLoginLimit decide anything; a few more are kept so the file still
	// reads sensibly by hand.
	hostStartsKept = 10
)

// hostHealth is the record behind safe mode.
type hostHealth struct {
	// Starts is when the hosting session has begun, oldest first.
	Starts []time.Time `json:"starts"`
	// LastGood is when a login last lasted long enough to fix things from.
	LastGood time.Time `json:"last_good,omitempty"`
}

func hostHealthPath(stateDir string) string { return filepath.Join(stateDir, hostHealthFile) }

// loadHostHealth reads the record, treating anything unreadable as no history.
// A corrupt file loses the streak rather than holding the console hostage: the
// in-memory short-run guard is still the backstop, and the next start rebuilds
// the count if the machine really is looping.
func loadHostHealth(stateDir string) hostHealth {
	var h hostHealth
	data, err := os.ReadFile(hostHealthPath(stateDir))
	if err != nil {
		return h
	}
	_ = json.Unmarshal(data, &h)
	return h
}

func saveHostHealth(stateDir string, h hostHealth) {
	data, err := json.MarshalIndent(h, "", "  ")
	if err != nil {
		return
	}
	_ = atomicfile.Write(hostHealthPath(stateDir), append(data, '\n'), 0o600)
}

// RecordHostStart notes that the hosting session has just begun. Called once,
// at the top of the wrapper, before anything can go wrong.
func RecordHostStart(stateDir string, now time.Time) {
	if stateDir == "" {
		return
	}
	h := loadHostHealth(stateDir)
	h.Starts = append(h.Starts, now.UTC())
	sort.Slice(h.Starts, func(i, j int) bool { return h.Starts[i].Before(h.Starts[j]) })
	if len(h.Starts) > hostStartsKept {
		h.Starts = h.Starts[len(h.Starts)-hostStartsKept:]
	}
	saveHostHealth(stateDir, h)
}

// RecordHostHealthy notes that a login has worked: a desktop stayed up long
// enough to fix things from. It clears the run of failures and lifts safe mode,
// which is how the console comes back on its own after one login that lasts
// with the console available.
func RecordHostHealthy(stateDir string, now time.Time) {
	if stateDir == "" {
		return
	}
	saveHostHealth(stateDir, hostHealth{LastGood: now.UTC()})
	ClearSafeMode(stateDir)
}

// ClearHostStreak wipes the run of recent starts without recording a login that
// worked and without touching the safe-mode breadcrumb.
//
// It is what a desktop forced by safe mode does once it has lasted: enough to
// let the next login offer the console again, not enough to say the trouble is
// over -- so `status` keeps reporting safe mode until a login that had the
// console on the table still lasts.
func ClearHostStreak(stateDir string) {
	if stateDir == "" {
		return
	}
	h := loadHostHealth(stateDir)
	if len(h.Starts) == 0 {
		return
	}
	h.Starts = nil
	saveHostHealth(stateDir, h)
}

// SafeModeReason reports whether the hosting session should hold the console
// back because recent logins have been ending on their own, and why.
//
// A start counts against the machine when it is newer than the last login that
// worked and falls inside failLoginWindow. failLoginLimit of those and the
// wrapper hosts only the desktop until a login lasts.
func SafeModeReason(stateDir string, now time.Time) (string, bool) {
	if stateDir == "" {
		return "", false
	}
	h := loadHostHealth(stateDir)
	recent := 0
	for _, start := range h.Starts {
		if !h.LastGood.IsZero() && !start.After(h.LastGood) {
			continue
		}
		if now.Sub(start) > failLoginWindow {
			continue
		}
		recent++
	}
	if recent < failLoginLimit {
		return "", false
	}
	return fmt.Sprintf("%d logins in a row ended within seconds", recent), true
}

// safeMode is what `status` reports while the console is held back.
type safeMode struct {
	Reason string    `json:"reason"`
	Since  time.Time `json:"since"`
}

func safeModePath(stateDir string) string { return filepath.Join(stateDir, safeModeFile) }

// WriteSafeMode records that the console is being held back, and why. It is
// rewritten rather than appended, and left in place: `status` shows it on every
// poll until RecordHostHealthy or `enable` clears it.
func WriteSafeMode(stateDir, reason string, now time.Time) {
	if stateDir == "" || strings.TrimSpace(reason) == "" {
		return
	}
	data, err := json.MarshalIndent(safeMode{Reason: reason, Since: now.UTC()}, "", "  ")
	if err != nil {
		return
	}
	_ = atomicfile.Write(safeModePath(stateDir), append(data, '\n'), 0o600)
}

// ReadSafeMode returns why the console is held back, or ok=false when it is not.
// It does not clear the file -- that is the job of the login that earns it back.
func ReadSafeMode(stateDir string) (reason string, since time.Time, ok bool) {
	if stateDir == "" {
		return "", time.Time{}, false
	}
	data, err := os.ReadFile(safeModePath(stateDir))
	if err != nil {
		return "", time.Time{}, false
	}
	var s safeMode
	if err := json.Unmarshal(data, &s); err != nil || strings.TrimSpace(s.Reason) == "" {
		return "", time.Time{}, false
	}
	return s.Reason, s.Since, true
}

// ClearSafeMode lets the console be offered again.
func ClearSafeMode(stateDir string) {
	if stateDir == "" {
		return
	}
	_ = os.Remove(safeModePath(stateDir))
}

// DisabledMarkerPath is the file `open-couch-engine disable` writes.
func DisabledMarkerPath(baseDir string) string { return filepath.Join(baseDir, disabledMarker) }

// IsDisabled reports whether the console has been switched off with
// `open-couch-engine disable`.
func IsDisabled(baseDir string) bool {
	_, err := os.Stat(DisabledMarkerPath(baseDir))
	return err == nil
}

// SetDisabled writes or removes the disabled marker.
func SetDisabled(baseDir string, off bool) error {
	path := DisabledMarkerPath(baseDir)
	if !off {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}
	return atomicfile.Write(path, []byte(time.Now().UTC().Format(time.RFC3339)+"\n"), 0o644)
}
