package console

import (
	"context"
	"strings"
	"testing"
)

// A pending request is somebody saying what they want right now; a boot
// preference is what they said once. The instruction has to win, or
// `console enter` on a machine set to boot to the desktop would be ignored --
// the compositor exits and the wrapper puts the desktop straight back.
func TestBootModeForLetsARequestBeatThePreference(t *testing.T) {
	got := BootModeFor(BootDesktop, ModeConsole, true, ModeDesktop, true)
	if got != ModeConsole {
		t.Fatalf("got %q, want the request honoured over the preference", got)
	}
}

func TestBootModeForFollowsThePreference(t *testing.T) {
	cases := []struct {
		boot    BootMode
		last    Mode
		hasLast bool
		want    Mode
	}{
		{BootDesktop, ModeConsole, true, ModeDesktop},
		{BootConsole, ModeDesktop, true, ModeConsole},
		{BootLast, ModeConsole, true, ModeConsole},
		{BootLast, ModeDesktop, true, ModeDesktop},
		// Nothing recorded yet -- a first boot after turning "last" on -- has to
		// land somewhere, and the desktop is the answer that cannot strand
		// anyone.
		{BootLast, "", false, ModeDesktop},
		{"", "", false, ModeDesktop},
	}
	for _, tc := range cases {
		if got := BootModeFor(tc.boot, "", false, tc.last, tc.hasLast); got != tc.want {
			t.Errorf("BootModeFor(%q, last=%q/%v) = %q, want %q", tc.boot, tc.last, tc.hasLast, got, tc.want)
		}
	}
}

// The record has to survive the machine being switched off, which is the only
// case "last" exists for.
func TestLastModeRoundTrips(t *testing.T) {
	dir := t.TempDir()
	if _, ok := ReadLastMode(dir); ok {
		t.Fatal("nothing was recorded, but a mode was reported")
	}
	WriteLastMode(dir, ModeConsole)
	if got, ok := ReadLastMode(dir); !ok || got != ModeConsole {
		t.Fatalf("ReadLastMode = %q ok=%v", got, ok)
	}
	// Unlike a request, it is not consumed: it is a preference, not an order.
	if got, _ := ReadLastMode(dir); got != ModeConsole {
		t.Error("reading the last mode cleared it")
	}
	WriteLastMode(dir, ModeDesktop)
	if got, _ := ReadLastMode(dir); got != ModeDesktop {
		t.Errorf("ReadLastMode = %q after overwrite", got)
	}
}

func TestLastModeRejectsRubbish(t *testing.T) {
	dir := t.TempDir()
	WriteLastMode(dir, Mode("gamescope"))
	if _, ok := ReadLastMode(dir); ok {
		t.Fatal("a mode that is not a mode must not be acted on")
	}
}

// Shut down playing, boot playing: the wrapper records the mode before it
// launches, because a machine switched off mid-session never reaches an "after".
func TestWrapperRecordsTheModeItStartsIn(t *testing.T) {
	var launched []string
	var w *Wrapper
	w = testWrapper(t, &launched, func([]string) {
		if len(launched) == 1 {
			if err := Request(w.RuntimeDir, ModeConsole); err != nil {
				t.Error(err)
			}
		}
	})
	if err := w.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	// desktop, then console, then the console hands back home.
	if got, _ := ReadLastMode(w.StateDir); got != ModeDesktop {
		t.Fatalf("last mode = %q, want the desktop it ended on", got)
	}
	if !strings.Contains(strings.Join(launched, ","), "start-gamescope-session") {
		t.Fatalf("launched %v, want the console to have run", launched)
	}
}

// A machine set to boot into the console does so with no request pending.
func TestWrapperStartsInTheConsoleWhenToldTo(t *testing.T) {
	var launched []string
	w := testWrapper(t, &launched, nil)
	w.Boot = BootConsole
	if err := w.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(launched) == 0 || launched[0] != "start-gamescope-session" {
		t.Fatalf("launched %v, want the console first", launched)
	}
}

// A machine set to boot into the console but stopping at a greeter first asks
// for a password on the desk monitor while the person waiting is on the sofa.
// Worth saying before they choose, so the doctor has to be able to tell.
func TestHasAutologinReadsSDDMWithLaterFilesWinning(t *testing.T) {
	dir := t.TempDir()
	write(t, dir+"/10-base.conf", "[Autologin]\nUser=someone\nSession=x.desktop\n")
	// Ordinary SDDM layering: a later file clears what an earlier one set.
	write(t, dir+"/99-later.conf", "[Autologin]\nUser=\n")

	old := autologinRoots
	autologinRoots = []string{dir}
	defer func() { autologinRoots = old }()

	if got := HasAutologin(LoginManager{Kind: LoginSDDM}); got != AutologinOff {
		t.Fatalf("HasAutologin = %v, want the later file to win", got)
	}

	write(t, dir+"/99-later.conf", "[Autologin]\nUser=belo\n")
	if got := HasAutologin(LoginManager{Kind: LoginSDDM}); got != AutologinOn {
		t.Fatalf("HasAutologin = %v, want autologin on", got)
	}
}

// A key outside the [Autologin] section is not an autologin.
func TestHasAutologinIgnoresOtherSections(t *testing.T) {
	dir := t.TempDir()
	write(t, dir+"/10.conf", "[General]\nUser=belo\n\n[Autologin]\nSession=x.desktop\n")
	old := autologinRoots
	autologinRoots = []string{dir}
	defer func() { autologinRoots = old }()

	if got := HasAutologin(LoginManager{Kind: LoginSDDM}); got != AutologinOff {
		t.Fatalf("HasAutologin = %v, want off", got)
	}
}

// Saying nothing beats warning wrongly: greetd, ly and the rest keep their
// answer somewhere this does not know how to read.
func TestHasAutologinAdmitsWhatItCannotRead(t *testing.T) {
	if got := HasAutologin(LoginManager{Kind: LoginGreetd}); got != AutologinUnknown {
		t.Errorf("greetd = %v, want unknown", got)
	}
	// No display manager means nothing asks anything.
	if got := HasAutologin(LoginManager{Kind: LoginNone}); got != AutologinOn {
		t.Errorf("no display manager = %v, want on", got)
	}
}
