// Package apps closes what the user asked to have closed before the machine is
// handed over.
//
// It matters more here than it did when the console ran alongside the desktop:
// entering console mode ends the desktop session, and everything still open in
// it goes too. Closing the named applications first is the difference between
// an editor saving its buffers and one being killed with the session.
package apps

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// Protected names are never closed, whatever the user has listed.
//
// The list covers every desktop this can host, not just the one running: the
// list is written once and carried between machines, and a name that is
// harmless on KDE ends the session on Hyprland. Closing the compositor here
// would take the desktop down without the wrapper being asked to switch, so the
// user would land in a dead session rather than in the console.
var Protected = []string{
	// This application and its engine.
	"open-couch", "opencouch", "open-couch-engine",
	// Steam, which is the point of the exercise.
	"steam", "steamwebhelper", "gamescope", "gamescope-wl",
	// KDE Plasma.
	"plasmashell", "kwin_wayland", "kwin_x11", "kwin_wayland_wrapper", "ksmserver", "systemsettings",
	// Hyprland.
	"Hyprland", "hyprland", "uwsm", "hyprpaper", "hyprlock", "hypridle",
	// GNOME.
	"gnome-shell", "gnome-session-binary", "mutter",
	// Shared session plumbing.
	"Xwayland", "xdg-desktop-portal", "pipewire", "wireplumber", "systemd",
}

// IsProtected reports whether a process name is one this refuses to close.
func IsProtected(name string) bool {
	lowered := strings.ToLower(strings.TrimSpace(name))
	for _, p := range Protected {
		if strings.ToLower(p) == lowered {
			return true
		}
	}
	return false
}

// procRoot is a variable so tests can point it at a fixture.
var procRoot = "/proc"

// signal is a variable for the same reason: a test must not actually kill
// anything.
var signal = func(pid int, sig syscall.Signal) error { return syscall.Kill(pid, sig) }

// Result says what happened to one name the user listed.
type Result struct {
	Name string
	// Closed counts the processes that were asked to quit.
	Closed int
	// Skipped is set when the name is protected.
	Skipped bool
}

// Close asks every process matching each name to quit.
//
// SIGTERM rather than SIGKILL, and no wait for it to take effect: the point is
// to give an application the chance to save, which is exactly what the signal it
// can catch is for. A process that ignores it is one the user will find still
// running, which is better than one whose unsaved work was destroyed on the way
// to a game.
//
// Names are matched exactly against the process name, the way `pkill -x` does.
// A substring match would close a browser because the user asked to close a
// music player whose name it happens to contain.
func Close(names []string) []Result {
	results := make([]Result, 0, len(names))
	var processes map[string][]int

	for _, name := range names {
		name = strings.TrimSpace(name)
		if name == "" {
			continue
		}
		if IsProtected(name) {
			results = append(results, Result{Name: name, Skipped: true})
			continue
		}
		if processes == nil {
			// Read once, not once per name: the list is short but /proc is not,
			// and re-walking it per name would also let a process started in
			// between be closed by a later name and not an earlier one.
			processes = runningProcesses()
		}
		result := Result{Name: name}
		for _, pid := range processes[strings.ToLower(name)] {
			if err := signal(pid, syscall.SIGTERM); err == nil {
				result.Closed++
			}
		}
		results = append(results, result)
	}
	return results
}

// runningProcesses maps a lowercased process name to the pids running under it.
func runningProcesses() map[string][]int {
	entries, err := os.ReadDir(procRoot)
	if err != nil {
		return nil
	}
	processes := map[string][]int{}
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || pid <= 0 {
			continue
		}
		comm, err := os.ReadFile(filepath.Join(procRoot, entry.Name(), "comm"))
		if err != nil {
			// The process ended between the listing and the read, which is
			// ordinary rather than an error.
			continue
		}
		name := strings.ToLower(strings.TrimSpace(string(comm)))
		if name == "" {
			continue
		}
		processes[name] = append(processes[name], pid)
	}
	return processes
}
