package console

import (
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

// The short-run guard in session.go counts in memory and starts every login at
// zero, so it never sees a machine that reboots straight back into a session
// that dies in seconds. This is the count that survives the reboot.
func TestSafeModeTripsAfterAStreakOfFailedLogins(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	for i := failLoginLimit; i > 0; i-- {
		RecordHostStart(dir, now.Add(-time.Duration(i)*time.Minute))
	}

	reason, tripped := SafeModeReason(dir, now)
	if !tripped {
		t.Fatalf("%d logins in %s did not trip safe mode", failLoginLimit, failLoginWindow)
	}
	if reason == "" {
		t.Error("safe mode tripped with nothing to tell the user")
	}
}

// One or two short logins are not a pattern: a television that is slow to wake
// can lose the first switch on its own.
func TestSafeModeHoldsBelowTheLimit(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	for i := 0; i < failLoginLimit-1; i++ {
		RecordHostStart(dir, now.Add(-time.Duration(i)*time.Minute))
	}
	if _, tripped := SafeModeReason(dir, now); tripped {
		t.Errorf("safe mode tripped on only %d failed logins", failLoginLimit-1)
	}
}

// A login that worked clears the slate: starts recorded before it do not count.
func TestSafeModeIgnoresStartsBeforeTheLastGoodLogin(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	for i := 10; i >= 6; i-- {
		RecordHostStart(dir, now.Add(-time.Duration(i)*time.Minute))
	}
	RecordHostHealthy(dir, now.Add(-5*time.Minute))
	// One more failed start since, which is not a streak.
	RecordHostStart(dir, now.Add(-time.Minute))

	if _, tripped := SafeModeReason(dir, now); tripped {
		t.Error("starts from before a login that worked were counted against the machine")
	}
}

// Yesterday's trouble should not hold the console back today.
func TestSafeModeIgnoresStartsOutsideTheWindow(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	for i := 0; i < failLoginLimit+1; i++ {
		RecordHostStart(dir, now.Add(-failLoginWindow-time.Duration(i)*time.Minute))
	}
	if _, tripped := SafeModeReason(dir, now); tripped {
		t.Error("stale starts outside the window tripped safe mode")
	}
}

// A login that worked -- a normal one at HealthyRun, a held one at logout, or
// `enable` -- wipes the run of failed starts, and safe mode goes with it because
// it is only ever that run being counted.
func TestRecordHostHealthyClearsTheStreak(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	for i := failLoginLimit; i > 0; i-- {
		RecordHostStart(dir, now.Add(-time.Duration(i)*time.Minute))
	}
	if _, tripped := SafeModeReason(dir, now); !tripped {
		t.Fatal("the streak did not trip to begin with")
	}

	RecordHostHealthy(dir, now)

	if _, tripped := SafeModeReason(dir, now); tripped {
		t.Error("the streak survived a login that worked")
	}
}

// The file is read by hand when something is wrong, so it must not grow without
// bound; only the last few starts decide anything anyway.
func TestRecordHostStartTrimsHistory(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	for i := 0; i < hostStartsKept+5; i++ {
		RecordHostStart(dir, now.Add(time.Duration(i)*time.Second))
	}
	h := loadHostHealth(dir)
	if len(h.Starts) != hostStartsKept {
		t.Fatalf("kept %d starts, want %d", len(h.Starts), hostStartsKept)
	}
	// The ones kept are the newest.
	if h.Starts[0].Before(now.Add(4 * time.Second)) {
		t.Errorf("trimmed the newest starts instead of the oldest: %v", h.Starts)
	}
}

// A half-written file must lose the streak, not load a partial one and still
// trip -- the in-memory short-run guard is the backstop, and the next start
// rebuilds the count if the machine really is looping.
func TestLoadHostHealthOnCorruptFile(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(hostHealthPath(dir), []byte(`{"starts": ["2026`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, tripped := SafeModeReason(dir, time.Now()); tripped {
		t.Error("a truncated host-health.json tripped safe mode")
	}
	if h := loadHostHealth(dir); len(h.Starts) != 0 || h.LastGood != nil {
		t.Errorf("corrupt file did not load as empty: %+v", h)
	}
}

// The window is by wall clock, which is routinely wrong on an early-boot reboot
// loop before NTP. A failure whose age reads negative (clock went back) or
// absurd (jumped forward) must still count; only a plausible, positive age past
// the window is aged out.
func TestSafeModeCountsFailuresThroughClockSteps(t *testing.T) {
	now := time.Now()

	future := t.TempDir()
	for i := 0; i < failLoginLimit; i++ {
		RecordHostStart(future, now.Add(time.Hour))
	}
	if _, tripped := SafeModeReason(future, now); !tripped {
		t.Error("failures timestamped in the future (clock stepped back) were discarded")
	}

	// A clock that has not been set yet is wrong by the epoch, not by an
	// afternoon: these are the starts of a real loop, written before the machine
	// knew what time it was.
	unset := t.TempDir()
	for i := 0; i < failLoginLimit; i++ {
		RecordHostStart(unset, time.Unix(0, 0))
	}
	if _, tripped := SafeModeReason(unset, now); !tripped {
		t.Error("failures from a clock that had never been set were discarded")
	}
}

// The other side of that line. A start a few days old is a start a few days
// old, not a clock that is lying, and three short logins spread across a week
// are not a loop. Keeping anything past a day counted an ordinary short login
// from Tuesday against one on Friday, and held the console back over it.
func TestSafeModeAgesOutStartsFromEarlierDays(t *testing.T) {
	now := time.Now()
	dir := t.TempDir()
	for _, age := range []time.Duration{72 * time.Hour, 48 * time.Hour, 24*time.Hour + time.Minute} {
		RecordHostStart(dir, now.Add(-age))
	}
	if _, tripped := SafeModeReason(dir, now); tripped {
		t.Error("three short logins spread over days tripped safe mode")
	}
}

// `last_good` is what clears the streak, so the starts can stay -- and they
// have to, because the file is what a person reads when the machine is
// misbehaving and a lone timestamp explains nothing.
func TestRecordHostHealthyKeepsTheHistory(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	for i := failLoginLimit; i > 0; i-- {
		RecordHostStart(dir, now.Add(-time.Duration(i)*time.Minute))
	}

	RecordHostHealthy(dir, now)

	h := loadHostHealth(dir)
	if h.LastGood == nil {
		t.Fatal("the login that worked was not recorded")
	}
	if len(h.Starts) != failLoginLimit {
		t.Errorf("kept %d starts, want the %d already on file", len(h.Starts), failLoginLimit)
	}
	if _, tripped := SafeModeReason(dir, now); tripped {
		t.Error("the streak survived a login that worked")
	}
}

// The panel says the hold in the user's own language, so it needs the number
// the engine's English sentence is built from.
func TestSafeModeLoginsIsTheNumberInTheSentence(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	if n := SafeModeLogins(dir, now); n != 0 {
		t.Errorf("SafeModeLogins = %d on a machine that is not held, want 0", n)
	}
	for i := failLoginLimit; i > 0; i-- {
		RecordHostStart(dir, now.Add(-time.Duration(i)*time.Minute))
	}
	n := SafeModeLogins(dir, now)
	if n != failLoginLimit {
		t.Fatalf("SafeModeLogins = %d, want %d", n, failLoginLimit)
	}
	if reason, _ := SafeModeReason(dir, now); !strings.Contains(reason, strconv.Itoa(n)) {
		t.Errorf("the sentence %q does not carry the number %d", reason, n)
	}
}

// A wrapper may have no state directory; none of this may panic on one.
func TestHealthIsQuietWithNoStateDir(t *testing.T) {
	RecordHostStart("", time.Now())
	RecordHostHealthy("", time.Now())
	if _, tripped := SafeModeReason("", time.Now()); tripped {
		t.Error("an empty state dir tripped safe mode")
	}
}

// `open-couch-engine disable` is the recovery that needs no root: a marker in
// the user's own config directory, gone again on `enable`.
func TestDisabledMarker(t *testing.T) {
	base := t.TempDir()
	if IsDisabled(base) {
		t.Fatal("a fresh config directory reads as disabled")
	}
	if err := SetDisabled(base, true); err != nil {
		t.Fatal(err)
	}
	if !IsDisabled(base) {
		t.Error("SetDisabled(true) did not take")
	}
	if err := SetDisabled(base, false); err != nil {
		t.Fatal(err)
	}
	if IsDisabled(base) {
		t.Error("SetDisabled(false) left the marker behind")
	}
	// Removing one that is not there is not an error.
	if err := SetDisabled(base, false); err != nil {
		t.Errorf("SetDisabled(false) on an already-enabled machine failed: %v", err)
	}
	if _, err := os.Stat(DisabledMarkerPath(base)); !os.IsNotExist(err) {
		t.Errorf("the marker path still resolves to something: %v", err)
	}
}
