package console

import (
	"os"
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

// Turning the console back on, or a login that lasts, has to lift the hold and
// wipe the streak behind it.
func TestRecordHostHealthyLiftsTheHold(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	for i := failLoginLimit; i > 0; i-- {
		RecordHostStart(dir, now.Add(-time.Duration(i)*time.Minute))
	}
	WriteSafeMode(dir, "3 logins in a row ended within seconds", now)

	RecordHostHealthy(dir, now)

	if _, _, held := ReadSafeMode(dir); held {
		t.Error("the safe-mode breadcrumb outlived a login that worked")
	}
	if _, tripped := SafeModeReason(dir, now); tripped {
		t.Error("the streak survived a login that worked")
	}
}

// A desktop that safe mode forced clears the streak once it has lasted -- so
// the next login can try the console -- but leaves the breadcrumb, so `status`
// keeps saying safe mode until a login that had the console still lasts.
func TestClearHostStreakKeepsTheBreadcrumb(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	for i := failLoginLimit; i > 0; i-- {
		RecordHostStart(dir, now.Add(-time.Duration(i)*time.Minute))
	}
	WriteSafeMode(dir, "3 logins in a row ended within seconds", now)

	ClearHostStreak(dir)

	if _, tripped := SafeModeReason(dir, now); tripped {
		t.Error("the streak was not cleared, so the next login stays held")
	}
	if _, _, held := ReadSafeMode(dir); !held {
		t.Error("ClearHostStreak wiped the breadcrumb; only a login that lasts should")
	}
	if h := loadHostHealth(dir); !h.LastGood.IsZero() {
		t.Error("ClearHostStreak recorded a login that worked; it did not")
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

// `status` shows this for as long as it is true, so it must survive a read --
// unlike the console-failure breadcrumb, which is seen once.
func TestSafeModeBreadcrumbSurvivesReads(t *testing.T) {
	dir := t.TempDir()
	WriteSafeMode(dir, "3 logins in a row ended within seconds", time.Now())

	for i := 0; i < 3; i++ {
		if _, _, ok := ReadSafeMode(dir); !ok {
			t.Fatalf("read %d found nothing; the hold has to stand until a login lasts", i)
		}
	}
	ClearSafeMode(dir)
	if _, _, ok := ReadSafeMode(dir); ok {
		t.Error("the breadcrumb outlived ClearSafeMode")
	}
}

// A wrapper may have no state directory; none of this may panic on one.
func TestHealthIsQuietWithNoStateDir(t *testing.T) {
	RecordHostStart("", time.Now())
	RecordHostHealthy("", time.Now())
	WriteSafeMode("", "something", time.Now())
	if _, tripped := SafeModeReason("", time.Now()); tripped {
		t.Error("an empty state dir tripped safe mode")
	}
	if _, _, ok := ReadSafeMode(""); ok {
		t.Error("an empty state dir reported a hold")
	}
	ClearSafeMode("")
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
