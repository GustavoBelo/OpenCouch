package console

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/GustavoBelo/OpenCouch/engine/internal/notify"
)

// CancelAction is the key of the button that calls an entry off.
const CancelAction = "cancel"

// DefaultGrace is how long a deliberate entry waits -- long enough to read the
// notification and reach its button, short enough that asking for the console
// still feels like asking.
//
// TriggerGrace is how long an entry nobody asked for waits. It is generous on
// purpose: switching a controller on is as often an accident as an intention,
// and the cost of missing the warning is a desktop closed out from under the
// user.
//
// They live here, rather than in whoever counts down, because the daemon, the
// command line and a panel all have to agree about how long the user has.
const (
	DefaultGrace = 10 * time.Second
	TriggerGrace = 20 * time.Second
)

// cancelPoll is how often a countdown looks for the cancel file. The file is
// the way in for a process that is not this one -- `open-couch-engine cancel`,
// mostly -- and a second is soon enough for something the user typed.
const cancelPoll = time.Second

// CountdownOpts is what a countdown needs to announce itself and be argued
// with.
type CountdownOpts struct {
	// Grace is how long the user has to change their mind.
	Grace time.Duration
	// Trigger is what asked, in a form that can start a sentence: "A controller
	// connected". Empty when nothing is worth saying.
	Trigger string
	// Display is the connector the console is about to take over, named the
	// way the user chose it. It is the one thing about an entry that cannot be
	// undone by looking: the desktop closes, and if it comes back on the wrong
	// screen there is nothing left on the right one to say so. Empty leaves the
	// sentence without it rather than guessing.
	Display string
	// RuntimeDir is where the cancel file lives. Empty skips that channel.
	RuntimeDir string
	// Notifier is where the announcement goes. Nil counts down silently, which
	// is what a machine with no notification server gets.
	Notifier notify.Notifier
	Logf     func(string, ...any)
	// Reason names who called it off when the context is what ended the
	// countdown. The daemon knows whether that was the controller being
	// switched off again or a request over IPC; this countdown does not.
	Reason func() string
}

// Countdown announces that console mode is about to start, and waits.
//
// A nil error means the grace period ran out and the caller should go ahead.
// Any error means somebody said no, and names them.
//
// The announcement is the only warning the user gets on most of the ways in --
// the launcher entry has no terminal to print to -- so it carries the way out
// with it: a Cancel button, and the whole notification clickable for the
// servers that draw no buttons.
func Countdown(ctx context.Context, opts CountdownOpts) error {
	logf := opts.Logf
	if logf == nil {
		logf = func(string, ...any) {}
	}

	// Only a stand-down asked for after the announcement means anything. One
	// left lying around from before -- `console cancel` typed while nothing was
	// pending -- would call this off within a second of announcing it, and the
	// user would watch the countdown disappear without being told why.
	if opts.RuntimeDir != "" {
		DropCancel(opts.RuntimeDir)
	}

	var handle notify.Handle
	if opts.Notifier != nil {
		shown, err := opts.Notifier.Show(ctx, armedNotification(opts.Trigger, opts.Display, opts.Grace, opts.Notifier.Actions()))
		if err != nil {
			logf("console: could not announce the entry: %v", err)
		} else {
			handle = shown
		}
	}

	// A nil channel blocks forever, which is the right behaviour for a
	// notification that cannot be answered.
	var answers <-chan string
	if handle != nil {
		answers = handle.Invoked()
	}

	// calledOff leaves the news on screen rather than taking the notification
	// away: "the desktop stays" is the part the user wants to see.
	calledOff := func(why string) error {
		logf("console: entry %s", why)
		if handle != nil {
			// A fresh context: the usual reason to be here is that ctx itself
			// was cancelled, and a cancelled context sends no D-Bus call.
			replaceCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
			defer cancel()
			if err := handle.Replace(replaceCtx, calledOffNotification(why)); err != nil {
				logf("console: could not update the notification: %v", err)
			}
		}
		return errors.New(why)
	}

	deadline := time.After(opts.Grace)
	poll := time.NewTicker(cancelPoll)
	defer poll.Stop()

	for {
		select {
		case <-ctx.Done():
			return calledOff(reason(opts.Reason))
		case key, ok := <-answers:
			if !ok {
				// The server took the notification away without an answer.
				// Being dismissed is not a decision, so the countdown carries
				// on; it just cannot be answered here any more.
				answers = nil
				continue
			}
			if key == CancelAction || key == notify.DefaultAction {
				return calledOff("cancelled from the notification")
			}
		case <-poll.C:
			if opts.RuntimeDir != "" && TakeCancel(opts.RuntimeDir) {
				return calledOff("cancelled")
			}
		case <-deadline:
			// Nothing to argue with any more, and a notification still offering
			// to cancel would be a lie.
			//
			// Replaced rather than only closed, because closing it is not
			// enough on every server. Omarchy's shell gives a critical popup no
			// lifetime at all, ignores the sender's CloseNotification, and
			// restores whatever is still on screen when the desktop comes back
			// -- so a countdown that was merely closed sat there for ever and
			// returned with every login, still offering to cancel an entry that
			// had already happened. The replacement is ordinary urgency with a
			// short life, so it goes on its own wherever close is ignored.
			if handle != nil {
				replaceCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
				if err := handle.Replace(replaceCtx, enteringNotification(opts.Display)); err != nil {
					logf("console: could not update the notification: %v", err)
				}
				cancel()
			}
			return nil
		}
	}
}

