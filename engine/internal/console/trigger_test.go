package console

import (
	"context"
	"testing"
	"time"
)

// A wrapper wired for the controller trigger: no pad, no notification server,
// no compositor, and a grace short enough to sit through.
func triggerWrapper(t *testing.T, pads func() int, stopped chan<- struct{}) *Wrapper {
	t.Helper()
	return &Wrapper{
		StateDir:        t.TempDir(),
		RuntimeDir:      t.TempDir(),
		Choices:         Config{TVName: "HDMI-A-1", EnterOnControllerConnect: true},
		Controllers:     pads,
		ControllerPoll:  time.Millisecond,
		ControllerGrace: 20 * time.Millisecond,
		StopDesktop: func(context.Context) error {
			select {
			case stopped <- struct{}{}:
			default:
			}
			return nil
		},
		QuitSteam: func(context.Context) {},
	}
}

// counter turns a script of readings into the sysfs count, holding the last one
// once the script runs out.
func counter(readings ...int) func() int {
	i := -1
	return func() int {
		if i < len(readings)-1 {
			i++
		}
		return readings[i]
	}
}

func TestControllerConnectingAsksForTheConsole(t *testing.T) {
	stopped := make(chan struct{}, 1)
	w := triggerWrapper(t, counter(0, 0, 1), stopped)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	go w.watchControllers(ctx)

	select {
	case <-stopped:
	case <-ctx.Done():
		t.Fatal("the desktop was never stopped")
	}
	mode, ok := TakeRequest(w.RuntimeDir)
	if !ok || mode != ModeConsole {
		t.Errorf("request = %v, %v; want the console", mode, ok)
	}
}

// The pad plugged in at the desk all day is not an event. Arming on the count
// rather than on the rise would enter the console every time the desktop came
// back -- including the trip home from the console itself.
func TestPadsAlreadyAttachedDoNotTrigger(t *testing.T) {
	stopped := make(chan struct{}, 1)
	w := triggerWrapper(t, counter(2), stopped)

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	w.watchControllers(ctx)

	select {
	case <-stopped:
		t.Fatal("a pad that was already there started a countdown")
	default:
	}
}

func TestTriggerIsIgnoredWhenTheSettingIsOff(t *testing.T) {
	stopped := make(chan struct{}, 1)
	w := triggerWrapper(t, counter(0, 1), stopped)
	w.Choices.EnterOnControllerConnect = false

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	w.watchControllers(ctx)

	select {
	case <-stopped:
		t.Fatal("the console was entered with the setting off")
	default:
	}
}

// No television chosen means the console cannot start, and a countdown for a
// switch that would fail is a desktop closed for nothing.
func TestTriggerIsIgnoredWhenNoDisplayIsChosen(t *testing.T) {
	stopped := make(chan struct{}, 1)
	w := triggerWrapper(t, counter(0, 1), stopped)
	w.Choices.TVName = ""

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	w.watchControllers(ctx)

	select {
	case <-stopped:
		t.Fatal("the console was entered with nothing to enter it on")
	default:
	}
}

// The application shows the same countdown the notification does, and cancels
// it through the file the engine already polls.
func TestTriggerAnnouncesItselfToTheApplication(t *testing.T) {
	stopped := make(chan struct{}, 1)
	w := triggerWrapper(t, counter(0, 1), stopped)
	w.ControllerGrace = 2 * time.Second

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go w.watchControllers(ctx)

	deadline := time.Now().Add(time.Second)
	var entry PendingEntry
	for time.Now().Before(deadline) {
		if e, ok := ReadPending(w.RuntimeDir); ok {
			entry = e
			break
		}
		time.Sleep(2 * time.Millisecond)
	}
	if entry.Trigger != TriggerController {
		t.Fatalf("announced %+v, want the controller trigger", entry)
	}
	if entry.Display != "HDMI-A-1" {
		t.Errorf("display = %q, want the connector when there is no description", entry.Display)
	}

	// Cancelling is the app's Cancel button, and the countdown polls for it.
	// Not before the countdown has started: it drops a stale cancel on the way
	// in, which is what stops one typed while nothing was pending from calling
	// off the next real entry -- and would swallow this one.
	time.Sleep(150 * time.Millisecond)
	if err := RequestCancel(w.RuntimeDir); err != nil {
		t.Fatal(err)
	}
	time.Sleep(1500 * time.Millisecond)
	select {
	case <-stopped:
		t.Fatal("the desktop was stopped after the entry was called off")
	default:
	}
	if _, ok := ReadPending(w.RuntimeDir); ok {
		t.Error("the announcement outlived the countdown that wrote it")
	}
}

