package console

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// stubSteam swaps the seams QuitSteam runs through and restores them after.
func stubSteam(t *testing.T) {
	t.Helper()
	pid, shut, run, wait, look := steamClientPID, steamShutdown, pidRunning, steamQuitWait, lookPath
	t.Cleanup(func() {
		steamClientPID, steamShutdown, pidRunning, steamQuitWait, lookPath = pid, shut, run, wait, look
	})
	// A test that gets as far as the PATH check should find Steam unless it says
	// otherwise.
	lookPath = func(string) (string, error) { return "/usr/bin/steam", nil }
}

func recordLogs(lines *[]string) func(string, ...any) {
	return func(format string, args ...any) { *lines = append(*lines, fmt.Sprintf(format, args...)) }
}

func joined(lines []string) string { return strings.Join(lines, "\n") }

// Steam not running is the common case: nothing is asked to quit and nothing is
// logged, because there is nothing to say.
func TestQuitSteamDoesNothingWhenSteamIsNotRunning(t *testing.T) {
	stubSteam(t)
	steamClientPID = func() (int, bool) { return 0, false }
	asked := false
	steamShutdown = func(context.Context) error { asked = true; return nil }

	var logs []string
	QuitSteam(context.Background(), recordLogs(&logs))

	if asked {
		t.Error("asked a Steam that is not running to shut down")
	}
	if len(logs) != 0 {
		t.Errorf("logged for a no-op: %q", logs)
	}
}

// A running Steam is asked to quit once, and the wait ends as soon as it is
// gone.
func TestQuitSteamAsksSteamToExitAndWaitsForIt(t *testing.T) {
	stubSteam(t)
	steamClientPID = func() (int, bool) { return 4242, true }
	gone := false
	calls := 0
	steamShutdown = func(context.Context) error { calls++; gone = true; return nil }
	pidRunning = func(pid int) bool {
		if pid != 4242 {
			t.Errorf("waited on pid %d, want the one from the pid file", pid)
		}
		return !gone
	}

	var logs []string
	QuitSteam(context.Background(), recordLogs(&logs))

	if calls != 1 {
		t.Errorf("`steam -shutdown` was run %d times, want once", calls)
	}
	if !strings.Contains(joined(logs), "steam quit") {
		t.Errorf("logs %q, want it to record that Steam quit", logs)
	}
}

// A shutdown that returns an error is still followed by the wait: the exit is
// what matters, not the exit code of the request.
func TestQuitSteamWaitsEvenWhenShutdownErrors(t *testing.T) {
	stubSteam(t)
	steamClientPID = func() (int, bool) { return 9, true }
	gone := false
	steamShutdown = func(context.Context) error { gone = true; return fmt.Errorf("pipe closed") }
	pidRunning = func(int) bool { return !gone }

	var logs []string
	QuitSteam(context.Background(), recordLogs(&logs))

	if !strings.Contains(joined(logs), "steam quit") {
		t.Errorf("logs %q, want the wait to have completed", logs)
	}
}

// A Steam that never exits must not hold the switch forever.
func TestQuitSteamGivesUpAfterTheDeadline(t *testing.T) {
	stubSteam(t)
	steamClientPID = func() (int, bool) { return 7, true }
	steamShutdown = func(context.Context) error { return nil }
	pidRunning = func(int) bool { return true }
	steamQuitWait = 20 * time.Millisecond

	var logs []string
	done := make(chan struct{})
	go func() { QuitSteam(context.Background(), recordLogs(&logs)); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("QuitSteam did not give up after its deadline")
	}

	if !strings.Contains(joined(logs), "still running") {
		t.Errorf("logs %q, want it to record that Steam was left running", logs)
	}
}

// Steam running but not on PATH: say so and leave it to the session stop rather
// than blocking on a command that is not there.
func TestQuitSteamStepsAsideWhenSteamIsNotOnPath(t *testing.T) {
	stubSteam(t)
	steamClientPID = func() (int, bool) { return 3, true }
	lookPath = func(string) (string, error) { return "", fmt.Errorf("not found") }
	asked := false
	steamShutdown = func(context.Context) error { asked = true; return nil }

	var logs []string
	QuitSteam(context.Background(), recordLogs(&logs))

	if asked {
		t.Error("ran `steam -shutdown` with steam missing from PATH")
	}
	if !strings.Contains(joined(logs), "not on PATH") {
		t.Errorf("logs %q, want it to name why Steam was left alone", logs)
	}
}

// The pid file outlives a crash, so steamClientPID has to look past it: a dead
// pid, junk, or a live pid that is not Steam all mean "not running".
func TestSteamClientPIDLooksPastAStalePidFile(t *testing.T) {
	stubSteam(t)
	orig := steamPidFile
	t.Cleanup(func() { steamPidFile = orig })
	dir := t.TempDir()
	steamPidFile = filepath.Join(dir, "steam.pid")

	if _, ok := steamClientPID(); ok {
		t.Error("a missing pid file reported a running Steam")
	}

	if err := os.WriteFile(steamPidFile, []byte("not-a-number\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, ok := steamClientPID(); ok {
		t.Error("junk in the pid file reported a running Steam")
	}

	// This process is alive but its comm is the test binary, not "steam".
	if err := os.WriteFile(steamPidFile, []byte(strconv.Itoa(os.Getpid())), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, ok := steamClientPID(); ok {
		t.Error("a live non-Steam pid reported a running Steam")
	}
}
