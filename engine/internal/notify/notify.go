// Package notify puts a message on the screen and takes an answer back.
//
// The answer is the point. Open Couch only ever announces things that are about
// to happen to the user's session, and an announcement the user cannot argue
// with is only half of a warning.
package notify

import (
	"context"
	"os/exec"
	"sync"
	"time"

	"github.com/godbus/dbus/v5"
)

const (
	appName     = "Open Couch"
	destination = "org.freedesktop.Notifications"
	objectPath  = dbus.ObjectPath("/org/freedesktop/Notifications")
	iface       = "org.freedesktop.Notifications"

	actionInvoked      = iface + ".ActionInvoked"
	notificationClosed = iface + ".NotificationClosed"
)

// DefaultAction is the key a server invokes when the notification itself is
// clicked rather than one of its buttons.
//
// Registering it matters more than the buttons do: mako draws no buttons at
// all, and dunst hides them behind a context menu, so on a good many desktops
// clicking the body is the only way a person can answer.
const DefaultAction = "default"

// Action is something the user can choose. An empty Label is legal and means
// the server may show the key.
type Action struct {
	Key   string
	Label string
}

// Notification is one message.
type Notification struct {
	Summary string
	Body    string
	Icon    string
	Actions []Action
	// Timeout asks the server to take the message away again. Zero leaves the
	// choice to the server.
	Timeout time.Duration
	// Critical asks the server not to expire the message on its own. Use it
	// when the message has to outlive whatever the server's idea of a few
	// seconds is -- a countdown the user is meant to be able to answer.
	Critical bool
}

// Handle is a notification that is on screen.
type Handle interface {
	// Invoked yields the key of whatever the user chose. It closes when the
	// notification goes away, which is not an answer: it only means nobody is
	// going to click it now.
	Invoked() <-chan string
	// Replace changes the message in place, rather than stacking a second one
	// on top of it.
	Replace(ctx context.Context, note Notification) error
	// Close takes the notification off the screen.
	Close()
}

// Notifier shows notifications.
type Notifier interface {
	// Actions reports whether this server can take an answer back. When it
	// cannot, the message has to say what to type instead.
	Actions() bool
	Show(ctx context.Context, note Notification) (Handle, error)
	Close()
}

// Dial finds somewhere to send notifications, and never fails.
//
// It is best effort by design: a machine with no notification server is not a
// machine that should stop being able to enter console mode. The caller gets a
// notifier that quietly does nothing rather than an error to handle.
func Dial() Notifier {
	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		return commandNotifier{}
	}

	n := &busNotifier{
		conn: conn,
		obj:  conn.Object(destination, objectPath),
		caps: map[string]bool{},
		live: map[uint32]*busHandle{},
		done: make(chan struct{}),
	}

	var caps []string
	if err := n.obj.Call(iface+".GetCapabilities", 0).Store(&caps); err != nil {
		// A session bus with nothing listening on it is no better than no bus.
		_ = conn.Close()
		return commandNotifier{}
	}
	for _, c := range caps {
		n.caps[c] = true
	}

	// Subscribe before the first Notify, not after: a match added later would
	// miss an answer given in between.
	signals := make(chan *dbus.Signal, 8)
	conn.Signal(signals)
	if err := conn.AddMatchSignal(
		dbus.WithMatchObjectPath(objectPath),
		dbus.WithMatchInterface(iface),
	); err != nil {
		conn.RemoveSignal(signals)
		_ = conn.Close()
		return commandNotifier{}
	}
	n.signals = signals
	go n.dispatch()
	return n
}

type busNotifier struct {
	conn    *dbus.Conn
	obj     dbus.BusObject
	caps    map[string]bool
	signals chan *dbus.Signal
	done    chan struct{}

	mu   sync.Mutex
	live map[uint32]*busHandle
}

func (n *busNotifier) Actions() bool { return n.caps["actions"] }

func (n *busNotifier) Show(ctx context.Context, note Notification) (Handle, error) {
	h := &busHandle{n: n, answers: make(chan string, 1)}

	// The lock spans the call and the bookkeeping so that dispatch cannot see
	// an answer for an id this map does not know about yet.
	n.mu.Lock()
	defer n.mu.Unlock()

	id, err := n.send(ctx, 0, note)
	if err != nil {
		return nil, err
	}
	h.id = id
	n.live[id] = h
	return h, nil
}

func (n *busNotifier) Close() {
	select {
	case <-n.done:
		return
	default:
	}
	close(n.done)
	n.conn.RemoveSignal(n.signals)
	_ = n.conn.Close()
}

