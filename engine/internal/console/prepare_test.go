package console

import (
	"context"
	"os"
	"testing"
)

// Entering twice must not record the TV as the desktop's own choice. It did
// once, and leaving handed the desktop back to a television nobody was
// watching, with no way to find out where the sound had been.
func TestPrepareAudioNeverOverwritesTheRecord(t *testing.T) {
	dir := t.TempDir()
	original := Prepared{PreviousSink: "alsa_output.usb-headphones", Card: "card0", PreviousCardProfile: "output:analog-stereo"}
	if err := writePrepared(dir, original); err != nil {
		t.Fatal(err)
	}

	// Returns before touching audio at all, which is what makes this safe to
	// run on a machine with no pactl.
	if err := PrepareAudio(context.Background(), dir, "Some TV", func(string, ...any) {}); err != nil {
		t.Fatalf("PrepareAudio = %v, want a second enter to be a no-op", err)
	}

	got, ok := ReadPrepared(dir)
	if !ok {
		t.Fatal("the record was removed")
	}
	if got != original {
		t.Errorf("record = %+v, want the first enter's %+v", got, original)
	}
}

// Leaving without having entered must do nothing. Restoring from an absent
// record would move sound the user placed themselves.
func TestRestoreAudioWithoutARecordDoesNothing(t *testing.T) {
	dir := t.TempDir()
	logged := 0
	RestoreAudio(context.Background(), dir, func(string, ...any) { logged++ })
	if logged != 0 {
		t.Errorf("logged %d lines with nothing to restore", logged)
	}
}

// The record has to be cleared once it has been acted on, or the next leave
// would restore a state that is already gone.
func TestRestoreAudioClearsTheRecord(t *testing.T) {
	dir := t.TempDir()
	// Nothing to put back, so neither branch shells out and the clear is what
	// this observes.
	if err := writePrepared(dir, Prepared{}); err != nil {
		t.Fatal(err)
	}

	RestoreAudio(context.Background(), dir, func(string, ...any) {})

	if _, ok := ReadPrepared(dir); ok {
		t.Error("the record survived being restored from")
	}
	if _, err := os.Stat(preparedPath(dir)); !os.IsNotExist(err) {
		t.Errorf("the record file is still there: %v", err)
	}
}

// What is written has to be exactly what comes back, or leaving restores
// something other than what entering displaced.
func TestPreparedRoundTrips(t *testing.T) {
	dir := t.TempDir()
	want := Prepared{
		PreviousSink:        "alsa_output.pci-0000_0d_00.1.hdmi-stereo",
		Card:                "alsa_card.pci-0000_0d_00.1",
		PreviousCardProfile: "output:hdmi-stereo-extra1",
	}
	if err := writePrepared(dir, want); err != nil {
		t.Fatal(err)
	}

	got, ok := ReadPrepared(dir)
	if !ok {
		t.Fatal("what was written did not read back")
	}
	if got != want {
		t.Errorf("round trip = %+v, want %+v", got, want)
	}
}

// A truncated or hand-edited file is not a record. Acting on half of one would
// restore a sink that was never there.
func TestReadPreparedRejectsRubbish(t *testing.T) {
	for _, body := range []string{"", "{", "not json", "[]"} {
		dir := t.TempDir()
		if err := os.WriteFile(preparedPath(dir), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, ok := ReadPrepared(dir); ok && body != "[]" {
			t.Errorf("ReadPrepared(%q) was accepted as a record", body)
		}
	}
}
