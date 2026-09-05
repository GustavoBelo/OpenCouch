package console

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A wrapper wired for tests: nothing is started, every launch is recorded, and
// a launch can leave a switch request behind the way a real one would.
func testWrapper(t *testing.T, launched *[]string, onLaunch func(argv []string)) *Wrapper {
	t.Helper()
	return &Wrapper{
		DesktopExec:        []string{"desktop-compositor"},
		ConsoleExec:        []string{"start-gamescope-session"},
		ConsoleSessionName: "gamescope-session",
		StateDir:           t.TempDir(),
		RuntimeDir:         t.TempDir(),
		Systemctl:          &fakeRunner{},
		ShortRun:           time.Nanosecond, // no run is "short" in a test
		ShortRunLimit:      2,
		Launch: func(_ context.Context, argv []string, _ []string) error {
			*launched = append(*launched, argv[0])
			if onLaunch != nil {
				onLaunch(argv)
			}
			return nil
		},
	}
}

// The desktop is what starts when nobody asked for anything else, and a
// compositor exiting with no request pending is an ordinary logout.
func TestWrapperStartsTheDesktopAndEndsOnLogout(t *testing.T) {
	var launched []string
	w := testWrapper(t, &launched, nil)
	if err := w.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(launched) != 1 || launched[0] != "desktop-compositor" {
		t.Fatalf("launched %v, want one desktop session", launched)
	}
}

// The whole point: desktop, console, desktop, all inside one login session.
func TestWrapperSwitchesBothWaysWithinOneSession(t *testing.T) {
	var launched []string
	var w *Wrapper
	steps := []Mode{ModeConsole, ModeDesktop}
	w = testWrapper(t, &launched, func([]string) {
		if len(steps) == 0 {
			return
		}
		if err := Request(w.RuntimeDir, steps[0]); err != nil {
			t.Error(err)
		}
		steps = steps[1:]
	})
	if err := w.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	want := []string{"desktop-compositor", "start-gamescope-session", "desktop-compositor"}
	if strings.Join(launched, ",") != strings.Join(want, ",") {
		t.Fatalf("launched %v, want %v", launched, want)
	}
}

// The request the wrapper starts with is honoured, so `console enter` followed
// by the compositor exiting lands in the console rather than back on the
// desktop.
func TestWrapperHonoursAPendingRequestOnStartup(t *testing.T) {
	var launched []string
	w := testWrapper(t, &launched, nil)
	if err := Request(w.RuntimeDir, ModeConsole); err != nil {
		t.Fatal(err)
	}
	if err := w.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(launched) == 0 || launched[0] != "start-gamescope-session" {
		t.Fatalf("launched %v, want the console first", launched)
	}
}

// Without this the loop spins forever on a compositor that cannot start, and the
// user never gets a screen at all.
func TestWrapperGivesUpAfterRepeatedInstantExits(t *testing.T) {
	var launched []string
	var w *Wrapper
	w = testWrapper(t, &launched, func([]string) {
		// Always ask for another one, so only the guard can end this.
		if err := Request(w.RuntimeDir, ModeDesktop); err != nil {
			t.Error(err)
		}
	})
	w.ShortRun = time.Hour // every run counts as instant
	w.ShortRunLimit = 3

	done := make(chan error, 1)
	go func() { done <- w.Run(context.Background()) }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the wrapper never gave up; it would spin forever on a broken compositor")
	}
	if len(launched) != 3 {
		t.Fatalf("launched %d sessions, want the limit of 3: %v", len(launched), launched)
	}
}

// A run that lasted resets the count, so an afternoon of playing followed by one
// bad start does not end the session.
func TestWrapperForgivesAnInstantExitAfterARealSession(t *testing.T) {
	var launched []string
	var w *Wrapper
	long := true
	w = testWrapper(t, &launched, func([]string) {
		if long {
			time.Sleep(20 * time.Millisecond)
			long = false
		}
		if len(launched) < 3 {
			if err := Request(w.RuntimeDir, ModeDesktop); err != nil {
				t.Error(err)
			}
		}
	})
	w.ShortRun = 10 * time.Millisecond
	w.ShortRunLimit = 2

	if err := w.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(launched) != 3 {
		t.Fatalf("launched %v, want the long run to have reset the count", launched)
	}
}

