package console

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Compositor is the desktop session the wrapper hosts.
//
// Only one thing about a compositor differs enough to need an interface: how to
// make it exit. Everything else the wrapper does -- sanitising the user manager,
// waiting for the connector, moving audio -- is the same whichever desktop is
// underneath, which is why this is one method and not a driver.
type Compositor interface {
	// Name is what the logs and the doctor call this compositor.
	Name() string
	// Stop asks the compositor to end its session. It reports whether the
	// request was accepted, never whether the session actually ended: an
	// accepted request that does nothing is a real outcome for at least one
	// compositor, so the caller verifies by effect instead.
	Stop(ctx context.Context) error
}

// DetectCompositor picks the compositor from the environment of the session it
// is called in.
//
// XDG_CURRENT_DESKTOP is the field the desktops themselves agree to set, and it
// is colon-separated because a session may claim more than one identity
// (Omarchy sets "Hyprland", Plasma sets "KDE"). DESKTOP_SESSION is the fallback
// for sessions that set only that.
func DetectCompositor() Compositor {
	names := strings.Split(os.Getenv("XDG_CURRENT_DESKTOP"), ":")
	names = append(names, os.Getenv("DESKTOP_SESSION"))
	for _, name := range names {
		switch strings.ToLower(strings.TrimSpace(name)) {
		case "kde", "plasma", "plasmawayland":
			return KDE{}
		case "hyprland", "omarchy":
			return Hyprland{}
		case "gnome", "gnome-wayland", "gnome-xorg":
			return GNOME{}
		}
	}
	return Unknown{}
}

// KDE ends a Plasma session through the shutdown service Plasma's own log-out
// menu calls, so the session unwinds the way it does for a normal logout rather
// than being killed.
type KDE struct{}

func (KDE) Name() string { return "KDE Plasma" }

func (KDE) Stop(ctx context.Context) error {
	// qdbus6 is the KF6 name and qdbus the KF5 one. Distributions disagree
	// about which they ship and some ship both, so try in order rather than
	// requiring either.
	return runFirstAvailable(ctx, [][]string{
		{"qdbus6", "org.kde.Shutdown", "/Shutdown", "org.kde.Shutdown.logout"},
		{"qdbus", "org.kde.Shutdown", "/Shutdown", "org.kde.Shutdown.logout"},
	})
}

// Hyprland stops through uwsm when the session was started by it, because
// stopping the compositor alone would leave uwsm's units behind.
type Hyprland struct{}

func (Hyprland) Name() string { return "Hyprland" }

func (Hyprland) Stop(ctx context.Context) error {
	// `hyprctl dispatch` is accepted and silently ignored by Hyprland's Lua
	// configuration parser -- it exits 0 and does nothing -- so this call being
	// accepted proves nothing. The caller verifies by effect.
	return runFirstAvailable(ctx, [][]string{
		{"uwsm", "stop"},
		{"hyprctl", "dispatch", "exit"},
	})
}

// GNOME ends the session through gnome-session's own quit command.
type GNOME struct{}

func (GNOME) Name() string { return "GNOME" }

func (GNOME) Stop(ctx context.Context) error {
	return runFirstAvailable(ctx, [][]string{
		{"gnome-session-quit", "--logout", "--no-prompt"},
	})
}

// Unknown is the compositor this does not recognise.
//
// It refuses rather than guessing. The generic way to end a session is
// `loginctl terminate-session`, which would work -- and would also kill the
// wrapper hosting it, dropping the user at the login manager instead of in the
// console they asked for. That is a worse outcome than being told the desktop is
// not supported yet, because the user cannot tell it from a crash.
type Unknown struct{}

func (Unknown) Name() string { return "an unrecognised desktop" }

func (Unknown) Stop(context.Context) error {
	return fmt.Errorf("this desktop is not supported yet (XDG_CURRENT_DESKTOP=%q): "+
		"there is no known way to end its session without also ending the session hosting it",
		os.Getenv("XDG_CURRENT_DESKTOP"))
}

// lookPath is shadowed by check.go's variable of the same name, which tests set.
func runFirstAvailable(ctx context.Context, attempts [][]string) error {
	var last error
	tried := false
	for _, attempt := range attempts {
		if _, err := lookPath(attempt[0]); err != nil {
			continue
		}
		tried = true
		cmd := exec.CommandContext(ctx, attempt[0], attempt[1:]...)
		if err := cmd.Run(); err != nil {
			last = fmt.Errorf("%s: %w", strings.Join(attempt, " "), err)
			continue
		}
		return nil
	}
	if !tried {
		names := make([]string, 0, len(attempts))
		for _, attempt := range attempts {
			names = append(names, attempt[0])
		}
		return fmt.Errorf("no way to stop the compositor: none of %s is installed",
			strings.Join(names, ", "))
	}
	return last
}

// SessionRunning reports whether this process is already inside a graphical
// session.
//
// The tell is the display socket rather than a process name or a compositor's
// own IPC, because the wrapper hosts whichever compositor the user configured
// and cannot know what to look for. A login manager starts the wrapper before
// any compositor exists, so nothing is set then; a user who types the command
// inside their own desktop has both the variable and the socket.
func SessionRunning(runtimeDir string) bool {
	if display := os.Getenv("WAYLAND_DISPLAY"); display != "" {
		if filepath.IsAbs(display) {
			return exists(display)
		}
		if runtimeDir == "" {
			return true
		}
		return exists(filepath.Join(runtimeDir, display))
	}
	if socket := x11Socket(os.Getenv("DISPLAY")); socket != "" {
		return exists(socket)
	}
	return false
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// x11SocketDir is a variable so tests can point it somewhere writable.
var x11SocketDir = "/tmp/.X11-unix"

// x11Socket names the socket a DISPLAY value refers to, or "" for one that
// names another machine.
//
// The socket rather than the variable, because DISPLAY is inherited by anything
// started from a shell that once had a session and survives that session ending.
// A stale value would have the wrapper refuse to start for a desktop that is no
// longer there, which is the one situation it is needed most.
func x11Socket(display string) string {
	host, number, found := strings.Cut(display, ":")
	if !found || host != "" {
		// A remote display is somebody else's session, not one this would be
		// running inside.
		return ""
	}
	number, _, _ = strings.Cut(number, ".")
	if number == "" {
		return ""
	}
	return filepath.Join(x11SocketDir, "X"+number)
}

var errNoCompositor = errors.New("no compositor is running")
