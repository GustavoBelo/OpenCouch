package console

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The desktop names come from the desktops themselves, and XDG_CURRENT_DESKTOP
// is colon-separated because a session may claim more than one identity.
func TestDetectCompositorReadsTheSessionsOwnClaim(t *testing.T) {
	for _, tc := range []struct {
		current, session string
		want             string
	}{
		{current: "KDE", want: "KDE Plasma"},
		{current: "plasma", want: "KDE Plasma"},
		{current: "Hyprland", want: "Hyprland"},
		{current: "GNOME", want: "GNOME"},
		{current: "wlroots:Hyprland", want: "Hyprland"},
		{current: "", session: "hyprland", want: "Hyprland"},
		{current: "", session: "plasma", want: "KDE Plasma"},
		{current: "XFCE", want: "an unrecognised desktop"},
		{current: "", want: "an unrecognised desktop"},
	} {
		t.Setenv("XDG_CURRENT_DESKTOP", tc.current)
		t.Setenv("DESKTOP_SESSION", tc.session)
		if got := DetectCompositor().Name(); got != tc.want {
			t.Errorf("XDG_CURRENT_DESKTOP=%q DESKTOP_SESSION=%q: got %q, want %q",
				tc.current, tc.session, got, tc.want)
		}
	}
}

// An unrecognised desktop refuses rather than reaching for
// `loginctl terminate-session`, which would end the session hosting the wrapper
// too and drop the user at the login manager instead of in the console.
func TestUnknownCompositorRefusesInsteadOfGuessing(t *testing.T) {
	t.Setenv("XDG_CURRENT_DESKTOP", "SomethingElse")
	err := Unknown{}.Stop(context.Background())
	if err == nil {
		t.Fatal("an unrecognised desktop was stopped anyway")
	}
	if !strings.Contains(err.Error(), "SomethingElse") {
		t.Errorf("err = %v, want it to name the desktop it did not recognise", err)
	}
}

// Every attempt being missing is a different failure from every attempt being
// tried and failing, and the message has to say which.
func TestRunFirstAvailableSaysWhenNothingIsInstalled(t *testing.T) {
	old := lookPath
	t.Cleanup(func() { lookPath = old })
	lookPath = func(string) (string, error) { return "", os.ErrNotExist }

	err := runFirstAvailable(context.Background(), [][]string{{"nope", "--stop"}, {"alsonope"}})
	if err == nil {
		t.Fatal("stopping with nothing installed was reported as success")
	}
	if !strings.Contains(err.Error(), "nope") || !strings.Contains(err.Error(), "alsonope") {
		t.Errorf("err = %v, want it to name what it looked for", err)
	}
}

// The socket rather than the variable: a login manager starts the wrapper with
// neither set, while a shell inside a desktop has both -- and a shell that
// outlived its desktop has the variable alone.
func TestSessionRunningFollowsTheDisplaySocket(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("WAYLAND_DISPLAY", "")
	t.Setenv("DISPLAY", "")
	if SessionRunning(dir) {
		t.Fatal("a session with no display was called running")
	}

	t.Setenv("WAYLAND_DISPLAY", "wayland-1")
	if SessionRunning(dir) {
		t.Fatal("a stale WAYLAND_DISPLAY with no socket was called running")
	}
	if err := os.WriteFile(filepath.Join(dir, "wayland-1"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if !SessionRunning(dir) {
		t.Fatal("a live wayland socket was not noticed")
	}

	// An absolute WAYLAND_DISPLAY names the socket outright.
	absolute := filepath.Join(dir, "elsewhere.sock")
	t.Setenv("WAYLAND_DISPLAY", absolute)
	if SessionRunning(dir) {
		t.Fatal("an absolute path to nothing was called running")
	}
	if err := os.WriteFile(absolute, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if !SessionRunning(dir) {
		t.Fatal("an absolute wayland socket was not noticed")
	}
}

func TestSessionRunningFollowsTheX11Socket(t *testing.T) {
	dir := t.TempDir()
	sockets := t.TempDir()
	old := x11SocketDir
	t.Cleanup(func() { x11SocketDir = old })
	x11SocketDir = sockets

	t.Setenv("WAYLAND_DISPLAY", "")
	t.Setenv("DISPLAY", ":0")
	if SessionRunning(dir) {
		t.Fatal("a stale DISPLAY with no socket was called running")
	}
	if err := os.WriteFile(filepath.Join(sockets, "X0"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if !SessionRunning(dir) {
		t.Fatal("a live X11 socket was not noticed")
	}

	// A display on another machine is somebody else's session.
	t.Setenv("DISPLAY", "other.host:0")
	if SessionRunning(dir) {
		t.Fatal("a remote display was read as a session running here")
	}
	t.Setenv("DISPLAY", ":0.1")
	if !SessionRunning(dir) {
		t.Fatal("a screen suffix was not stripped from the display number")
	}
}
