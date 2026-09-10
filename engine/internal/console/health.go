package console

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"syscall"
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
// host-health.json is that counter, kept on disk. SafeModeReason reads it and is
// the single answer to "is the console being held back": the wrapper decides the
// hold from it at login, and `status`, `doctor` and the `enter` gate report from
// the same call, so none of them can disagree.

const (
	// hostHealthFile records when the hosting session has started and when it
	// last reached a login that worked. It lives in the state directory, not
	// the runtime one: the failure it exists for is a reboot loop, and the
	// runtime directory is wiped by the reboot that would reset the count.
	hostHealthFile = "host-health.json"

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
	// failLoginLimit is how many logins may end early inside that window before
	// the wrapper stops offering the console. Three, not one: a television that
	// is slow to wake can lose the first switch on its own, and one short login
	// is not yet a pattern.
	failLoginLimit = 3
	// healthyRun is how long a session has to last to count as a login that
	// worked. A wrapper that has hosted this long has given the user somewhere
	// to fix things from, which is all safe mode is protecting.
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
	// LastGood is when a login last lasted long enough to fix things from. A
	// pointer so a machine that has never had one leaves the field out of the
	// file rather than carrying a zero timestamp -- omitempty does not fire on
	// a plain time.Time.
	LastGood *time.Time `json:"last_good,omitempty"`
}

func hostHealthPath(stateDir string) string { return filepath.Join(stateDir, hostHealthFile) }

// withHostHealthLock serialises a read-modify-write of host-health.json against
// a concurrent write from an overlapping session -- a display manager hands the
// next login over before the last one has unwound, and the outgoing wrapper's
// healthy-timer can fire at the same moment the incoming one records its start.
func withHostHealthLock(stateDir string, fn func()) {
	lock, err := os.OpenFile(filepath.Join(stateDir, hostHealthFile+".lock"),
		os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		fn()
		return
	}
	defer lock.Close()
	if syscall.Flock(int(lock.Fd()), syscall.LOCK_EX) == nil {
		defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	}
	fn()
}

// loadHostHealth reads the record, treating anything unreadable as no history.
// A corrupt file loses the streak rather than holding the console hostage: the
// in-memory short-run guard is still the backstop, and the next start rebuilds
// the count if the machine really is looping.
func loadHostHealth(stateDir string) hostHealth {
	data, err := os.ReadFile(hostHealthPath(stateDir))
	if err != nil {
		return hostHealth{}
	}
	var h hostHealth
	if err := json.Unmarshal(data, &h); err != nil {
		return hostHealth{}
	}
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
// at the top of the wrapper, before anything can go wrong -- and only when it
// meant to offer the console, never for a `disable`d login.
func RecordHostStart(stateDir string, now time.Time) {
	if stateDir == "" {
		return
	}
	withHostHealthLock(stateDir, func() {
		h := loadHostHealth(stateDir)
		h.Starts = append(h.Starts, now.UTC())
		sort.Slice(h.Starts, func(i, j int) bool { return h.Starts[i].Before(h.Starts[j]) })
		if len(h.Starts) > hostStartsKept {
			h.Starts = h.Starts[len(h.Starts)-hostStartsKept:]
		}
		saveHostHealth(stateDir, h)
	})
}

// RecordHostHealthy notes that a login has worked: a session stayed up long
// enough to fix things from. It clears the run of failed starts, which is how
// the console comes back on its own -- a normal login the moment it passes
// healthyRun, a login safe mode forced only when it logs out having lasted.
func RecordHostHealthy(stateDir string, now time.Time) {
	if stateDir == "" {
		return
	}
	t := now.UTC()
	withHostHealthLock(stateDir, func() {
		saveHostHealth(stateDir, hostHealth{LastGood: &t})
	})
}

// SafeModeReason reports whether the console should be held back because recent
// logins have been ending on their own, and why. It is the one source of truth:
// the wrapper holds the desktop when it trips, and `status` / `doctor` / the
// `enter` gate refuse from the same call.
//
// A start counts against the machine when it is newer than the last login that
// worked and falls inside failLoginWindow. failLoginLimit of those and the
// console is held until a login lasts.
func SafeModeReason(stateDir string, now time.Time) (string, bool) {
	if stateDir == "" {
		return "", false
	}
	h := loadHostHealth(stateDir)
	recent := 0
	for _, start := range h.Starts {
		if h.LastGood != nil && !start.After(*h.LastGood) {
			continue
		}
		// The window drops trouble from before today. It is by wall clock,
		// which is routinely wrong on an early-boot reboot loop -- exactly what
		// this guards -- so an age that is negative (clock stepped back) or
		// absurd (stepped forward) is treated as recent rather than discarding
		// a real failure. Only a plausible, positive age is aged out.
		if age := now.Sub(start); age > failLoginWindow && age < 24*time.Hour {
			continue
		}
		recent++
	}
	if recent < failLoginLimit {
		return "", false
	}
	return fmt.Sprintf("%d logins in a row ended early", recent), true
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