// Falling back beats ending the session: a machine with no gamescope session
// installed should land on the desktop, not on a black screen.
func TestWrapperFallsBackToTheDesktopWhenTheConsoleCannotStart(t *testing.T) {
	var launched []string
	w := testWrapper(t, &launched, nil)
	w.ConsoleExec = nil
	if err := Request(w.RuntimeDir, ModeConsole); err != nil {
		t.Fatal(err)
	}
	if err := w.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(launched) != 1 || launched[0] != "desktop-compositor" {
		t.Fatalf("launched %v, want a fallback to the desktop", launched)
	}
}

// There has to be a way back, so refusing up front beats hosting a session that
// can never return to a desktop.
func TestWrapperRefusesWithoutADesktopCommand(t *testing.T) {
	w := &Wrapper{RuntimeDir: t.TempDir(), StateDir: t.TempDir(), Systemctl: &fakeRunner{}}
	if err := w.Run(context.Background()); err == nil {
		t.Fatal("a wrapper with no way back must refuse to start")
	}
}

// The console needs to identify itself as gamescope, or the portals and the
// session's own units look at XDG_CURRENT_DESKTOP and load the wrong things.
func TestConsoleRunsWithTheGamescopeIdentity(t *testing.T) {
	var env []string
	w := &Wrapper{
		DesktopExec: []string{"desktop"}, ConsoleExec: []string{"console"},
		ConsoleSessionName: "gamescope-session",
		StateDir:           t.TempDir(), RuntimeDir: t.TempDir(), Systemctl: &fakeRunner{},
		ShortRun: time.Nanosecond,
		Launch: func(_ context.Context, _ []string, extra []string) error {
			env = append(env, extra...)
			return nil
		},
	}
	if err := Request(w.RuntimeDir, ModeConsole); err != nil {
		t.Fatal(err)
	}
	if err := w.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(env, " ")
	for _, want := range []string{"XDG_CURRENT_DESKTOP=gamescope", "DESKTOP_SESSION=gamescope-session"} {
		if !strings.Contains(joined, want) {
			t.Errorf("console environment %v is missing %q", env, want)
		}
	}
}

// Big Picture's own "Switch to Desktop" stops the gamescope target and leaves
// no request behind. Treating that as a logout would drop the user at a
// greeter -- nobody logs out *from* a console, so leaving one means going home.
func TestConsoleExitWithNoRequestReturnsToTheDesktop(t *testing.T) {
	var launched []string
	w := testWrapper(t, &launched, nil)
	if err := Request(w.RuntimeDir, ModeConsole); err != nil {
		t.Fatal(err)
	}
	if err := w.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	want := []string{"start-gamescope-session", "desktop-compositor"}
	if strings.Join(launched, ",") != strings.Join(want, ",") {
		t.Fatalf("launched %v, want the console to hand back to the desktop", launched)
	}
}

// The regression. The wrapper is started once by the login manager and hosts
// every session until logout, so a display chosen from the desktop it is hosting
// has to be the display it hands over -- reading the file at login meant the TUI
// said DP-1, the file said DP-1, and the television lit up.
func TestConsoleUsesTheDisplayChosenSinceLogin(t *testing.T) {
	launched := []string{}
	w := testWrapper(t, &launched, nil)
	w.Choices = Config{TVName: "HDMI-A-1", TVDescription: "a television"}
	w.Reload = func() (Config, error) {
		return Config{TVName: "DP-1", TVDescription: "a desk monitor"}, nil
	}
	if err := Request(w.RuntimeDir, ModeConsole); err != nil {
		t.Fatal(err)
	}
	if err := w.Run(context.Background()); err != nil {
		t.Fatal(err)
	}

	sc := w.Systemctl.(*fakeRunner)
	if !sc.called("set-environment OUTPUT_CONNECTOR=DP-1") {
		t.Errorf("systemctl calls %v, want gamescope pointed at the display chosen since login", sc.calls)
	}
	if sc.called("OUTPUT_CONNECTOR=HDMI-A-1") {
		t.Error("gamescope was pointed at the display chosen at login")
	}
}

