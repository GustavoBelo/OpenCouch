package console

import "testing"

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

func TestEntryContentCarriesTheDesktopIdentity(t *testing.T) {
	t.Setenv("XDG_CURRENT_DESKTOP", "")
	body := EntryContent("X", "open-couch-engine host-session", []string{"KDE"})
	if !contains(body, "DesktopNames=KDE") || !contains(body, "Exec=open-couch-engine host-session") {
		t.Fatalf("entry = %q", body)
	}

	// A desktop whose own entry names nothing falls back to what this session
	// claims to be, because that is the identity the user is already running
	// under.
	t.Setenv("XDG_CURRENT_DESKTOP", "Hyprland")
	if !contains(EntryContent("X", "cmd", nil), "DesktopNames=Hyprland") {
		t.Error("an entry with no names of its own ignored the running session")
	}

	// With nothing to fall back to, the line is left out rather than guessed.
	// Portals and polkit agents key off XDG_CURRENT_DESKTOP, so naming the
	// wrong desktop loads the wrong ones for the whole session -- worse than
	// naming none.
	t.Setenv("XDG_CURRENT_DESKTOP", "")
	if contains(EntryContent("X", "cmd", nil), "DesktopNames=") {
		t.Error("an entry with nothing to declare declared something anyway")
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
	if !contains(EntryContent("X", "open-couch-engine host-session", nil), HostingMarker+"=true") {
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
