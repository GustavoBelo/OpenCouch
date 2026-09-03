package console

import (
	"os"
	"testing"
	"time"
)

// The wrapper cannot say this itself: by the time it knows, it has stopped the
// compositor and taken the notification server with it. What it writes has to
// reach whoever comes back.
func TestFailureRoundTrips(t *testing.T) {
	dir := t.TempDir()
	RecordFailure(dir, "no gamescope session is installed")

	reason, ok := TakeFailure(dir)
	if !ok {
		t.Fatal("nothing was left for the daemon to report")
	}
	if reason != "no gamescope session is installed" {
		t.Errorf("reason = %q, want what the wrapper recorded", reason)
	}
}

// One notification, not one per poll. The daemon reads this every three
// seconds, and a popup that keeps coming back is worse than the silence it
// replaced.
func TestTakeFailureIsSeenOnce(t *testing.T) {
	dir := t.TempDir()
	RecordFailure(dir, "something went wrong")

	if _, ok := TakeFailure(dir); !ok {
		t.Fatal("the first read found nothing")
	}
	if reason, ok := TakeFailure(dir); ok {
		t.Errorf("the news came back a second time: %q", reason)
	}
	if _, err := os.Stat(failurePath(dir)); !os.IsNotExist(err) {
		t.Errorf("the file is still there: %v", err)
	}
}

// The wrapper writes this immediately before starting the desktop, and the
// daemon starts with that desktop, so it is read within seconds. One that has
// been sitting there belongs to a session already left behind -- a machine
// switched off before the daemon ever ran -- and a popup about it days later is
// noise about something the user has long since worked around.
func TestTakeFailureIgnoresOldNews(t *testing.T) {
	dir := t.TempDir()
	RecordFailure(dir, "something went wrong")
	old := time.Now().Add(-failureMaxAge - time.Minute)
	if err := os.Chtimes(failurePath(dir), old, old); err != nil {
		t.Fatal(err)
	}

	if reason, ok := TakeFailure(dir); ok {
		t.Errorf("stale news was reported: %q", reason)
	}
	// Cleared anyway, so it does not wait for a later poll to surprise anyone.
	if _, err := os.Stat(failurePath(dir)); !os.IsNotExist(err) {
		t.Errorf("the stale file was left behind: %v", err)
	}
}

// Nothing recorded is the normal case, on every poll of every session that
// worked. It must be silent and cheap.
func TestTakeFailureOnNothing(t *testing.T) {
	if reason, ok := TakeFailure(t.TempDir()); ok {
		t.Errorf("TakeFailure invented %q", reason)
	}
	if _, ok := TakeFailure(""); ok {
		t.Error("an empty state dir produced news")
	}
}

// An empty reason is not news. Recording one would produce a notification that
// says a session failed and does not say why, which is the situation this
// exists to end.
func TestRecordFailureIgnoresAnEmptyReason(t *testing.T) {
	dir := t.TempDir()
	for _, reason := range []string{"", "   ", "\n"} {
		RecordFailure(dir, reason)
		if _, ok := TakeFailure(dir); ok {
			t.Errorf("an empty reason %q was recorded", reason)
		}
	}
	// A missing state dir is not an error either: the wrapper may not have one.
	RecordFailure("", "something")
}
