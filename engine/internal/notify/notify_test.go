package notify

import (
	"reflect"
	"testing"
	"time"

	"github.com/godbus/dbus/v5"
)

func TestActionListIsFlattenedPairs(t *testing.T) {
	n := &busNotifier{caps: map[string]bool{"actions": true}}
	got := n.actionList([]Action{{Key: "cancel", Label: "Cancel"}, {Key: DefaultAction, Label: "Cancel"}})
	want := []string{"cancel", "Cancel", DefaultAction, "Cancel"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("actionList = %v, want %v", got, want)
	}
}

// A server that never claimed to do actions is sent none: it would drop them,
// and the body has already told the user to type a command instead.
func TestActionListIsEmptyWhereActionsAreNotSupported(t *testing.T) {
	n := &busNotifier{caps: map[string]bool{"body": true}}
	if got := n.actionList([]Action{{Key: "cancel", Label: "Cancel"}}); len(got) != 0 {
		t.Errorf("actionList = %v, want none", got)
	}
	if n.Actions() {
		t.Error("Actions() must follow what the server said it can do")
	}
}

func TestExpiry(t *testing.T) {
	if got := expiry(0); got != -1 {
		t.Errorf("expiry(0) = %d, want the server's own choice (-1)", got)
	}
	if got := expiry(20 * time.Second); got != 20000 {
		t.Errorf("expiry(20s) = %d, want 20000", got)
	}
}

func TestCriticalIsAnUrgencyHint(t *testing.T) {
	if got := hints(Notification{}); len(got) != 0 {
		t.Errorf("hints = %v, want none for an ordinary message", got)
	}
	got := hints(Notification{Critical: true})
	urgency, ok := got["urgency"]
	if !ok {
		t.Fatalf("hints = %v, want an urgency", got)
	}
	if urgency.Value() != byte(2) {
		t.Errorf("urgency = %v, want 2 so the server does not expire it", urgency.Value())
	}
}

func TestActionFromSignal(t *testing.T) {
	good := &dbus.Signal{Path: objectPath, Name: actionInvoked, Body: []any{uint32(7), "cancel"}}
	id, key, ok := actionFromSignal(good)
	if !ok || id != 7 || key != "cancel" {
		t.Errorf("actionFromSignal = %d, %q, %v", id, key, ok)
	}

	for name, signal := range map[string]*dbus.Signal{
		"nil":            nil,
		"another object": {Path: dbus.ObjectPath("/somewhere/else"), Name: actionInvoked, Body: []any{uint32(7), "cancel"}},
		"short body":     {Path: objectPath, Name: actionInvoked, Body: []any{uint32(7)}},
		"wrong types":    {Path: objectPath, Name: actionInvoked, Body: []any{"7", 3}},
	} {
		if _, _, ok := actionFromSignal(signal); ok {
			t.Errorf("%s: accepted a signal it should have ignored", name)
		}
	}
}

func TestClosedFromSignal(t *testing.T) {
	id, ok := closedFromSignal(&dbus.Signal{Path: objectPath, Name: notificationClosed, Body: []any{uint32(3), uint32(2)}})
	if !ok || id != 3 {
		t.Errorf("closedFromSignal = %d, %v", id, ok)
	}
	if _, ok := closedFromSignal(&dbus.Signal{Path: objectPath, Name: notificationClosed}); ok {
		t.Error("accepted a signal with no id")
	}
}

func TestAHandleDeliversOneAnswerAndSurvivesRetirement(t *testing.T) {
	h := &busHandle{answers: make(chan string, 1)}
	h.answer("cancel")
	// A second click on a notification whose first click is still being acted
	// on is not a second decision.
	h.answer("cancel")
	h.retire()
	// The buffered answer has to survive the close, because servers send
	// ActionInvoked and NotificationClosed one after the other.
	if key, ok := <-h.Invoked(); !ok || key != "cancel" {
		t.Errorf("first read = %q, %v, want the answer", key, ok)
	}
	if _, ok := <-h.Invoked(); ok {
		t.Error("the channel must be closed once the notification has gone")
	}
	// Retiring twice happens: the server closes a notification we just closed.
	h.retire()
}

// The fallback cannot be answered, and a nil channel blocks forever in a
// select, which is exactly what that means.
func TestTheCommandFallbackTakesNoAnswer(t *testing.T) {
	if (commandNotifier{}).Actions() {
		t.Error("notify-send cannot take an answer back")
	}
	if (commandHandle{}).Invoked() != nil {
		t.Error("a notification that cannot be answered must never yield one")
	}
}
