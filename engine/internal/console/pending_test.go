package console

import (
	"testing"
	"time"
)

func TestPendingEntryRoundTrips(t *testing.T) {
	dir := t.TempDir()
	if err := WritePending(dir, PendingEntry{
		Deadline: time.Now().Add(20 * time.Second).Format(time.RFC3339),
		Trigger:  TriggerController,
		Display:  "TCL 25G64",
	}); err != nil {
		t.Fatal(err)
	}
	entry, ok := ReadPending(dir)
	if !ok || entry.Trigger != TriggerController || entry.Display != "TCL 25G64" {
		t.Fatalf("read %+v, %v", entry, ok)
	}

	ClearPending(dir)
	if _, ok := ReadPending(dir); ok {
		t.Error("the announcement survived being cleared")
	}
}

// A countdown that was interrupted by the switch it asked for leaves its file
// behind: the compositor stops and takes the process with it. The next session
// must not read that as a countdown already under way.
func TestPendingEntryExpires(t *testing.T) {
	dir := t.TempDir()
	if err := WritePending(dir, PendingEntry{
		Deadline: time.Now().Add(-time.Second).Format(time.RFC3339),
		Trigger:  TriggerController,
	}); err != nil {
		t.Fatal(err)
	}
	if _, ok := ReadPending(dir); ok {
		t.Error("a deadline that has passed was reported as pending")
	}
}

func TestPendingEntryIsAbsentWhenNothingWroteOne(t *testing.T) {
	if _, ok := ReadPending(t.TempDir()); ok {
		t.Error("found an announcement in an empty runtime directory")
	}
}
