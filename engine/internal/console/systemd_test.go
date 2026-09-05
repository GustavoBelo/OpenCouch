package console

import (
	"context"
	"errors"
	"strings"
	"testing"
)

type fakeRunner struct {
	calls  []string
	output map[string]string
	fail   map[string]bool
}

func (f *fakeRunner) Run(_ context.Context, args ...string) error {
	key := strings.Join(args, " ")
	f.calls = append(f.calls, key)
	if f.fail[key] {
		return errors.New("no")
	}
	return nil
}

func (f *fakeRunner) Output(_ context.Context, args ...string) (string, error) {
	key := strings.Join(args, " ")
	f.calls = append(f.calls, key)
	if f.fail[key] {
		return "", errors.New("no")
	}
	return f.output[key], nil
}

func (f *fakeRunner) called(substr string) bool {
	for _, c := range f.calls {
		if strings.Contains(c, substr) {
			return true
		}
	}
	return false
}

// Leaving graphical-session-pre.target active is what makes uwsm refuse the
// next compositor with "A compositor or graphical-session* target is already
// active!", and the session then dies in the same second it starts.
func TestSanitizeClearsWhatBlocksTheNextCompositor(t *testing.T) {
	f := &fakeRunner{}
	Sanitize(context.Background(), f)

	for _, want := range []string{
		"stop gamescope-session.target",
		"stop graphical-session-pre.target",
		"reset-failed",
		"unset-environment XDG_CURRENT_DESKTOP",
		"XDG_DESKTOP_PORTAL_DIR",
	} {
		if !f.called(want) {
			t.Errorf("Sanitize did not ask for %q; calls were %v", want, f.calls)
		}
	}
}

// Every step is "make sure this is not the case", so stopping something that was
// never running has to count as success. A cleanup that gave up halfway would
// leave exactly the state it exists to clear.
func TestSanitizeKeepsGoingWhenAStepFails(t *testing.T) {
	f := &fakeRunner{fail: map[string]bool{"stop gamescope-session.target": true}}
	Sanitize(context.Background(), f)
	if !f.called("reset-failed") {
		t.Errorf("Sanitize stopped early; calls were %v", f.calls)
	}
}

// graphical-session-pre.target is active throughout any healthy session, so
// treating it as leftover state would call every working machine broken.
func TestDirtyIgnoresTheAlwaysActiveTarget(t *testing.T) {
	f := &fakeRunner{output: map[string]string{
		"is-active graphical-session-pre.target": "active",
		"list-units --state=failed --no-legend":  "",
	}}
	if dirty, why := Dirty(context.Background(), f); dirty {
		t.Fatalf("a live session was reported dirty: %q", why)
	}
}

func TestDirtyReportsLeftoverFailedUnits(t *testing.T) {
	f := &fakeRunner{output: map[string]string{
		"list-units --state=failed --no-legend": "gamescope-mangoapp.service loaded failed failed mangoapp",
	}}
	dirty, why := Dirty(context.Background(), f)
	if !dirty || !strings.Contains(why, "failed units") {
		t.Fatalf("Dirty = %v %q", dirty, why)
	}
}

func TestDirtyIsQuietOnACleanManager(t *testing.T) {
	f := &fakeRunner{output: map[string]string{"list-units --state=failed --no-legend": ""}}
	if dirty, why := Dirty(context.Background(), f); dirty {
		t.Fatalf("a clean manager was reported dirty: %q", why)
	}
}

func TestTargetKnownFollowsSystemctl(t *testing.T) {
	ok := &fakeRunner{output: map[string]string{"cat gamescope-session.target": "[Unit]"}}
	if !TargetKnown(context.Background(), ok) {
		t.Error("a resolvable target was reported missing")
	}
	missing := &fakeRunner{fail: map[string]bool{"cat gamescope-session.target": true}}
	if TargetKnown(context.Background(), missing) {
		t.Error("an unresolvable target was reported present")
	}
}
