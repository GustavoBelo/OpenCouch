package console

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// steamPidFile is where the Steam client records its process id. A variable so
// tests can point it at a fixture.
var steamPidFile = filepath.Join(homeDir(), ".steam", "steam.pid")

// steamQuitWait bounds the wait for Steam to go away after it has been asked to.
// A clean quit is a second or two; the cap is for a Steam that has wedged, where
// waiting longer buys nothing the session teardown will not also do. A variable
// so a test does not have to sit through it.
var steamQuitWait = 8 * time.Second

// steamClientPID reports the pid of a running Steam client, if there is one.
//
// The pid file outlives a crash, so a live pid is not enough on its own: the
// number is checked against /proc to be sure it is Steam and not whatever was
// handed it next. A variable so tests can stand in for a running Steam without
// one.
var steamClientPID = func() (int, bool) {
	// A home directory that would not resolve leaves steamPidFile relative, and
	// reading it would then be against the working directory -- some other pid
	// file, or none. Not knowing where Steam's is means treating it as gone.
	if !filepath.IsAbs(steamPidFile) {
		return 0, false
	}
	data, err := os.ReadFile(steamPidFile)
	if err != nil {
		return 0, false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || pid <= 0 {
		return 0, false
	}
	if !pidRunning(pid) {
		return 0, false
	}
	comm, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "comm"))
	if err != nil || strings.TrimSpace(string(comm)) != "steam" {
		return 0, false
	}
	return pid, true
}

// steamShutdown asks Steam to exit. A variable so a test can see it was called
// without a Steam to call.
var steamShutdown = func(ctx context.Context) error {
	return exec.CommandContext(ctx, "steam", "-shutdown").Run()
}

// pidRunning reports whether a process with this pid exists. A variable so tests
// can drive the wait loop without a real process.
var pidRunning = func(pid int) bool {
	return exists(filepath.Join("/proc", strconv.Itoa(pid)))
}

// QuitSteam asks a running desktop Steam to exit cleanly before the session is
// torn down.
//
// It exists because of what a SIGTERM'd Steam does on the way out: the handler
// races the collapsing display server, hangs for a couple of seconds and then
// crashes in Xlib teardown -- and graphical-session.target waits for it the
// whole time. The crash also makes the next Steam, the one in the gamescope
// session, decide it "did not shut down cleanly" and run an immediate client
// update. `steam -shutdown` is the quit the tray menu's "Exit" uses, and done
// here, while X and Wayland are still healthy, it is quick and clean.
//
// Best-effort. Steam not running is the common case and returns at once; a quit
// that does not land before the deadline just logs and lets the ordinary stop
// take over. It never starts Steam -- `steam -shutdown` on a machine with none
// running would -- so the pid file is checked first.
func QuitSteam(ctx context.Context, logf func(string, ...any)) {
	pid, ok := steamClientPID()
	if !ok {
		return
	}
	if _, err := lookPath("steam"); err != nil {
		logf("console: steam is running but not on PATH; leaving it to the session stop")
		return
	}

	started := time.Now()
	if err := steamShutdown(ctx); err != nil {
		logf("console: `steam -shutdown` returned %v; waiting for it to exit anyway", err)
	}

	deadline := time.Now().Add(steamQuitWait)
	for pidRunning(pid) {
		if time.Now().After(deadline) {
			logf("console: steam still running %s after -shutdown; stopping the session anyway",
				time.Since(started).Round(time.Millisecond))
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(150 * time.Millisecond):
		}
	}
	logf("console: steam quit %s after -shutdown", time.Since(started).Round(time.Millisecond))
}

// homeDir is os.UserHomeDir without the error path: an empty string just makes
// steamPidFile unreadable, which QuitSteam already treats as "no Steam".
func homeDir() string {
	home, _ := os.UserHomeDir()
	return home
}
