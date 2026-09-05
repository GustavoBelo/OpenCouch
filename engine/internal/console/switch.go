package console

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Mode is which compositor the hosting session should run next.
type Mode string

const (
	ModeDesktop Mode = "desktop"
	ModeConsole Mode = "console"
)

// requestFile is how a switch is asked for. A file rather than a socket because
// the process asking is about to be killed by the switch it is asking for: it
// has to leave the request somewhere that outlives it, and the wrapper reads it
// only after the compositor has gone.
const requestFile = "open-couch-next-session"

func RequestPath(runtimeDir string) string {
	return filepath.Join(runtimeDir, requestFile)
}

// Request records which compositor should run after the current one exits.
//
// No request means a real log out: the wrapper's loop ends and the session
// closes, which is what makes an ordinary logout still work.
func Request(runtimeDir string, mode Mode) error {
	return os.WriteFile(RequestPath(runtimeDir), []byte(string(mode)+"\n"), 0o600)
}

// requestMaxAge is how long a switch request stays meaningful.
//
// It exists so that nobody has to clear a request to keep it from doing harm
// later. The process that writes one is running inside the compositor it is
// about to stop, and stopping the compositor kills it -- so it cannot be relied
// on to come back and tidy up, and code that tried raced the wrapper for the
// file. Losing that race is how `enter` dropped the user at the login screen:
// the request was cleared, and the wrapper read a compositor exit with nothing
// pending as an ordinary logout.
//
// The window only has to cover a compositor's exit, which is seconds. Anything
// older was written for a switch that never happened, and acting on it would
// jump to the console at some unrelated logout hours later.
const requestMaxAge = 2 * time.Minute

// TakeRequest reads and clears a pending request.
//
// Clearing is the point: a request that survived being acted on would switch
// again on the next exit, and the user would be unable to log out. A request
// older than requestMaxAge is cleared and ignored, which is what lets writers
// leave one behind without having to clean up after themselves.
func TakeRequest(runtimeDir string) (Mode, bool) {
	path := RequestPath(runtimeDir)
	info, statErr := os.Stat(path)
	data, err := os.ReadFile(path)
	_ = os.Remove(path)
	if err != nil {
		return "", false
	}
	if statErr == nil && time.Since(info.ModTime()) > requestMaxAge {
		return "", false
	}
	switch mode := Mode(strings.TrimSpace(string(data))); mode {
	case ModeDesktop, ModeConsole:
		return mode, true
	default:
		return "", false
	}
}

// ClearRequest drops a pending request without acting on it.
func ClearRequest(runtimeDir string) { _ = os.Remove(RequestPath(runtimeDir)) }

// StopCompositor ends the running compositor so the wrapper can start the other
// one.
//
// Verified by effect, never by exit status. Hyprland's Lua configuration parser
// accepts `hyprctl dispatch exit`, exits 0 and does nothing, so a caller that
// trusted the return code would report success and leave the user wondering why
// nothing happened. The wrapper's own record of which session it is running is
// what settles it -- and it is written by the wrapper rather than read from the
// compositor, so the same check works for every desktop.
func StopCompositor(ctx context.Context, runtimeDir string, c Compositor) error {
	if c == nil {
		c = DetectCompositor()
	}
	before, ok := ReadLive(runtimeDir)
	if !ok {
		// Nothing is hosting this session, so there is no loop waiting to start
		// the console and ending the compositor would just log the user out.
		// Refusing here is the last line: the entry paths check Hosted() first,
		// and this catches a session that stopped being hosted since.
		return errors.New("this session is not hosted, so ending the compositor would log you out instead of switching; " +
			"run `open-couch-engine setup` and log in again")
	}
	if err := c.Stop(ctx); err != nil {
		return err
	}
	if !AwaitSessionEnd(ctx, runtimeDir, before, stopTimeout) {
		return fmt.Errorf("%s accepted the request to end its session: %w", c.Name(), ErrSwitchPending)
	}
	return nil
}

// ErrSwitchPending says the compositor accepted the request to stop but the
// wrapper had not started the next session before the wait ran out.
//
// It is not a failure, and the difference matters more than it looks: a caller
// that treats it as one and clears the request turns a slow switch into a
// logout. The compositor is going away either way, and when it does the wrapper
// reads the request and acts on it -- but only if the request is still there.
// That is exactly how `enter` dropped the user at the login screen: the stop
// worked, the confirmation was late, the request was cleared, and the wrapper
// found nothing to switch to.
var ErrSwitchPending = errors.New("the switch is under way but has not finished yet")

// stopTimeout is how long to wait for the next session to appear.
//
// It has to cover the whole gap, not just the compositor's exit: before the
// wrapper records a new generation it runs Sanitize and then SettleJobs, which
// alone is allowed twenty seconds. A timeout shorter than that reports a switch
// as stalled while it is merely proceeding.
const stopTimeout = 45 * time.Second

// StopConsoleSession ends a running gamescope session.
//
// Stopping the target is what Steam's own "Switch to Desktop" does, so this is
// the same door rather than a second one.
func StopConsoleSession(ctx context.Context, sc Runner) error {
	if sc == nil {
		sc = Systemctl{}
	}
	if out, err := sc.Output(ctx, "is-active", "gamescope-session.target"); err != nil || out != "active" {
		return errors.New("no console session is running")
	}
	return sc.Run(ctx, "stop", "gamescope-session.target")
}

// RuntimeDir is where the request file lives. It has to be the same directory
// for the process asking and for the wrapper reading, which is the one thing
// they share.
func RuntimeDir() (string, error) {
	dir := os.Getenv("XDG_RUNTIME_DIR")
	if dir == "" {
		return "", errors.New("XDG_RUNTIME_DIR is not set, so there is nowhere to leave the request")
	}
	return dir, nil
}

// cancelFile stops a pending automatic entry. Same shape as the request file
// and for the same reason: the daemon that armed the entry and the command that
// calls it off are different processes, and the runtime directory is what they
// share.
const cancelFile = "open-couch-cancel-entry"

func CancelPath(runtimeDir string) string { return filepath.Join(runtimeDir, cancelFile) }

// cancelMaxAge is how long a stand-down stays meaningful.
//
// A countdown polls for the file every second, so one that a live countdown was
// going to consume is never more than a moment old. Anything older was written
// when nothing was counting down -- `open-couch-engine cancel` typed at a shell
// with no entry pending -- and honouring it later would call off the next
// legitimate entry, silently, without anyone having asked.
const cancelMaxAge = 30 * time.Second

// RequestCancel asks a pending automatic entry to stand down.
func RequestCancel(runtimeDir string) error {
	return os.WriteFile(CancelPath(runtimeDir), []byte("1\n"), 0o600)
}

// TakeCancel reports whether a stand-down was asked for, and clears it.
//
// A stale file is cleared and ignored rather than left alone, so the trap
// disarms itself instead of waiting for the next entry to walk into it.
func TakeCancel(runtimeDir string) bool {
	path := CancelPath(runtimeDir)
	info, err := os.Stat(path)
	if err != nil {
		return false
	}
	_ = os.Remove(path)
	return time.Since(info.ModTime()) <= cancelMaxAge
}

// DropCancel clears a stand-down without acting on it.
//
// A countdown calls this before it announces anything. Without it, a cancel
// written seconds earlier -- while nothing was pending -- would call off an
// entry that had not even been announced yet, and the user would see a countdown
// vanish for no stated reason.
func DropCancel(runtimeDir string) { _ = os.Remove(CancelPath(runtimeDir)) }