func reason(f func() string) string {
	if f == nil {
		return "cancelled"
	}
	if why := f(); why != "" {
		return why
	}
	return "cancelled"
}

func armedNotification(trigger, display string, grace time.Duration, actions bool) notify.Notification {
	body := ""
	if trigger != "" {
		body = trigger + ". "
	}
	body += fmt.Sprintf("Entering console mode%s in %s. The desktop and everything open on it will close. ",
		onDisplay(display), inSeconds(grace))
	if actions {
		body += "Click here to cancel."
	} else {
		body += "Run `open-couch-engine cancel` to stop it."
	}

	note := notify.Notification{
		Summary: "Console mode",
		Body:    body,
		Icon:    "input-gaming",
		Timeout: grace,
		// The countdown is the only warning, so the server must not decide on
		// its own that it has been up long enough.
		Critical: true,
	}
	if actions {
		// Both keys, and the same label for each. The capability says a server
		// takes an answer back; it does not say the server draws a button, and
		// there is no capability that does. mako draws none, dunst hides them
		// in a context menu, and quickshell -- Omarchy's own -- draws none
		// either while reporting `actions`. So the body has to invite the
		// click, and `default` has to mean what the button means.
		note.Actions = []notify.Action{
			{Key: CancelAction, Label: "Cancel"},
			{Key: notify.DefaultAction, Label: "Cancel"},
		}
	}
	return note
}

// enteringNotification is what the countdown leaves behind once it has run
// out: the entry is happening, and there is nothing left to click.
func enteringNotification(display string) notify.Notification {
	return notify.Notification{
		Summary: "Console mode",
		Body:    "Entering console mode" + onDisplay(display) + ". The desktop is closing.",
		Icon:    "input-gaming",
		Timeout: 5 * time.Second,
	}
}

func calledOffNotification(why string) notify.Notification {
	return notify.Notification{
		Summary: "Console mode",
		Body:    "Entering console mode was " + why + ". The desktop stays.",
		Icon:    "input-gaming",
		Timeout: 5 * time.Second,
	}
}

// onDisplay names where the console is going, for the middle of a sentence.
// A machine with no display chosen never reaches a countdown -- the entry paths
// refuse first -- so this is empty only when something failed to read it, and
// then saying nothing beats naming the wrong screen.
func onDisplay(display string) string {
	if display = strings.TrimSpace(display); display == "" {
		return ""
	}
	return " on " + display
}

func inSeconds(d time.Duration) string {
	seconds := int(d.Round(time.Second) / time.Second)
	if seconds == 1 {
		return "1 second"
	}
	return fmt.Sprintf("%d seconds", seconds)
}
