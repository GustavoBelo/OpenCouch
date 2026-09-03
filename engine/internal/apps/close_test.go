package apps

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func fakeProc(t *testing.T, byPid map[int]string) {
	t.Helper()
	root := t.TempDir()
	for pid, comm := range byPid {
		dir := filepath.Join(root, itoa(pid))
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "comm"), []byte(comm+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// Something that is not a pid at all, which /proc is full of.
	if err := os.MkdirAll(filepath.Join(root, "self"), 0o755); err != nil {
		t.Fatal(err)
	}
	old := procRoot
	procRoot = root
	t.Cleanup(func() { procRoot = old })
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	digits := []byte{}
	for i > 0 {
		digits = append([]byte{byte('0' + i%10)}, digits...)
		i /= 10
	}
	return string(digits)
}

// recordSignals replaces the kill with a recorder, so a test never sends a real
// signal to a real process.
func recordSignals(t *testing.T) *[]int {
	t.Helper()
	sent := []int{}
	old := signal
	signal = func(pid int, sig syscall.Signal) error {
		if sig != syscall.SIGTERM {
			t.Errorf("sent %v to %d, want SIGTERM", sig, pid)
		}
		sent = append(sent, pid)
		return nil
	}
	t.Cleanup(func() { signal = old })
	return &sent
}

func TestCloseMatchesTheWholeProcessName(t *testing.T) {
	fakeProc(t, map[int]string{10: "discord", 11: "discord", 12: "firefox"})
	sent := recordSignals(t)

	results := Close([]string{"discord"})
	if len(results) != 1 || results[0].Closed != 2 {
		t.Fatalf("results = %+v, want discord closed twice", results)
	}
	if len(*sent) != 2 {
		t.Fatalf("signalled %v, want both discord pids", *sent)
	}

	// A substring is not a match: asking to close "cord" must not close
	// Discord, and asking to close "fire" must not close Firefox.
	*sent = nil
	if results := Close([]string{"cord", "fire"}); results[0].Closed != 0 || results[1].Closed != 0 {
		t.Errorf("results = %+v, want nothing closed by a substring", results)
	}
	if len(*sent) != 0 {
		t.Errorf("signalled %v on a substring match", *sent)
	}
}

// Closing the compositor would end the desktop without the wrapper being asked
// to switch, leaving the user in a dead session rather than in the console.
func TestCloseRefusesProtectedNames(t *testing.T) {
	fakeProc(t, map[int]string{10: "plasmashell", 11: "Hyprland", 12: "steam", 13: "open-couch-engine"})
	sent := recordSignals(t)

	results := Close([]string{"plasmashell", "Hyprland", "steam", "open-couch-engine", "PLASMASHELL"})
	for _, r := range results {
		if !r.Skipped || r.Closed != 0 {
			t.Errorf("%q was not protected: %+v", r.Name, r)
		}
	}
	if len(*sent) != 0 {
		t.Fatalf("signalled %v despite every name being protected", *sent)
	}
}

// The list is written once and carried between machines, so a name that only
// matters on another desktop still has to be refused here.
func TestProtectedCoversEveryHostableDesktop(t *testing.T) {
	for _, name := range []string{
		"plasmashell", "kwin_wayland", // KDE
		"Hyprland", "uwsm", // Hyprland
		"gnome-shell", "mutter", // GNOME
		"gamescope", "steam", // the point of the exercise
		"open-couch-engine", // this
	} {
		if !IsProtected(name) {
			t.Errorf("%q is not protected", name)
		}
	}
	if IsProtected("discord") || IsProtected("") {
		t.Error("an ordinary application was treated as protected")
	}
}

func TestCloseIgnoresNamesThatAreNotRunning(t *testing.T) {
	fakeProc(t, map[int]string{10: "firefox"})
	recordSignals(t)

	results := Close([]string{"discord", "  ", ""})
	if len(results) != 1 {
		t.Fatalf("results = %+v, want blank names dropped", results)
	}
	if results[0].Closed != 0 || results[0].Skipped {
		t.Errorf("results = %+v, want discord reported as closing nothing", results)
	}
}
