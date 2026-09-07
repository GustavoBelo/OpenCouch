package console

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func writeLog(t *testing.T, stateDir, text string, when time.Time) {
	t.Helper()
	if err := os.WriteFile(LogPath(stateDir), []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(LogPath(stateDir), when, when); err != nil {
		t.Fatal(err)
	}
}

// The log the user wants is the one from the login that went wrong, and that
// login is over by the time they open the panel.
func TestRotateKeepsThePreviousLogin(t *testing.T) {
	dir := t.TempDir()
	when := time.Date(2026, 9, 5, 23, 32, 27, 0, time.Local)
	writeLog(t, dir, "the console session ended\n", when)

	if err := RotateLog(dir); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(LogPath(dir)); !os.IsNotExist(err) {
		t.Errorf("the current log survived rotation: %v", err)
	}

	sessions, err := LogSessions(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(sessions) != 1 || sessions[0].ID != "20260905-233227" {
		t.Fatalf("kept %+v, want the login dated by its last line", sessions)
	}
	text, err := ReadLogSession(dir, sessions[0].ID)
	if err != nil || text != "the console session ended\n" {
		t.Errorf("read back %q, %v", text, err)
	}
}

// A login that wrote nothing is not a login worth keeping, and rotating on a
// machine that has never hosted one must not fail.
func TestRotateIgnoresAnEmptyOrMissingLog(t *testing.T) {
	dir := t.TempDir()
	if err := RotateLog(dir); err != nil {
		t.Fatalf("rotating with no log at all: %v", err)
	}
	writeLog(t, dir, "", time.Now())
	if err := RotateLog(dir); err != nil {
		t.Fatalf("rotating an empty log: %v", err)
	}
	sessions, err := LogSessions(dir)
	if err != nil || len(sessions) != 0 {
		t.Fatalf("kept %+v, %v; want nothing", sessions, err)
	}
}

func TestRotateKeepsOnlyTheNewest(t *testing.T) {
	dir := t.TempDir()
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.Local)
	for i := 0; i < logsKept+4; i++ {
		writeLog(t, dir, "login\n", base.Add(time.Duration(i)*time.Hour))
		if err := RotateLog(dir); err != nil {
			t.Fatal(err)
		}
	}

	sessions, err := LogSessions(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(sessions) != logsKept {
		t.Fatalf("kept %d logins, want %d", len(sessions), logsKept)
	}
	// Newest first, and the four oldest gone.
	if sessions[0].ID != "20260101-130000" {
		t.Errorf("newest is %s, want the last login written", sessions[0].ID)
	}
	if sessions[len(sessions)-1].ID != "20260101-040000" {
		t.Errorf("oldest is %s, want the four before it dropped", sessions[len(sessions)-1].ID)
	}
}

// The id comes back from the application, which got it from `log --list`.
// Joining one to a path without checking it is how a caller reads whatever it
// likes.
func TestReadLogSessionRefusesAnythingButAnID(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "secret"), []byte("no"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"../secret", "..", "/etc/passwd", "20260905-233227x", ""} {
		if _, err := ReadLogSession(dir, id); err == nil {
			t.Errorf("id %q was accepted", id)
		}
	}
}

// Clearing has to leave the file, because the wrapper is holding it open and
// appending: removing it would leave the running login writing to an inode
// nobody can read back.
func TestClearLogEmptiesRatherThanRemoves(t *testing.T) {
	dir := t.TempDir()
	writeLog(t, dir, "something\n", time.Now())
	if err := ClearLog(dir); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(LogPath(dir))
	if err != nil {
		t.Fatalf("the log file went away: %v", err)
	}
	if info.Size() != 0 {
		t.Errorf("size = %d, want empty", info.Size())
	}
	if err := ClearLog(t.TempDir()); err != nil {
		t.Errorf("clearing a log that was never written: %v", err)
	}
}

// The application iterates what this returns. `null` is not a list.
func TestLogSessionsIsAListWhenThereIsNothing(t *testing.T) {
	sessions, err := LogSessions(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if sessions == nil {
		t.Error("nil, want an empty list")
	}
}

func TestReadLogIsEmptyBeforeAnySessionHasRun(t *testing.T) {
	text, err := ReadLog(t.TempDir())
	if err != nil || text != "" {
		t.Errorf("read %q, %v; want empty and no error", text, err)
	}
}
