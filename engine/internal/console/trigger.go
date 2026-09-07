package console

import (
	"context"
	"strings"
	"time"

	"github.com/GustavoBelo/OpenCouch/engine/internal/notify"
)

// controllerPoll is how often the wrapper looks for a pad that has just been
// switched on. Sysfs is read once per tick and costs nothing; two seconds is
// well inside the time it takes to pick up a controller and look at the
// television.
const controllerPoll = 2 * time.Second

// watchControllers asks for the console when a gamepad is switched on, if the
// user has said it should.
//
// It runs only while the desktop is the session on screen, and only for as long
// as that session lasts: entering from the console is meaningless, and a watch
// that outlived the compositor would arm itself against the next one.
func (w *Wrapper) watchControllers(ctx context.Context) {
	count := w.Controllers
	if count == nil {
		count = ConnectedControllers
	}
	poll := w.ControllerPoll
	if poll <= 0 {
		poll = controllerPoll
	}

	// Whatever is already attached when the desktop starts is not an event.
	// Arming on the count instead of on the rise would enter the console every
	// time the desktop came back with a pad still plugged in -- including the
	// trip home from the console, which is the one moment the user has just
	// said they want the desktop.
	attached := count()

	ticker := time.NewTicker(poll)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			now := count()
			rose := now > attached
			attached = now
			if !rose {
				continue
			}
			cfg := w.choices()
			// Read on every rise rather than once: a login lasts days, and the
			// switch is in a window the user opens during one.
			if !cfg.EnterOnControllerConnect || !cfg.Configured() {
				continue
			}
			w.enterOnTrigger(ctx, cfg)
			// Deliberately not returning. A countdown that was called off means
			// "not this time", not "never again this session", and the next pad
			// switched on should ask again.
		}
	}
}

// enterOnTrigger announces the entry, gives the user their twenty seconds, and
// switches if nobody objects.
func (w *Wrapper) enterOnTrigger(ctx context.Context, cfg Config) {
	display := cfg.TVDescription
	if display == "" {
		display = cfg.TVName
	}

	// Written before the countdown starts so the app can join one already under
	// way, and cleared however this ends -- including the path where the
	// compositor stops and takes the app down with it, since the file lives in
	// the runtime directory and a stale one would be read as a live countdown
	// by the next session. ReadPending's deadline check covers the rest.
	grace := w.ControllerGrace
	if grace <= 0 {
		grace = TriggerGrace
	}
	if err := WritePending(w.RuntimeDir, PendingEntry{
		Deadline: time.Now().Add(grace).Format(time.RFC3339),
		Trigger:  TriggerController,
		Display:  display,
	}); err != nil {
		w.logf("console: could not tell the application about the entry: %v", err)
	}
	defer ClearPending(w.RuntimeDir)

	// Dialled here rather than kept for the life of the wrapper: at login there
	// is no notification server yet, and a connection made then would be to
	// nothing for the rest of the day.
	notifier := w.dial()
	if notifier != nil {
		defer notifier.Close()
	}

	w.logf("console: a controller connected; announcing an entry in %s", grace)
	if err := Countdown(ctx, CountdownOpts{
		Grace:      grace,
		Trigger:    "A controller connected",
		Display:    display,
		RuntimeDir: w.RuntimeDir,
		Notifier:   notifier,
		Logf:       w.logf,
	}); err != nil {
		return
	}

	if err := Request(w.RuntimeDir, ModeConsole); err != nil {
		w.logf("console: could not record the request: %v", err)
		return
	}
	if err := w.stopDesktop(ctx); err != nil {
		// Cleared here, unlike in `enter`. There the error usually means the
		// stop worked and killed the reporter; here the reporter is the wrapper
		// itself, so it is still running and the stop really did fail. A
		// request left behind would be taken by the next compositor exit --
		// an ordinary logout would land in the console.
		w.logf("console: could not stop the desktop for the controller entry: %v", err)
		ClearRequest(w.RuntimeDir)
	}
}

func (w *Wrapper) stopDesktop(ctx context.Context) error {
	if w.StopDesktop != nil {
		return w.StopDesktop(ctx)
	}
	return CompositorFor(w.desktopNames()...).Stop(ctx)
}

func (w *Wrapper) dial() notify.Notifier {
	if w.Notifier != nil {
		return w.Notifier()
	}
	return notify.Dial()
}

// desktopNames is everything known about what the hosted desktop calls itself:
// what its entry declares, and what setup captured from the session that was
// running. Either may be empty on its own.
func (w *Wrapper) desktopNames() []string {
	names := append([]string{}, w.DesktopNames...)
	for _, name := range strings.Split(w.Choices.DesktopNames, ":") {
		if name = strings.TrimSpace(name); name != "" {
			names = append(names, name)
		}
	}
	return names
}
