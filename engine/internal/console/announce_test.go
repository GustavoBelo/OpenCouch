package console

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/GustavoBelo/OpenCouch/engine/internal/notify"
)

// fakeNotifier stands in for a notification server. answer is what the user
// clicks the moment the notification appears; dismiss closes the notification
// without an answer, which is what a swipe does.
type fakeNotifier struct {
	actions bool
	answer  string
	dismiss bool

	mu     sync.Mutex
	handle *fakeHandle
}

func (f *fakeNotifier) Actions() bool { return f.actions }
func (f *fakeNotifier) Close()        {}

func (f *fakeNotifier) Show(_ context.Context, note notify.Notification) (notify.Handle, error) {
	h := &fakeHandle{shown: note, answers: make(chan string, 1)}
	if f.answer != "" {
		h.answers <- f.answer
	}
	if f.dismiss {
		close(h.answers)
	}
	f.mu.Lock()
	f.handle = h
	f.mu.Unlock()
	return h, nil
}

func (f *fakeNotifier) shown() *fakeHandle {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.handle
}

type fakeHandle struct {
	answers chan string

	mu       sync.Mutex
	shown    notify.Notification
	replaced []notify.Notification
	closed   bool
}

func (h *fakeHandle) Invoked() <-chan string { return h.answers }

func (h *fakeHandle) Replace(_ context.Context, note notify.Notification) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.replaced = append(h.replaced, note)
	return nil
}

func (h *fakeHandle) Close() {
	h.mu.Lock()
	h.closed = true
	h.mu.Unlock()
}

func (h *fakeHandle) announcement() notify.Notification {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.shown
}

func (h *fakeHandle) lastReplacement(t *testing.T) notify.Notification {
	t.Helper()
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.replaced) == 0 {
		t.Fatal("the notification was never updated to say the entry was called off")
	}
	return h.replaced[len(h.replaced)-1]
}

func TestCountdownRunningOutMeansGoAhead(t *testing.T) {
	n := &fakeNotifier{actions: true}
	err := Countdown(context.Background(), CountdownOpts{Grace: 30 * time.Millisecond, Notifier: n})
	if err != nil {
		t.Fatalf("Countdown = %v, want the grace to run out", err)
	}
}

func TestCountdownStopsWhenTheNotificationIsAnswered(t *testing.T) {
	for _, key := range []string{CancelAction, notify.DefaultAction} {
		t.Run(key, func(t *testing.T) {
			n := &fakeNotifier{actions: true, answer: key}
			err := Countdown(context.Background(), CountdownOpts{Grace: time.Minute, Notifier: n})
			if err == nil {
				t.Fatal("answering the notification did not call the entry off")
			}
			body := n.shown().lastReplacement(t).Body
			if !strings.Contains(body, "The desktop stays") {
				t.Errorf("replacement body = %q, want it to say the desktop stays", body)
			}
		})
	}
}

// Being dismissed is not a decision. The countdown carries on; it just cannot
// be answered there any more.
func TestCountdownSurvivesTheNotificationBeingDismissed(t *testing.T) {
	n := &fakeNotifier{actions: true, dismiss: true}
	if err := Countdown(context.Background(), CountdownOpts{Grace: 30 * time.Millisecond, Notifier: n}); err != nil {
		t.Fatalf("Countdown = %v, want a dismissed notification to change nothing", err)
	}
}

// A cancel written while the countdown is running is the one that counts. It
// arrives after the announcement, which is the only moment at which the user can
// have seen what they are calling off.
func TestCountdownStopsWhenTheCancelFileAppears(t *testing.T) {
	dir := t.TempDir()
	n := &fakeNotifier{actions: true}

	go func() {
		time.Sleep(20 * time.Millisecond)
		if err := RequestCancel(dir); err != nil {
			panic(err)
		}
	}()

	err := Countdown(context.Background(), CountdownOpts{
		Grace:      time.Minute,
		RuntimeDir: dir,
		Notifier:   n,
	})
	if err == nil {
		t.Fatal("the cancel file did not call the entry off")
	}
	// Clearing is the point: a request that survived being acted on would call
	// off the next entry too.
	if TakeCancel(dir) {
		t.Error("the cancel file was left behind")
	}
}

