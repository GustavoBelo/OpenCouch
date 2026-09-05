package console

import (
	"context"
	"os/exec"
	"strings"
	"time"
)

// Runner executes a systemctl --user command. It exists so the cleanup can be
// tested by what it asks for rather than by what a live session does.
type Runner interface {
	Run(ctx context.Context, args ...string) error
	Output(ctx context.Context, args ...string) (string, error)
}

// Systemctl talks to the caller's systemd user manager.
type Systemctl struct{}

func (Systemctl) Run(ctx context.Context, args ...string) error {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, "systemctl", append([]string{"--user"}, args...)...).Run()
}

func (Systemctl) Output(ctx context.Context, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "systemctl", append([]string{"--user"}, args...)...).Output()
	return strings.TrimSpace(string(out)), err
}

// staleEnvironment is what a gamescope session leaves in the user manager's
// environment. Left behind, XDG_CURRENT_DESKTOP still says "gamescope" and
// XDG_DESKTOP_PORTAL_DIR is empty, so the desktop that starts next gets the
// wrong portals and the wrong identity.
var staleEnvironment = []string{
	"XDG_CURRENT_DESKTOP",
	"DESKTOP_SESSION",
	"XDG_SESSION_DESKTOP",
	"XDG_DESKTOP_PORTAL_DIR",
	"DISPLAY",
	"GAMESCOPE_WAYLAND_DISPLAY",
	"WAYLAND_DISPLAY",
	// Ours: which output gamescope was told to drive. A stale value would send
	// the next console session to a display the user did not choose.
	"OUTPUT_CONNECTOR",
}

// Sanitize clears what a session leaves behind in the systemd user manager.
//
// This is the step nothing else performs, and its absence is what makes a
// desktop refuse to come back: start-gamescope-session does the same cleanup on
// the way *in*, precisely because it knows the state is left dirty, but there is
// no equivalent on the way out. A gamescope session that ends abruptly leaves
// graphical-session-pre.target active, and uwsm then declines with "A compositor
// or graphical-session* target is already active!" -- the next session dies in
// the same second it starts, and the user is left with a black screen.
//
// Failures are not reported. Every step here is "make sure this is not the
// case", and a stop for something that was never running is a success as far as
// the caller is concerned.
func Sanitize(ctx context.Context, sc Runner) {
	_ = sc.Run(ctx, "stop", "gamescope-session.target")
	_ = sc.Run(ctx, "stop", "graphical-session.target")
	_ = sc.Run(ctx, "stop", "graphical-session-pre.target")
	_ = sc.Run(ctx, "reset-failed")
	_ = sc.Run(ctx, append([]string{"unset-environment"}, staleEnvironment...)...)
}

// SettleJobs waits for the user manager to finish whatever it is doing.
//
// Stopping a session is not instant, and uwsm refuses to start a compositor on
// top of units that are still tearing down -- it fails with
// "wayland-session-bindpid@<pid>.service returned non-zero exit status 1", and
// systemd logs an ordering cycle while the old envelope target unwinds. Waiting
// for the job queue to drain is the difference between a session that starts and
// one that dies in five seconds.
func SettleJobs(ctx context.Context, sc Runner, within time.Duration) {
	deadline := time.Now().Add(within)
	for {
		out, err := sc.Output(ctx, "list-jobs", "--no-legend")
		if err != nil || strings.TrimSpace(out) == "" {
			return
		}
		if time.Now().After(deadline) {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(250 * time.Millisecond):
		}
	}
}

// Dirty reports whether the user manager still carries session state, which is
// what makes the next compositor refuse to start. Used by the doctor, so a
// machine left in that state can be told what is wrong instead of just failing.
// Note it does not look at graphical-session-pre.target: that target is active
// throughout any healthy session, so reporting it would call every working
// machine broken. It only blocks a compositor that is *starting*, which is where
// Sanitize deals with it.
func Dirty(ctx context.Context, sc Runner) (bool, string) {
	out, err := sc.Output(ctx, "list-units", "--state=failed", "--no-legend")
	if err == nil && strings.Contains(out, "gamescope") {
		return true, "a previous gamescope session left failed units behind"
	}
	return false, ""
}

// TargetKnown reports whether the systemd user manager can resolve the
// gamescope session's target, which is what the session entry's command starts.
func TargetKnown(ctx context.Context, sc Runner) bool {
	_, err := sc.Output(ctx, "cat", "gamescope-session.target")
	return err == nil
}

// systemDisplayManager names the unit that starts the graphical login, or
// nothing when the machine has no display manager at all.
//
// This is the one query that goes to the system manager rather than the user's,
// so it does not go through Runner.
func systemDisplayManager(ctx context.Context) string {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "systemctl", "show", "-p", "Id", "--value", "display-manager").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}
