package console

import (
	"strings"
	"testing"
)

// Asking "which session is running" inside a hosted session answers with the
// hosting entry. Recording that would make the wrapper host itself and the user
// would never reach a desktop.
func TestHostsConsoleRecognisesAHostingEntry(t *testing.T) {
	hosting := Entry{Exec: []string{"/home/u/.local/bin/open-couch-engine", "host-session"}}
	if !HostsConsole(hosting) {
		t.Error("a hosting entry was not recognised")
	}
	for _, plain := range []Entry{
		{Exec: []string{"uwsm", "start", "-g", "-1", "-e", "-D", "Hyprland", "hyprland.desktop"}},
		{Exec: []string{"start-gamescope-session"}},
		{Exec: []string{"open-couch-engine", "enter"}},
		{Exec: []string{"session"}},
		// `console` alone appears in plenty of unrelated commands; only the
		// pair means a wrapper.
		{Exec: []string{"kitty", "--session", "console"}},
		{Exec: nil},
	} {
		if HostsConsole(plain) {
			t.Errorf("%v was mistaken for a hosting entry", plain.Exec)
		}
	}
}

// Somebody else's hosting entry is not a desktop either. hyprmoncfg hosts
// sessions the same way and shares machines with this; reading its wrapper as
// somewhere to come back to would have this wrapper host that one, and the user
// would never reach a desktop.
func TestHostsConsoleRecognisesAForeignHostingEntry(t *testing.T) {
	byExec := Entry{Exec: []string{"/home/u/.local/bin/hyprmoncfg", "console", "session"}}
	if !HostsConsole(byExec) {
		t.Error("hyprmoncfg's wrapper command was not recognised")
	}
	// Its entry may point at a wrapper script instead, and then only the
	// marker gives it away.
	byMarker := Entry{Exec: []string{"/home/u/.local/share/hyprmoncfg-spike/session-wrapper.sh"}, Hosting: true}
	if !HostsConsole(byMarker) {
		t.Error("a hosting entry behind a wrapper script was not recognised")
	}
}

// Running setup twice must not stack the suffix.
func TestHostsConsoleTrustsTheMarkerWhateverTheCommand(t *testing.T) {
	viaScript := Entry{Exec: []string{"/home/u/.local/share/some/wrapper.sh"}, Hosting: true}
	if !HostsConsole(viaScript) {
		t.Error("a marked entry was not recognised as hosting")
	}
	if HostsConsole(Entry{Exec: []string{"/home/u/.local/share/some/wrapper.sh"}}) {
		t.Error("an unmarked script was mistaken for a hosting entry")
	}
}

func TestEntryContentCarriesTheMarker(t *testing.T) {
	if !contains(EntryContent("X", "open-couch-engine"), HostingMarker+"=true") {
		t.Error("the generated entry does not mark itself as hosting")
	}
}

// Entries generated before the marker existed point at a wrapper script, so
// neither the marker nor the Exec line gives them away. The name we write is
// the last thing left to recognise them by.
func TestHostsConsoleRecognisesTheNameSetupWrites(t *testing.T) {
	old := Entry{Path: "/usr/local/share/wayland-sessions/" + HostingEntryFile,
		Exec: []string{"/home/u/.local/share/spike/session-wrapper.sh"}}
	if !HostsConsole(old) {
		t.Error("an entry with our own file name was not recognised as hosting")
	}
	if HostsConsole(Entry{Path: "/usr/share/wayland-sessions/omarchy.desktop", Exec: []string{"uwsm", "start"}}) {
		t.Error("an ordinary session was mistaken for a hosting one")
	}
}

// Coming back to the console is coming back to what you are leaving.
func TestIsGamescopeSession(t *testing.T) {
	if !IsGamescopeSession(Entry{DesktopNames: []string{"gamescope"}}) {
		t.Error("the gamescope session was not recognised")
	}
	if IsGamescopeSession(Entry{DesktopNames: []string{"hyprland"}}) {
		t.Error("an ordinary session was mistaken for the console")
	}
}

// A hosting entry may point at a wrapper script, carry no marker, and be called
// anything -- which is exactly what was installed on the machine this was first
// tested on. The generated name is what still gives it away, because both
// programs that host sessions build it with HostingEntryName.
func TestHostsConsoleRecognisesAHostingEntryByItsName(t *testing.T) {
	behindScript := Entry{
		Name: "Omarchy (hyprmoncfg console switch)",
		Exec: []string{"/home/u/.local/share/hyprmoncfg-spike/session-wrapper.sh"},
	}
	if !HostsConsole(behindScript) {
		t.Error("a hosting entry behind a wrapper script was read as a desktop")
	}
	// And an ordinary desktop is still an ordinary desktop.
	for _, plain := range []Entry{
		{Name: "Omarchy (Hyprland uwsm)", Exec: []string{"uwsm", "start", "omarchy.desktop"}},
		{Name: "Hyprland", Exec: []string{"Hyprland"}},
		{Name: "Plasma (Wayland)", Exec: []string{"startplasma-wayland"}},
	} {
		if HostsConsole(plain) {
			t.Errorf("%q was mistaken for a hosting entry", plain.Name)
		}
	}
}