// `open-couch-engine cancel` typed while nothing is pending used to leave a
// file that called off the next entry, silently, seconds or hours later. The
// countdown drains it before announcing, so what the user sees start is what
// they get.
func TestCountdownIgnoresACancelLeftFromBefore(t *testing.T) {
	dir := t.TempDir()
	if err := RequestCancel(dir); err != nil {
		t.Fatalf("RequestCancel: %v", err)
	}

	err := Countdown(context.Background(), CountdownOpts{
		Grace:      30 * time.Millisecond,
		RuntimeDir: dir,
		Notifier:   &fakeNotifier{actions: true},
	})
	if err != nil {
		t.Fatalf("Countdown = %v, want a stale cancel to be ignored", err)
	}
}

func TestCountdownNamesWhoCalledItOff(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	n := &fakeNotifier{actions: true}
	err := Countdown(ctx, CountdownOpts{
		Grace:    time.Minute,
		Notifier: n,
		Reason:   func() string { return "the controller was disconnected" },
	})
	if err == nil {
		t.Fatal("a cancelled context did not call the entry off")
	}
	if !strings.Contains(err.Error(), "the controller was disconnected") {
		t.Errorf("err = %v, want it to name the controller", err)
	}
	// The replacement has to go out on a context of its own: the usual reason
	// to be here is that the caller's context is already dead.
	body := n.shown().lastReplacement(t).Body
	if !strings.Contains(body, "the controller was disconnected") {
		t.Errorf("replacement body = %q, want it to name the controller", body)
	}
}

// A machine with no notification server still counts down; it just does it
// quietly.
func TestCountdownWithNowhereToAnnounce(t *testing.T) {
	if err := Countdown(context.Background(), CountdownOpts{Grace: 20 * time.Millisecond}); err != nil {
		t.Fatalf("Countdown = %v, want a silent countdown to still run out", err)
	}
}

func TestArmedNotificationSaysHowToCancel(t *testing.T) {
	withButtons := armedNotification("", "DP-1", TriggerGrace, true)
	if !strings.Contains(withButtons.Body, "Click here to cancel") {
		t.Errorf("body = %q, want it to invite a click", withButtons.Body)
	}
	keys := []string{}
	for _, a := range withButtons.Actions {
		keys = append(keys, a.Key)
	}
	// Both, because mako and dunst draw no buttons: on those the only answer a
	// person can give is a click on the body, which arrives as `default`.
	if len(keys) != 2 || keys[0] != CancelAction || keys[1] != notify.DefaultAction {
		t.Errorf("action keys = %v, want the button and the body click", keys)
	}
	if !withButtons.Critical {
		t.Error("the only warning the user gets must not expire on the server's schedule")
	}

	withoutButtons := armedNotification("", "DP-1", TriggerGrace, false)
	if !strings.Contains(withoutButtons.Body, "open-couch-engine cancel") {
		t.Errorf("body = %q, want it to name the command instead", withoutButtons.Body)
	}
	if len(withoutButtons.Actions) != 0 {
		t.Errorf("actions = %v, want none where they would be dropped", withoutButtons.Actions)
	}
}

// The trigger used to be hard-coded, so a countdown the user started from the
// TUI told them a controller had connected.
func TestArmedNotificationLeadsWithTheTrigger(t *testing.T) {
	withTrigger := armedNotification("A controller connected", "HDMI-A-1", TriggerGrace, true).Body
	if !strings.HasPrefix(withTrigger, "A controller connected. Entering console mode on HDMI-A-1 in 20 seconds.") {
		t.Errorf("body = %q, want it to lead with the controller", withTrigger)
	}
	asked := armedNotification("", "HDMI-A-1", DefaultGrace, true).Body
	if !strings.HasPrefix(asked, "Entering console mode on HDMI-A-1 in 10 seconds.") {
		t.Errorf("body = %q, want no lead when the user asked outright", asked)
	}
}