// A configuration that cannot be re-read is stale at worst. Refusing over it
// would turn an unreadable file into no console at all.
func TestConsoleFallsBackToLoginChoicesWhenTheReReadFails(t *testing.T) {
	launched := []string{}
	w := testWrapper(t, &launched, nil)
	w.Choices = Config{TVName: "HDMI-A-1"}
	w.Reload = func() (Config, error) { return Config{}, errors.New("unreadable") }
	if err := Request(w.RuntimeDir, ModeConsole); err != nil {
		t.Fatal(err)
	}
	if err := w.Run(context.Background()); err != nil {
		t.Fatal(err)
	}

	if sc := w.Systemctl.(*fakeRunner); !sc.called("set-environment OUTPUT_CONNECTOR=HDMI-A-1") {
		t.Errorf("systemctl calls %v, want the login choice to have stood", sc.calls)
	}
	if len(launched) == 0 || launched[0] != "start-gamescope-session" {
		t.Errorf("launched %v, want the console to have started anyway", launched)
	}
}

// The way back has to exist. A desktop session chosen since login but no longer
// installed must not strand the user, so the entry validated at startup stands.
func TestDesktopFallsBackToTheEntryValidatedAtLogin(t *testing.T) {
	launched := []string{}
	w := testWrapper(t, &launched, nil)
	w.DesktopSession = "hyprland.desktop"
	w.Reload = func() (Config, error) {
		return Config{DesktopSession: "a-session-that-was-uninstalled.desktop"}, nil
	}
	if err := w.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(launched) != 1 || launched[0] != "desktop-compositor" {
		t.Fatalf("launched %v, want the desktop validated at login", launched)
	}
}

