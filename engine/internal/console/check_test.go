package console

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// fakePath decides what is installed, so a requirement check can be exercised
// on a machine that has gamescope and on one that does not.
func fakePath(t *testing.T, present ...string) {
	t.Helper()
	have := map[string]bool{}
	for _, name := range present {
		have[name] = true
	}
	original := lookPath
	lookPath = func(name string) (string, error) {
		if have[name] {
			return "/usr/bin/" + name, nil
		}
		return "", errors.New("not found")
	}
	t.Cleanup(func() { lookPath = original })
}

// systemdWithout is a user manager that cannot resolve the gamescope target,
// which is what a machine with no gamescope-session package looks like.
func systemdWithout() *fakeRunner {
	return &fakeRunner{fail: map[string]bool{"cat gamescope-session.target": true}}
}

// systemdWith is a manager that resolves it.
func systemdWith() *fakeRunner {
	return &fakeRunner{output: map[string]string{"cat gamescope-session.target": "[Unit]"}}
}

// The whole point of one list: a machine missing everything must name every
// missing thing, not the first one, so the user fixes it in one pass instead of
// discovering the next problem after each reboot.
func TestRequirementsNameEverythingThatIsMissing(t *testing.T) {
	fakePath(t)
	reqs := Requirements(context.Background(), Config{}, systemdWithout(), nil, "/tmp/console.json")
	unmet := Unmet(reqs)

	for _, want := range []string{"gamescope session", "gamescope-session.target", "gamescope is not installed", "Steam is not installed", "desktop session", "no display has been chosen"} {
		if !anyContains(unmet, want) {
			t.Errorf("nothing in %q mentions %q", unmet, want)
		}
	}
}

// The panel's hand-copied subset never checked for gamescope, Steam or the
// systemd target, so it could call a machine ready that `console doctor`
// refused, and the button it drew led to a closed desktop. One list is what
// makes that impossible; this pins the three it used to skip.
func TestRequirementsCoverWhatThePanelUsedToSkip(t *testing.T) {
	fakePath(t)
	reqs := Requirements(context.Background(), Config{}, systemdWithout(), nil, "/tmp/console.json")

	for _, want := range []string{"gamescope is not installed", "Steam is not installed", "systemd cannot resolve gamescope-session.target"} {
		if !anyContains(Unmet(reqs), want) {
			t.Errorf("%q is not on the list the panel reads", want)
		}
	}
}

// A requirement that is met has to say so. A list that only ever reports
// failures cannot tell "everything is fine" from "nothing was checked", and the
// doctor prints both halves.
func TestRequirementsReportWhatIsThere(t *testing.T) {
	fakePath(t, "gamescope", "steam")
	entries := []Entry{
		{Path: "/usr/share/wayland-sessions/gamescope.desktop", DesktopNames: []string{GamescopeDesktopName}},
		{Path: "/usr/share/wayland-sessions/hyprland.desktop"},
	}
	cfg := Config{TVName: "HDMI-A-1", DesktopSession: "hyprland.desktop"}

	reqs := Requirements(context.Background(), cfg, systemdWith(), entries, "/tmp/console.json")
	for _, r := range reqs {
		// Hosted is the one that depends on this machine rather than on the
		// fixtures, so it is allowed to fail here.
		if !r.OK && !strings.Contains(r.Want, "not hosted") {
			t.Errorf("requirement failed on a complete machine: %s", r.Want)
		}
		if r.OK && strings.TrimSpace(r.Have) == "" {
			t.Error("a met requirement printed nothing")
		}
	}
	if !anyContains(havesOf(reqs), "gamescope.desktop") {
		t.Error("the gamescope entry that was found is not named")
	}
}

// Unmet carries the sentence the user acts on, not a bare boolean: it is what a
// panel lists and what an entry path refuses with, so it has to stand alone.
func TestUnmetCarriesTheActionableSentence(t *testing.T) {
	fakePath(t)
	unmet := Unmet(Requirements(context.Background(), Config{}, systemdWithout(), nil, "/etc/x/console.json"))
	if !anyContains(unmet, "/etc/x/console.json") {
		t.Errorf("the config path the user must edit is missing from %q", unmet)
	}
	if !anyContains(unmet, "install a gamescope-session package") {
		t.Errorf("no instruction in %q, only a complaint", unmet)
	}
}

func anyContains(list []string, want string) bool {
	for _, s := range list {
		if strings.Contains(s, want) {
			return true
		}
	}
	return false
}

func havesOf(reqs []Requirement) []string {
	out := []string{}
	for _, r := range reqs {
		out = append(out, r.Have)
	}
	return out
}