func TestInSeconds(t *testing.T) {
	for _, tc := range []struct {
		in   time.Duration
		want string
	}{
		{20 * time.Second, "20 seconds"},
		{time.Second, "1 second"},
		{1500 * time.Millisecond, "2 seconds"},
	} {
		if got := inSeconds(tc.in); got != tc.want {
			t.Errorf("inSeconds(%s) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// The announcement has to name the display. Entering closes the desktop, so if
// it comes back on the wrong screen there is nothing left on the right one to
// say what happened -- and the countdown is the last moment anyone can look.
func TestCountdownNamesTheDisplay(t *testing.T) {
	notifier := &fakeNotifier{actions: true}

	if err := Countdown(context.Background(), CountdownOpts{
		Grace:      10 * time.Millisecond,
		Display:    "DP-1",
		RuntimeDir: t.TempDir(),
		Notifier:   notifier,
	}); err != nil {
		t.Fatal(err)
	}

	armed := notifier.shown().announcement()
	if !strings.Contains(armed.Body, "DP-1") {
		t.Errorf("announcement = %q, want it to name the display", armed.Body)
	}
	// And again once it has run out: the replacement is what is on screen for
	// the last moment before the desktop goes.
	if last := notifier.shown().lastReplacement(t); !strings.Contains(last.Body, "DP-1") {
		t.Errorf("replacement = %q, want it to name the display", last.Body)
	}
}

// A countdown that could not read the display still has to read as a sentence,
// rather than trailing an "on" with nothing after it.
func TestCountdownWithNoDisplayReadsAsASentence(t *testing.T) {
	notifier := &fakeNotifier{actions: true}

	if err := Countdown(context.Background(), CountdownOpts{
		Grace:      10 * time.Millisecond,
		RuntimeDir: t.TempDir(),
		Notifier:   notifier,
	}); err != nil {
		t.Fatal(err)
	}

	armed := notifier.shown().announcement().Body
	if !strings.HasPrefix(armed, "Entering console mode in ") {
		t.Errorf("announcement = %q, want the display left out cleanly", armed)
	}
	replaced := notifier.shown().lastReplacement(t).Body
	if !strings.HasPrefix(replaced, "Entering console mode. ") {
		t.Errorf("replacement = %q, want the display left out cleanly", replaced)
	}
}

// The countdown that ran out must not leave a notification still offering to
// cancel it. Closing alone is not enough: Omarchy's shell gives a critical
// popup no lifetime, ignores the sender's close, and restores what is still on
// screen when the desktop comes back -- so the stale countdown returned with
// every login, offering to call off an entry that had already happened.
func TestCountdownReplacesTheAnnouncementWhenItRunsOut(t *testing.T) {
	notifier := &fakeNotifier{actions: true}

	if err := Countdown(context.Background(), CountdownOpts{
		Grace:      10 * time.Millisecond,
		RuntimeDir: t.TempDir(),
		Notifier:   notifier,
	}); err != nil {
		t.Fatalf("Countdown = %v, want the grace to have run out", err)
	}

	last := notifier.shown().lastReplacement(t)
	if strings.Contains(strings.ToLower(last.Body), "cancel") {
		t.Errorf("body = %q, still offers to cancel an entry that is happening", last.Body)
	}
	if last.Critical {
		t.Error("the replacement is critical, so a server that never expires those keeps it for ever")
	}
	if last.Timeout <= 0 {
		t.Errorf("timeout = %v, want a life short enough to leave on its own", last.Timeout)
	}
	if len(last.Actions) != 0 {
		t.Errorf("actions = %v, want none: there is nothing left to click", last.Actions)
	}
}
