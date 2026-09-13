package console

import (
	"context"
	"os/exec"
	"path/filepath"
	"time"
)

// Requirement is one thing a console session needs, and whether this machine
// has it.
//
// It carries both sentences rather than just the failure, because the doctor
// prints the good news too: a list that only ever says what is broken cannot
// tell "everything is fine" from "nothing was checked".
type Requirement struct {
	OK bool
	// Have reads as a statement of fact, for the line the doctor prints when
	// the requirement is met.
	Have string
	// Want names what is missing and what to do about it. It is what a panel
	// shows and what an entry path refuses with, so it has to stand alone.
	Want string
}

// lookPath is a variable so tests can decide what is installed.
var lookPath = exec.LookPath

// checkStateDir is a seam so a test can point the safe-mode check at a scratch
// directory rather than the real ~/.cache/open-couch.
var checkStateDir = StateDir

func installed(name string) bool {
	_, err := lookPath(name)
	return err == nil
}

// Requirements reports everything a console session needs, in the order the
// doctor prints them.
//
// This exists because the same list was written twice -- once in `console
// doctor` and once for the panel -- and the two drifted: the panel's copy never
// checked for gamescope, Steam or the systemd target, so it could call a machine
// ready that the doctor refused. One list means the panel, the doctor and the
// entry paths cannot disagree about what "ready" means.
//
// entries is passed in rather than looked up, because callers on a hot path
// already have it and globbing three session directories twice per status
// broadcast is not free.
func Requirements(ctx context.Context, cfg Config, sc Runner, entries []Entry, configPath string) []Requirement {
	if sc == nil {
		sc = Systemctl{}
	}
	reqs := []Requirement{}
	add := func(ok bool, have, want string) {
		reqs = append(reqs, Requirement{OK: ok, Have: have, Want: want})
	}

	gamescope, hasGamescope := FindGamescopeSession(entries)
	have := "the gamescope session is installed"
	if hasGamescope {
		have += " (" + gamescope.File() + ")"
	}
	add(hasGamescope, have,
		"no gamescope session is installed; install a gamescope-session package")
	add(TargetKnown(ctx, sc),
		"systemd can resolve gamescope-session.target",
		"systemd cannot resolve gamescope-session.target")
	add(installed("gamescope"), "gamescope is installed", "gamescope is not installed")
	add(installed("steam"), "Steam is installed", "Steam is not installed")

	// Existing is not enough: the entry also has to be a desktop. Recording a
	// hosting session as the way home makes the wrapper start a wrapper, and
	// the user never reaches a desktop at all -- which reads as a machine that
	// hangs on login rather than as a setting that is wrong.
	desktop, hasDesktop := FindEntryByFile(entries, cfg.DesktopSession)
	switch {
	case !hasDesktop:
		add(false, "", "no desktop session to come back to; set desktop_session in "+configPath)
	case HostsConsole(desktop):
		add(false, "", "the desktop session to come back to ("+cfg.DesktopSession+
			") hosts sessions itself; pick a real desktop with `open-couch-engine setup --desktop <file>`")
	default:
		add(true, "the desktop session to come back to is "+cfg.DesktopSession, "")
	}

	add(cfg.Configured(),
		"the display to hand over is "+cfg.TVName,
		"no display has been chosen; run `open-couch-engine tv`")

	// A machine with no XDG_RUNTIME_DIR has nowhere to leave the request, which
	// the caller will have failed on already; saying nothing beats inventing a
	// second complaint about it here.
	if runtimeDir, err := RuntimeDir(); err == nil {
		add(Hosted(runtimeDir),
			"this session is hosted, so switching will work",
			"this session is not hosted; run `open-couch-engine setup` and log in again")
	}

	// Safe mode and `disable` both stop the console from starting, and for the
	// same visible reason: `enter` would end the desktop for a switch that is
	// not going to happen. Read from the same SafeModeReason call the wrapper
	// holds the desktop from, so the panel, the doctor and the gate cannot
	// disagree with it. configPath is <base>/console.json.
	base := filepath.Dir(configPath)
	switch {
	case IsDisabled(base):
		add(false, "", "Open Couch is switched off; run `open-couch-engine enable` to offer the console again")
	default:
		if stateDir, err := checkStateDir(); err == nil {
			if reason, held := SafeModeReason(stateDir, time.Now()); held {
				add(false, "", "Open Couch is in safe mode after "+reason+
					"; fix the setup and log in once, or run `open-couch-engine enable`")
			}
		}
	}
	return reqs
}

// Unmet returns the Want line of every requirement this machine does not meet,
// which is the form a panel lists and an entry path refuses with.
func Unmet(reqs []Requirement) []string {
	unmet := []string{}
	for _, r := range reqs {
		if !r.OK {
			unmet = append(unmet, r.Want)
		}
	}
	return unmet
}
