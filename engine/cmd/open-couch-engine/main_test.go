package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/GustavoBelo/OpenCouch/engine/internal/console"
)

// A configuration file that will not parse must not end the login.
//
// It is the exact shape of failure safe mode exists to break -- the session
// dies in milliseconds and a picker-less greeter offers it straight back --
// except that it happens before the wrapper runs, so the counter never sees it
// and the hold never trips. Hosting the desktop with the defaults is the way
// out: the file can be fixed from a desktop, never from a login screen.
func TestLoadForHostingSurvivesAnUnreadableConfig(t *testing.T) {
	config := t.TempDir()
	state := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", config)
	t.Setenv("XDG_CACHE_HOME", state)
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())

	base := filepath.Join(config, "open-couch")
	if err := os.MkdirAll(base, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(console.ConfigPath(base), []byte("{ half a file"), 0o644); err != nil {
		t.Fatal(err)
	}

	e, notes := loadForHosting()
	if e.Base == "" || e.StateDir == "" || e.RuntimeDir == "" {
		t.Fatalf("loadForHosting gave up on a corrupt config: %+v", e)
	}
	// Normalized, not merely zeroed: everything downstream reads a boot mode.
	if e.Config.Boot != console.BootDesktop {
		t.Errorf("boot mode is %q, want the normalized default", e.Config.Boot)
	}
	if len(notes) == 0 {
		t.Error("nothing was left in the log about the file that could not be read")
	}
	// And the user hears it. The machine looks fine from the outside -- it logs
	// in, it just ignores everything they chose -- so the desktop about to come
	// up is the only place the news can reach them.
	reason, ok := console.TakeFailure(e.StateDir)
	if !ok {
		t.Fatal("no breadcrumb for the settings that could not be read")
	}
	if !strings.Contains(reason, "console.json") {
		t.Errorf("the breadcrumb %q does not name the file to fix", reason)
	}
}

// Nothing resolvable at all -- no home, no runtime directory -- still yields a
// wrapper's worth of env rather than an error. Every empty field here is one
// the wrapper already treats as "nothing to record".
func TestLoadForHostingSurvivesNowhereToWrite(t *testing.T) {
	t.Setenv("HOME", "")
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv("XDG_CACHE_HOME", "")
	t.Setenv("XDG_RUNTIME_DIR", "")

	e, notes := loadForHosting()
	if e.RuntimeDir != "" {
		t.Errorf("runtime dir is %q with XDG_RUNTIME_DIR unset", e.RuntimeDir)
	}
	if len(notes) == 0 {
		t.Error("a login with nowhere to write said nothing about it")
	}
	if e.Config.Boot != console.BootDesktop {
		t.Errorf("boot mode is %q, want the normalized default", e.Config.Boot)
	}
}

// `host-session` typed inside a desktop is a command refusing, not a login
// collapsing. The floor exists because a login manager offers the same session
// again within the second; nothing is waiting to retry this, and the person who
// typed it is at a terminal reading the answer.
func TestHostSessionRefusesInsideASessionWithoutWaiting(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	runtimeDir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", runtimeDir)
	// A compositor already running, the way SessionRunning finds one.
	if err := os.WriteFile(filepath.Join(runtimeDir, "wayland-1"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WAYLAND_DISPLAY", "wayland-1")

	begun := time.Now()
	err := hostSession(context.Background())
	waited := time.Since(begun)

	if !errors.Is(err, console.ErrNotALogin) {
		t.Fatalf("err = %v, want the refusal", err)
	}
	if waited > 2*time.Second {
		t.Errorf("waited %s before refusing; the floor is for logins, not for a command typed at a terminal", waited)
	}
}