// send is the Notify call. replaces of zero asks for a new notification.
func (n *busNotifier) send(ctx context.Context, replaces uint32, note Notification) (uint32, error) {
	var id uint32
	call := n.obj.CallWithContext(ctx, iface+".Notify", 0,
		appName,
		replaces,
		note.Icon,
		note.Summary,
		note.Body,
		n.actionList(note.Actions),
		hints(note),
		expiry(note.Timeout),
	)
	if err := call.Store(&id); err != nil {
		return 0, err
	}
	return id, nil
}

// actionList flattens actions into the key, label, key, label list the
// protocol wants. A server that never said it does actions is sent none: it
// would drop them anyway, and the body text has already told the user to type a
// command instead.
func (n *busNotifier) actionList(actions []Action) []string {
	if !n.Actions() || len(actions) == 0 {
		return []string{}
	}
	flat := make([]string, 0, len(actions)*2)
	for _, a := range actions {
		flat = append(flat, a.Key, a.Label)
	}
	return flat
}

func (n *busNotifier) dispatch() {
	for {
		select {
		case <-n.done:
			return
		case signal, ok := <-n.signals:
			if !ok {
				return
			}
			switch signal.Name {
			case actionInvoked:
				if id, key, ok := actionFromSignal(signal); ok {
					n.answer(id, key)
				}
			case notificationClosed:
				if id, ok := closedFromSignal(signal); ok {
					n.retire(id)
				}
			}
		}
	}
}

func (n *busNotifier) answer(id uint32, key string) {
	n.mu.Lock()
	h := n.live[id]
	n.mu.Unlock()
	if h != nil {
		h.answer(key)
	}
}

func (n *busNotifier) retire(id uint32) {
	n.mu.Lock()
	h := n.live[id]
	delete(n.live, id)
	n.mu.Unlock()
	if h != nil {
		h.retire()
	}
}

type busHandle struct {
	n  *busNotifier
	id uint32

	answers chan string
	once    sync.Once
}

func (h *busHandle) Invoked() <-chan string { return h.answers }

func (h *busHandle) Replace(ctx context.Context, note Notification) error {
	h.n.mu.Lock()
	defer h.n.mu.Unlock()
	_, err := h.n.send(ctx, h.id, note)
	return err
}

func (h *busHandle) Close() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = h.n.obj.CallWithContext(ctx, iface+".CloseNotification", 0, h.id).Store()
	h.n.retire(h.id)
}

// answer delivers at most one choice. A second click on a notification whose
// first click is still being acted on is not a second decision.
func (h *busHandle) answer(key string) {
	select {
	case h.answers <- key:
	default:
	}
}

func (h *busHandle) retire() {
	// Buffered answers survive the close, so an answer immediately followed by
	// the server closing the notification is still delivered.
	h.once.Do(func() { close(h.answers) })
}

func hints(note Notification) map[string]dbus.Variant {
	h := map[string]dbus.Variant{}
	if note.Critical {
		h["urgency"] = dbus.MakeVariant(byte(2))
	}
	return h
}

// expiry is the protocol's expire_timeout: milliseconds, or -1 for whatever the
// server thinks is right.
func expiry(timeout time.Duration) int32 {
	if timeout <= 0 {
		return -1
	}
	return int32(timeout.Milliseconds())
}

func actionFromSignal(signal *dbus.Signal) (uint32, string, bool) {
	if signal == nil || signal.Path != objectPath || len(signal.Body) < 2 {
		return 0, "", false
	}
	id, ok := signal.Body[0].(uint32)
	if !ok {
		return 0, "", false
	}
	key, ok := signal.Body[1].(string)
	if !ok {
		return 0, "", false
	}
	return id, key, true
}

func closedFromSignal(signal *dbus.Signal) (uint32, bool) {
	if signal == nil || signal.Path != objectPath || len(signal.Body) == 0 {
		return 0, false
	}
	id, ok := signal.Body[0].(uint32)
	return id, ok
}

// commandNotifier is the fallback: notify-send, which every desktop has, and
// which cannot take an answer back.
type commandNotifier struct{}

func (commandNotifier) Actions() bool { return false }
func (commandNotifier) Close()        {}

func (c commandNotifier) Show(ctx context.Context, note Notification) (Handle, error) {
	send(ctx, note)
	return commandHandle{}, nil
}

type commandHandle struct{}

// Invoked is nil on purpose: a nil channel blocks forever in a select, which is
// exactly what "this notification can never be answered" means.
func (commandHandle) Invoked() <-chan string { return nil }
func (commandHandle) Close()                 {}

func (commandHandle) Replace(ctx context.Context, note Notification) error {
	send(ctx, note)
	return nil
}

// send is best effort in the same way the rest of this package is: a machine
// with no notify-send still gets whatever the caller logged.
func send(ctx context.Context, note Notification) {
	path, err := exec.LookPath("notify-send")
	if err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	_ = exec.CommandContext(ctx, path, "-a", appName, note.Summary, note.Body).Run()
}
