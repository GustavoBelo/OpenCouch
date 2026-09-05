// Package console runs Steam's gamescope session in place of the desktop, and
// brings the desktop back afterwards.
//
// The shape is a *wrapper session*: the login manager starts one session that
// hosts either compositor in turn, rather than being asked to switch between two
// sessions of its own. Switching through the login manager was tried and does
// not work -- a display manager's autologin fires only when the display manager
// itself starts, so ending a session lands on the greeter, which remembers the
// last session and walks the user straight back into the one they just left.
// Worse, that route only exists on display managers that have an autologin file
// to rewrite, which rules out greetd, ly and a plain tty login.
//
// With one hosting session none of that applies: the login manager never sees
// the session end, so there is no greeter, no password prompt and no autologin
// to rewrite, and the same code works with any of them or with none.
package console

import (
	"os"
	"path/filepath"
	"strings"
)

// GamescopeDesktopName is what a session entry declares to say it is the
// gamescope session. Package names differ across distributions --
// gamescope-session-cachyos here, gamescope-session-git elsewhere -- so this is
// what identifies it, never a package name or a file path.
const GamescopeDesktopName = "gamescope"

// HostingMarker is the key `console setup` writes into the session entry it
// generates, so a hosting session can be recognised however it is launched.
const HostingMarker = "X-OpenCouch-Hosting"

// foreignHostingMarker is the marker written by hyprmoncfg, which hosts
// sessions the same way this does and which this shares a machine with.
//
// Recognising somebody else's hosting entry matters as much as recognising our
// own, and for the same reason: an entry that hosts a session is not a desktop
// to come back to. Reading it as one makes the wrapper host a wrapper, and the
// user never reaches a desktop at all.
const foreignHostingMarker = "X-Hyprmoncfg-Hosting"

// Entry is one session entry offered to the login manager.
type Entry struct {
	Path string
	Name string
	// Exec is the command line, already stripped of the field codes a session
	// entry may carry.
	Exec []string
	// DesktopNames is the DesktopNames= list, exactly as written.
	//
	// Case is preserved because this ends up in XDG_CURRENT_DESKTOP, which
	// portals and polkit agents match case-sensitively -- "KDE" finds the KDE
	// portal and "kde" finds nothing. The comparisons below fold case
	// themselves rather than making every reader accept a mangled value.
	DesktopNames []string
	// Hosting is set by the marker `console setup` writes. Reading the Exec
	// line is not enough on its own: a hosting entry may point at a wrapper
	// script rather than at us directly, and then it looks like an ordinary
	// session and offers itself as somewhere to come back to.
	Hosting bool
}

// File is the entry's basename, which is how a login manager names a session.
func (e Entry) File() string { return filepath.Base(e.Path) }

// SessionRoots are the system directories session entries are packaged into.
//
// It is a variable so a test can point discovery at a fixture. These paths are
// absolute, so a test asserting that some session is absent would otherwise
// pass or fail depending on what happens to be installed on the machine running
// it -- which is not a property of the code under test.
var SessionRoots = []string{"/usr/local/share/wayland-sessions", "/usr/share/wayland-sessions"}

// SessionDirs lists where session entries live, in the order a login manager
// reads them: a local override before the packaged one.
func SessionDirs() []string {
	dirs := []string{}
	if home, err := os.UserHomeDir(); err == nil {
		dirs = append(dirs, filepath.Join(home, ".local", "share", "wayland-sessions"))
	}
	return append(dirs, SessionRoots...)
}

// FindEntries reads every session entry in the given directories.
//
// An entry that appears in more than one directory is kept once, from the
// earliest directory, which is the one that wins for the login manager too.
func FindEntries(dirs []string) []Entry {
	seen := map[string]bool{}
	entries := []Entry{}
	for _, dir := range dirs {
		paths, err := filepath.Glob(filepath.Join(dir, "*.desktop"))
		if err != nil {
			continue
		}
		for _, path := range paths {
			base := filepath.Base(path)
			if seen[base] {
				continue
			}
			entry, err := ReadEntry(path)
			if err != nil {
				continue
			}
			seen[base] = true
			entries = append(entries, entry)
		}
	}
	return entries
}

// ReadEntry parses a session entry.
//
// Only the [Desktop Entry] group is read: a session file may carry action
// groups whose own Exec= would otherwise be mistaken for the session's.
func ReadEntry(path string) (Entry, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Entry{}, err
	}
	entry := Entry{Path: path}
	inMain := false
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "[") {
			inMain = line == "[Desktop Entry]"
			continue
		}
		if !inMain || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		switch strings.TrimSpace(key) {
		case "Name":
			entry.Name = strings.TrimSpace(value)
		case "Exec":
			entry.Exec = ParseExec(value)
		case HostingMarker, foreignHostingMarker:
			entry.Hosting = strings.EqualFold(strings.TrimSpace(value), "true")
		case "DesktopNames":
			for _, name := range strings.Split(value, ";") {
				if name = strings.TrimSpace(name); name != "" {
					entry.DesktopNames = append(entry.DesktopNames, name)
				}
			}
		}
	}
	return entry, nil
}

// ParseExec splits a session entry's Exec line into a command.
//
// Field codes (%f, %U and friends) are dropped: they are placeholders for files
// a launcher would substitute, and a session entry is never launched with any.
// A doubled %% is a literal percent sign.
func ParseExec(line string) []string {
	fields := []string{}
	var current strings.Builder
	quote := byte(0)
	started := false

	flush := func() {
		if started {
			fields = append(fields, current.String())
			current.Reset()
			started = false
		}
	}

	for i := 0; i < len(line); i++ {
		c := line[i]
		switch {
		case quote != 0 && c == quote:
			quote = 0
		case quote != 0:
			current.WriteByte(c)
			started = true
		case c == '"' || c == '\'':
			quote = c
			started = true
		case c == ' ' || c == '\t':
			flush()
		case c == '%' && i+1 < len(line):
			i++
			if line[i] == '%' {
				current.WriteByte('%')
				started = true
			}
			// Any other field code expands to nothing.
		default:
			current.WriteByte(c)
			started = true
		}
	}
	flush()
	return fields
}

// FindGamescopeSession returns the session entry that declares itself the
// gamescope session.
func FindGamescopeSession(entries []Entry) (Entry, bool) {
	for _, entry := range entries {
		for _, name := range entry.DesktopNames {
			if strings.EqualFold(name, GamescopeDesktopName) {
				return entry, true
			}
		}
	}
	return Entry{}, false
}

// IsGamescopeSession reports whether an entry is the console itself, which is
// never somewhere to come back to.
func IsGamescopeSession(e Entry) bool {
	for _, name := range e.DesktopNames {
		if strings.EqualFold(name, GamescopeDesktopName) {
			return true
		}
	}
	return false
}

// FindEntryByFile returns the entry with the given file name, which is how a
// login manager's configuration refers to a session.
func FindEntryByFile(entries []Entry, file string) (Entry, bool) {
	for _, entry := range entries {
		if entry.File() == file {
			return entry, true
		}
	}
	return Entry{}, false
}