// The entry is named after the product, not the desktop. Naming it after the
// desktop put two near-identical entries in the greeter on a machine that also
// had hyprmoncfg, which names its own the same way.
func TestHostingEntryNameNamesTheProduct(t *testing.T) {
	if got := HostingEntryName(); got != "Open Couch (console switch)" {
		t.Errorf("HostingEntryName() = %q", got)
	}
	// And it still ends with the mark that lets HostsConsole recognise it.
	if !contains(HostingEntryName(), hostingNameMark) {
		t.Errorf("%q would not be recognised as a hosting entry", HostingEntryName())
	}
	// The desktop it hosts moves to the Comment, where there is room for it.
	body := EntryContent("Omarchy (Hyprland uwsm)", "cmd")
	if !contains(body, "Name=Open Couch (console switch)") {
		t.Errorf("entry = %q", body)
	}
	if !contains(body, "Comment=Hosts Omarchy (Hyprland uwsm) and") {
		t.Errorf("the entry does not say which desktop it hosts:\n%s", body)
	}
}

// A package can install the hosting entry itself, because the engine it points
// at is on PATH for every account. When it has, setup has nothing to install
// and should not print a sudo command for a file that is already there.
func TestInstalledHostingEntryFindsOnlyOursInASystemDirectory(t *testing.T) {
	const self = "/usr/bin/open-couch-engine"
	old := SessionRoots
	SessionRoots = []string{"/usr/local/share/wayland-sessions", "/usr/share/wayland-sessions"}
	t.Cleanup(func() { SessionRoots = old })

	ours := Entry{
		Path: "/usr/share/wayland-sessions/open-couch-session.desktop",
		Name: "Open Couch (console switch)",
		Exec: []string{self, "host-session"},
	}
	if _, ok := InstalledHostingEntry([]Entry{ours}, self); !ok {
		t.Error("the entry a package installed was not recognised")
	}

	for _, other := range []Entry{
		// In the user's own directory: not something a package put there, and
		// on most login managers not something the greeter reads either.
		{Path: "/home/u/.local/share/wayland-sessions/open-couch-session.desktop",
			Exec: []string{self, "host-session"}},
		// Another build's entry. Pointing a login at it would run a binary this
		// user may not even have.
		{Path: "/usr/share/wayland-sessions/open-couch-session.desktop",
			Exec: []string{"/home/someone/.local/bin/open-couch-engine", "host-session"}},
		// Somebody else's wrapper entirely.
		{Path: "/usr/share/wayland-sessions/hyprmoncfg-session.desktop",
			Name: "Omarchy (hyprmoncfg console switch)", Exec: []string{"/usr/bin/hyprmoncfg", "console", "session"}},
		// An ordinary desktop.
		{Path: "/usr/share/wayland-sessions/omarchy.desktop", Exec: []string{"uwsm", "start"}},
	} {
		if _, ok := InstalledHostingEntry([]Entry{other}, self); ok {
			t.Errorf("%s was mistaken for a packaged hosting entry", other.Path)
		}
	}
}

func contains(haystack, needle string) bool {
	return strings.Contains(haystack, needle)
}

// A hosting entry whose Exec exists but whose binary has been removed is an
// unbreakable login loop: the login manager starts the session, it dies at
// once, and the greeter comes back with the same entry selected. TryExec is
// what makes the entry disappear instead.
func TestEntryContentDeclaresTryExecSoADeletedEngineHidesTheEntry(t *testing.T) {
	body := EntryContent("Omarchy", "/home/u/.local/bin/open-couch-engine")
	if !contains(body, "\nTryExec=/home/u/.local/bin/open-couch-engine\n") {
		t.Fatalf("entry has no TryExec, so a deleted engine would lock the user out:\n%s", body)
	}
	if !contains(body, "\nExec=/home/u/.local/bin/open-couch-engine "+WrapperCommand+"\n") {
		t.Fatalf("Exec does not run the wrapper:\n%s", body)
	}
}

// Steam's "Switch to Desktop" writes zz-steamos-autologin.conf, and SDDM lets
// the alphabetically last file win. Instructions naming a file that sorts
// before it hand the user a console session that works once and then stops
// being what the machine logs into.
func TestSDDMInstructionsNameAnAutologinFileThatOutsortsSteams(t *testing.T) {
	out := SetupInstructions(
		LoginManager{Kind: LoginSDDM, Unit: "sddm.service"},
		"/home/u/.config/open-couch/open-couch-session.desktop",
		"Open Couch (console switch)",
		"open-couch-engine host-session",
	)
	if !contains(out, AutologinDropIn) {
		t.Fatalf("instructions do not name %s:\n%s", AutologinDropIn, out)
	}
	if AutologinDropIn <= "zz-steamos-autologin.conf" {
		t.Fatalf("%q does not sort after Steam's zz-steamos-autologin.conf, so Steam overrules it", AutologinDropIn)
	}
	// The greeter is not a reliable route: plenty of themes show no picker.
	if !contains(out, "Not every theme has one") {
		t.Fatalf("instructions still promise a session picker that many themes lack:\n%s", out)
	}
}
