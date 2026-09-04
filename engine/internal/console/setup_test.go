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
func TestHostingEntryNameDoesNotStack(t *testing.T) {
	first := HostingEntryName("Omarchy (Hyprland uwsm)")
	if first != "Omarchy (Hyprland uwsm) (console switch)" {
		t.Fatalf("name = %q", first)
	}
	if again := HostingEntryName(first); again != first {
		t.Errorf("running setup twice gave %q", again)
	}
}

// The entry carries no DesktopNames: one installed by a package serves every
// account, and they do not all come back to the same desktop. The wrapper
// exports the identity instead, which is tested in session_test.go.
func TestEntryContentIsTheSameForEveryAccount(t *testing.T) {
	body := EntryContent("X (console switch)", "/usr/bin/open-couch-engine host-session")
	if contains(body, "DesktopNames") {
		t.Errorf("the entry named a desktop it cannot know:\n%s", body)
	}
	if !contains(body, "Exec=/usr/bin/open-couch-engine host-session") || !contains(body, HostingMarker+"=true") {
		t.Errorf("entry = %q", body)
	}
}

func contains(haystack, needle string) bool {
	return len(haystack) >= len(needle) && (haystack == needle || indexOf(haystack, needle) >= 0)
}

func indexOf(h, n string) int {
	for i := 0; i+len(n) <= len(h); i++ {
		if h[i:i+len(n)] == n {
			return i
		}
	}
	return -1
}

// Reading the Exec line is not enough: a hosting entry may point at a wrapper
// script, and then it looks like an ordinary session and offers itself as
// somewhere to come back to -- which would host itself forever.
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
	if !contains(EntryContent("X", "open-couch-engine host-session"), HostingMarker+"=true") {
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

// Naming the hosting entry after another program's hosting entry stacked the
// suffix twice: "Omarchy (hyprmoncfg console switch) (console switch)".
func TestHostingEntryNameDoesNotStackAForeignSuffix(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"Omarchy", "Omarchy (console switch)"},
		{"Omarchy (console switch)", "Omarchy (console switch)"},
		{"Omarchy (hyprmoncfg console switch)", "Omarchy (console switch)"},
		{"Omarchy (hyprmoncfg console switch) (console switch)", "Omarchy (console switch)"},
	} {
		if got := HostingEntryName(tc.in); got != tc.want {
			t.Errorf("HostingEntryName(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// An entry installed where the greeter never looks is the worst outcome: the
// user logs out, cannot find the session, and nothing says why. SDDM ships
// SessionDir=/usr/local/share/wayland-sessions,/usr/share/wayland-sessions.
func TestSetupInstructionsInstallWhereTheGreeterLooks(t *testing.T) {
	for _, tc := range []struct {
		kind     LoginManagerKind
		wantSudo bool
	}{
		{LoginSDDM, true},
		{LoginGDM, true},
		{LoginLightDM, true},
		{LoginUnknown, true},
		{LoginGreetd, false},
		{LoginNone, false},
	} {
		got := SetupInstructions(LoginManager{Kind: tc.kind, Unit: "x.service"},
			"/home/u/.config/open-couch/open-couch-session.desktop", "X (console switch)", "cmd host-session")
		system := strings.Contains(got, "sudo install") && strings.Contains(got, "/usr/local/share/wayland-sessions/")
		user := strings.Contains(got, "~/.local/share/wayland-sessions/")
		if tc.wantSudo && !system {
			t.Errorf("%v: told the user to install where its greeter does not look:\n%s", tc.kind, got)
		}
		if !tc.wantSudo && !user {
			t.Errorf("%v: asked for root when the user's own directory would do:\n%s", tc.kind, got)
		}
		if system && user {
			t.Errorf("%v: gave two different install paths at once:\n%s", tc.kind, got)
		}
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