// pretendCompositorRunning plants the socket a live Hyprland instance holds,
// which is what SessionRunning looks for.
func pretendCompositorRunning(t *testing.T, runtimeDir string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(runtimeDir, "wayland-1"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WAYLAND_DISPLAY", "wayland-1")
	t.Setenv("XDG_RUNTIME_DIR", runtimeDir)
}

// The login manager starts this before any compositor exists. Typed inside a
// desktop, the first thing the loop does is Sanitize -- `systemctl --user stop
// graphical-session.target` -- which takes that desktop's services down with it,
// without asking. The command's help said it would not work; this makes it true.
func TestRunRefusesInsideALiveSession(t *testing.T) {
	launched := []string{}
	w := testWrapper(t, &launched, nil)
	pretendCompositorRunning(t, w.RuntimeDir)

	err := w.Run(context.Background())
	if err == nil {
		t.Fatal("running inside a live session was allowed")
	}
	if !strings.Contains(err.Error(), "already running") {
		t.Errorf("err = %v, want it to name the running compositor", err)
	}
	if !strings.Contains(err.Error(), "open-couch-engine enter") {
		t.Errorf("err = %v, want it to point at the command that does work", err)
	}
	// The refusal has to come before anything is torn down or started.
	if len(launched) != 0 {
		t.Errorf("launched %v despite refusing", launched)
	}
	if sc, ok := w.Systemctl.(*fakeRunner); ok && sc.called("stop graphical-session.target") {
		t.Error("the live session's services were stopped anyway")
	}
}

// The ordinary path -- started by the login manager, nothing running yet -- must
// still work, or the refusal has cost more than it saved.
func TestRunProceedsWhenNoCompositorIsRunning(t *testing.T) {
	launched := []string{}
	w := testWrapper(t, &launched, nil)

	if err := w.Run(context.Background()); err != nil {
		t.Fatalf("Run = %v, want a normal start", err)
	}
	if len(launched) == 0 {
		t.Error("nothing was launched")
	}
}

// The desktop comes back empty and nothing on screen says why: the compositor
// was already stopped, so the notification server went with it. The wrapper
// leaves the reason for the daemon that starts with the desktop it is about to
// bring up.
func TestRunLeavesWordWhenTheConsoleCannotStart(t *testing.T) {
	launched := []string{}
	w := testWrapper(t, &launched, nil)
	w.Boot = BootConsole
	// What a machine with no gamescope-session package looks like.
	w.ConsoleExec = nil

	if err := w.Run(context.Background()); err != nil {
		t.Fatalf("Run = %v, want the fallback to the desktop", err)
	}

	reason, ok := TakeFailure(w.StateDir)
	if !ok {
		t.Fatal("the wrapper fell back to the desktop and left no reason")
	}
	if !strings.Contains(reason, "gamescope") {
		t.Errorf("reason = %q, want it to name what was missing", reason)
	}
	// The point of falling back at all: the user gets a desktop, not a black
	// screen.
	if len(launched) == 0 || !strings.Contains(strings.Join(launched, " "), "desktop-compositor") {
		t.Errorf("launched %v, want the desktop to have come back", launched)
	}
}

// A session that worked must leave nothing behind, or the daemon announces a
// failure that did not happen.
func TestRunLeavesNoWordWhenNothingFailed(t *testing.T) {
	launched := []string{}
	w := testWrapper(t, &launched, nil)

	if err := w.Run(context.Background()); err != nil {
		t.Fatal(err)
	}

	if reason, ok := TakeFailure(w.StateDir); ok {
		t.Errorf("a working session recorded %q", reason)
	}
}

// The desktop used to get its identity from the DesktopNames line of the
// per-user hosting entry. A hosting entry installed once for every account
// cannot carry it, so the wrapper exports it -- and without it the desktop comes
// up with an empty XDG_CURRENT_DESKTOP, which portals and polkit agents key off
// for the whole life of the session.
func TestDesktopSessionGetsItsIdentityFromTheWrapper(t *testing.T) {
	env := desktopEnv("omarchy.desktop", []string{"Hyprland"}, "")
	want := map[string]bool{
		"XDG_CURRENT_DESKTOP=Hyprland": false,
		"XDG_SESSION_DESKTOP=Hyprland": false,
		"DESKTOP_SESSION=omarchy":      false,
	}
	for _, entry := range env {
		if _, ok := want[entry]; ok {
			want[entry] = true
		} else {
			t.Errorf("unexpected environment entry %q", entry)
		}
	}
	for entry, seen := range want {
		if !seen {
			t.Errorf("%q was not exported", entry)
		}
	}

	// More than one name is how a session claims two identities at once.
	if got := desktopEnv("x.desktop", []string{"wlroots", "Hyprland"}, ""); got[0] != "XDG_CURRENT_DESKTOP=wlroots:Hyprland" {
		t.Errorf("got %q, want the names joined with a colon", got[0])
	}

	// An entry that declares nothing falls back to what setup recorded from the
	// running session, which is how Omarchy -- whose entry names nothing -- gets
	// an identity at all.
	if got := desktopEnv("omarchy.desktop", nil, "Hyprland"); got[0] != "XDG_CURRENT_DESKTOP=Hyprland" {
		t.Errorf("got %q, want the recorded identity", got)
	}

	// With neither, nothing is invented: naming the wrong desktop is worse than
	// naming none.
	for _, entry := range desktopEnv("x.desktop", nil, "") {
		if strings.HasPrefix(entry, "XDG_CURRENT_DESKTOP=") {
			t.Errorf("invented a desktop identity: %q", entry)
		}
	}
}
