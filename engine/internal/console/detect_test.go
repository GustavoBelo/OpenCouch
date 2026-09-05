package console

import (
	"os"
	"path/filepath"
	"testing"
)

// The gamescope session is identified by what it declares, never by a package
// name or a file path: CachyOS ships gamescope-session-cachyos, ChimeraOS ships
// gamescope-session-git, and both put the entry somewhere different.
func TestFindGamescopeSessionMatchesOnTheDeclaredDesktopName(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "omarchy.desktop"), `[Desktop Entry]
Name=Omarchy (Hyprland uwsm)
Exec=uwsm start -g -1 -e -D Hyprland hyprland.desktop
DesktopNames=Hyprland
Type=Application
`)
	write(t, filepath.Join(dir, "gamescope-session.desktop"), `[Desktop Entry]
Name=Gamescope
Exec=start-gamescope-session
DesktopNames=gamescope
Type=Application
`)

	entries := FindEntries([]string{dir})
	got, ok := FindGamescopeSession(entries)
	if !ok {
		t.Fatal("the gamescope session was not found")
	}
	if got.File() != "gamescope-session.desktop" {
		t.Errorf("file = %q", got.File())
	}
	if len(got.Exec) != 1 || got.Exec[0] != "start-gamescope-session" {
		t.Errorf("Exec = %v", got.Exec)
	}
}

func TestFindGamescopeSessionRefusesWhenAbsent(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "omarchy.desktop"), "[Desktop Entry]\nDesktopNames=Hyprland\nExec=/bin/true\n")
	if _, ok := FindGamescopeSession(FindEntries([]string{dir})); ok {
		t.Fatal("no gamescope session is installed; none must be reported")
	}
}

// A local entry shadows the packaged one for the login manager, so it has to
// shadow it here too -- otherwise the wrapper would run a different command
// from the one the machine actually boots.
func TestFindEntriesPrefersTheEarlierDirectory(t *testing.T) {
	local, system := t.TempDir(), t.TempDir()
	write(t, filepath.Join(local, "omarchy.desktop"), "[Desktop Entry]\nName=Local\nExec=local-cmd\nDesktopNames=Hyprland\n")
	write(t, filepath.Join(system, "omarchy.desktop"), "[Desktop Entry]\nName=System\nExec=system-cmd\nDesktopNames=Hyprland\n")

	entries := FindEntries([]string{local, system})
	if len(entries) != 1 {
		t.Fatalf("got %d entries, want the shadowed one only: %+v", len(entries), entries)
	}
	if entries[0].Name != "Local" {
		t.Errorf("Name = %q, want the local entry to win", entries[0].Name)
	}
}

// A session entry may carry action groups whose Exec= is not the session's.
func TestReadEntryIgnoresOtherGroups(t *testing.T) {
	path := filepath.Join(t.TempDir(), "s.desktop")
	write(t, path, `[Desktop Entry]
Name=Real
Exec=the-real-command
DesktopNames=gamescope

[Desktop Action Other]
Name=Other
Exec=the-wrong-command
`)
	entry, err := ReadEntry(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(entry.Exec) != 1 || entry.Exec[0] != "the-real-command" {
		t.Errorf("Exec = %v", entry.Exec)
	}
}

func TestParseExec(t *testing.T) {
	cases := []struct {
		line string
		want []string
	}{
		{"start-gamescope-session", []string{"start-gamescope-session"}},
		{"uwsm start -g -1 -e -D Hyprland hyprland.desktop",
			[]string{"uwsm", "start", "-g", "-1", "-e", "-D", "Hyprland", "hyprland.desktop"}},
		// Field codes are placeholders a launcher fills in; a session is never
		// launched with any, so they must not survive as empty arguments.
		{"cmd %U --flag %f", []string{"cmd", "--flag"}},
		{`cmd "an argument with spaces" tail`, []string{"cmd", "an argument with spaces", "tail"}},
		{"cmd 100%% sure", []string{"cmd", "100%", "sure"}},
		{"   spaced   out   ", []string{"spaced", "out"}},
		{"", nil},
	}
	for _, tc := range cases {
		got := ParseExec(tc.line)
		if len(got) != len(tc.want) {
			t.Errorf("ParseExec(%q) = %v, want %v", tc.line, got, tc.want)
			continue
		}
		for i := range got {
			if got[i] != tc.want[i] {
				t.Errorf("ParseExec(%q) = %v, want %v", tc.line, got, tc.want)
				break
			}
		}
	}
}

// An empty quoted argument is still an argument: dropping it would shift every
// flag that follows.
func TestParseExecKeepsEmptyQuotedArguments(t *testing.T) {
	got := ParseExec(`cmd "" tail`)
	if len(got) != 3 || got[1] != "" {
		t.Errorf("ParseExec = %#v, want an empty middle argument", got)
	}
}

// A session installed under $HOME wins over the packaged one of the same name,
// because that is the one the login manager itself reads first.
func TestSessionDirsReadsTheLocalOverrideFirst(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	withSessionRoots(t, "/packaged")

	got := SessionDirs()
	want := []string{filepath.Join(home, ".local", "share", "wayland-sessions"), "/packaged"}
	if len(got) != len(want) {
		t.Fatalf("SessionDirs = %q, want %q", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("SessionDirs = %q, want %q", got, want)
		}
	}
}

// The packaged roots are the seam: without it every test that asks what
// sessions this machine has is really asking what the machine it runs on has
// installed.
func TestSessionDirsFollowsTheConfiguredRoots(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	withSessionRoots(t, "/one", "/two")

	got := SessionDirs()
	if len(got) != 3 || got[1] != "/one" || got[2] != "/two" {
		t.Errorf("SessionDirs = %q, want the configured roots after the home one", got)
	}
	for _, dir := range got {
		if dir == "/usr/share/wayland-sessions" {
			t.Error("SessionDirs still reads the real system directory")
		}
	}
}

func withSessionRoots(t *testing.T, roots ...string) {
	t.Helper()
	original := SessionRoots
	SessionRoots = roots
	t.Cleanup(func() { SessionRoots = original })
}

func write(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}