// The wrapper has no XDG_CURRENT_DESKTOP of its own -- it builds that variable
// for the compositor it launches -- so it has to name the desktop from what it
// is hosting.
func TestCompositorForNamesTheHostedDesktop(t *testing.T) {
	w := &Wrapper{DesktopNames: []string{"Hyprland"}}
	if name := CompositorFor(w.desktopNames()...).Name(); name != "Hyprland" {
		t.Errorf("compositor = %s, want Hyprland from the entry", name)
	}

	// Omarchy's entry declares none, so setup captures it from the session.
	w = &Wrapper{Choices: Config{DesktopNames: "KDE:plasma"}}
	if name := CompositorFor(w.desktopNames()...).Name(); name != "KDE Plasma" {
		t.Errorf("compositor = %s, want the identity setup recorded", name)
	}

	w = &Wrapper{Choices: Config{DesktopNames: ""}}
	if name := CompositorFor(w.desktopNames()...).Name(); name != "an unrecognised desktop" {
		t.Errorf("compositor = %s, want a refusal", name)
	}
}

// Nothing to offer while the console is held back. The watch is armed for every
// hosted desktop, so the hold is what has to say no -- read when the pad rises,
// not decided when the desktop started.
func TestTriggerIsIgnoredWhileTheConsoleIsHeld(t *testing.T) {
	stopped := make(chan struct{}, 1)
	w := triggerWrapper(t, counter(0, 1), stopped)
	now := time.Now()
	for i := failLoginLimit; i > 0; i-- {
		RecordHostStart(w.StateDir, now.Add(-time.Duration(i)*time.Minute))
	}

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	w.watchControllers(ctx)

	select {
	case <-stopped:
		t.Fatal("a pad switched on entered the console while it was held back")
	default:
	}
}

// And the moment the hold lifts, the pad works -- in that login, without a
// relogin. Arming the watch only for a desktop that was not held meant `enable`
// from the panel left the trigger dead for the rest of the login, while the
// panel, `status` and the `enter` gate all reported the console as ready.
func TestTriggerArmsItselfWhenTheHoldLifts(t *testing.T) {
	stopped := make(chan struct{}, 1)
	base := t.TempDir()
	if err := SetDisabled(base, true); err != nil {
		t.Fatal(err)
	}

	// The pad goes on only after the hold has been lifted, the way it happens
	// on a desk: the user clicks "offer the console again", then picks the
	// controller up.
	calls := 0
	pads := func() int {
		calls++
		switch {
		case calls < 3:
			return 0
		case calls == 3:
			if err := SetDisabled(base, false); err != nil {
				t.Error(err)
			}
			return 0
		default:
			return 1
		}
	}
	w := triggerWrapper(t, pads, stopped)
	w.BaseDir = base

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	go w.watchControllers(ctx)

	select {
	case <-stopped:
	case <-ctx.Done():
		t.Fatal("the pad did nothing after the hold was lifted")
	}
	if mode, ok := TakeRequest(w.RuntimeDir); !ok || mode != ModeConsole {
		t.Errorf("request = %v, %v; want the console", mode, ok)
	}
}
