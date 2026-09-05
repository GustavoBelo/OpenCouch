package console

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// Launcher starts a compositor and returns when it has exited. It is a field so
// the hosting loop can be exercised without starting anything.
type Launcher func(ctx context.Context, argv []string, extraEnv []string) error

// Wrapper hosts both compositors in one login session.
type Wrapper struct {
	// DesktopExec is the user's own compositor command, taken from the session
	// entry they normally log into and validated before the loop starts. It is
	// the way back that always exists, so it stands whenever a later re-read
	// cannot produce one.
	DesktopExec []string
	// DesktopSession is the file DesktopExec came from, so a re-read can tell
	// whether the user has since chosen a different one.
	DesktopSession string
	// DesktopNames is what the entry DesktopExec came from declares, if it
	// declares anything. Config.DesktopNames covers the ones that do not.
	DesktopNames []string
	// ConsoleExec is the gamescope session's own entry point. Reusing it rather
	// than reimplementing matters: that script does environment plumbing --
	// dbus-update-activation-environment, XDG_DESKTOP_PORTAL_DIR, reset-failed --
	// that has to happen and is not ours to duplicate.
	ConsoleExec []string
	// ConsoleSessionName is what DESKTOP_SESSION should say inside the console,
	// normally the session entry's file name without its suffix.
	ConsoleSessionName string

	// Boot says where a fresh login starts. A pending request always wins over
	// it, so `console enter` is not fighting a preference. It is read once, at
	// the top of Run, because "where a login starts" has already happened by the
	// time anyone could edit it -- unlike everything in Choices.
	Boot BootMode

	StateDir   string
	RuntimeDir string

	// Choices is the configuration as it was at login, and what stands if a
	// re-read fails.
	Choices Config
	// Reload re-reads the configuration. It is a function rather than a value
	// because the wrapper is started once, by the login manager, and then
	// outlives every edit made from the desktop it hosts -- a login session
	// lasts days. Reading once meant the display chosen an hour ago was not the
	// one gamescope drove: the TUI said DP-1, the file said DP-1, and the
	// television lit up.
	Reload func() (Config, error)

	Systemctl Runner
	Launch    Launcher
	Logf      func(string, ...any)

	// ShortRun is how long a compositor has to last to count as a real session,
	// and ShortRunLimit how many consecutive short ones end the loop.
	ShortRun      time.Duration
	ShortRunLimit int
}

const (
	defaultShortRun      = 15 * time.Second
	defaultShortRunLimit = 2
	// connectorWait is how long to give a display to present itself. Booting
	// straight into the console reaches this six seconds after the driver
	// loaded, which is well before a television has finished waking up.
	connectorWait = 20 * time.Second
)

func (w *Wrapper) logf(format string, args ...any) {
	if w.Logf != nil {
		w.Logf(format, args...)
	}
}

// Run hosts compositors until nobody asks for another one.
//
// The loop is the whole design. Because the login manager started this and not a
// compositor, it never sees a session end when the user switches, so there is no
// greeter, no password prompt and nothing to reconfigure. An ordinary logout
// still works: the compositor exits with no request pending, the loop ends, and
// the session closes exactly as it always did.
func (w *Wrapper) Run(ctx context.Context) error {
	if len(w.DesktopExec) == 0 {
		return errors.New("no desktop compositor command: there would be no way back")
	}
	// The login manager starts this before any compositor exists. Finding one
	// already running means somebody typed the command inside their own desktop,
	// and the first thing the loop does is Sanitize, which stops
	// graphical-session.target and takes that desktop's services down with it.
	// The command's help says it will not work; refusing is what makes that true.
	if SessionRunning(w.RuntimeDir) {
		return errors.New("a compositor is already running: `host-session` is what the login manager starts, not something to run inside a session it would tear down.\nTo switch now, use `open-couch-engine enter`")
	}
	if w.Systemctl == nil {
		w.Systemctl = Systemctl{}
	}
	if w.Launch == nil {
		w.Launch = RealLauncher
	}
	if w.ShortRun == 0 {
		w.ShortRun = defaultShortRun
	}
	if w.ShortRunLimit == 0 {
		w.ShortRunLimit = defaultShortRunLimit
	}

	// Mark the session so the doctor can tell a hosted session from a plain
	// one: the compositor underneath looks identical either way.
	if w.RuntimeDir != "" {
		if err := markHosted(w.RuntimeDir); err != nil {
			w.logf("console: could not mark this session as hosted: %v", err)
		}
		defer unmarkHosted(w.RuntimeDir)
	}

	requested, hasRequest := TakeRequest(w.RuntimeDir)
	last, hasLast := ReadLastMode(w.StateDir)
	mode := BootModeFor(w.Boot, requested, hasRequest, last, hasLast)
	w.logf("console: starting in %s mode (boot=%s, last=%s)", mode, orDefault(string(w.Boot), string(BootDesktop)), orDefault(string(last), "none"))

	// The record of which session is running is cleared when the loop ends, so
	// a runtime directory that outlives the login does not claim one is still
	// there.
	defer ClearLive(w.RuntimeDir)

	shortRuns := 0
	generation := 0
	for {
		Sanitize(ctx, w.Systemctl)
		// The previous session's units may still be stopping -- a display
		// manager restart hands the new session over long before the old one
		// has unwound -- and uwsm refuses to start on top of that.
		SettleJobs(ctx, w.Systemctl, 20*time.Second)

		argv, env, err := w.commandFor(ctx, mode)
		if err != nil {
			w.logf("console: cannot start the %s session: %v", mode, err)
			if mode == ModeDesktop {
				return err
			}
			// The console could not be prepared, so fall back to the desktop
			// rather than ending the session and leaving a black screen. The
			// desktop the user gets back is empty, and nothing here can tell
			// them why: the notification server went with the compositor. Leave
			// word for the daemon, which starts with the desktop that is about
			// to come up, and let it do the telling.
			RecordFailure(w.StateDir, err.Error())
			mode = ModeDesktop
			continue
		}

		// Recorded before launching, not after: a machine switched off while
		// playing has to come back playing, and there is no "after" then.
		WriteLastMode(w.StateDir, mode)
		// Recorded before launching for the same reason as the mode above: the
		// process that asked for this switch is watching for the generation to
		// move, and it is watching now, not once the compositor has finished
		// coming up.
		generation++
		if err := WriteLive(w.RuntimeDir, Live{Mode: mode, Generation: generation}); err != nil {
			w.logf("console: could not record the running session: %v", err)
		}
		w.logf("console: starting the %s session: %s", mode, strings.Join(argv, " "))
		started := time.Now()
		runErr := w.Launch(ctx, argv, env)
		lasted := time.Since(started)
		w.logf("console: the %s session ended after %s (%v)", mode, lasted.Round(time.Second), runErr)

		// A compositor that dies instantly would otherwise be restarted forever,
		// and the user would have no way in at all. Hand back to the login
		// manager instead, which at least shows them something.
		if lasted < w.ShortRun {
			shortRuns++
			if shortRuns >= w.ShortRunLimit {
				w.logf("console: %d sessions ended immediately; handing back to the login manager", shortRuns)
				break
			}
		} else {
			shortRuns = 0
		}

		next, ok := TakeRequest(w.RuntimeDir)
		if !ok {
			// Nobody logs out *from* the console: leaving it means going home.
			// Big Picture's own "Switch to Desktop" just stops the session's
			// target and leaves no request behind, so treating a request-less
			// console exit as a logout would drop the user at a greeter.
			if mode == ModeConsole {
				w.logf("console: the console session ended; returning to the desktop")
				mode = ModeDesktop
				continue
			}
			w.logf("console: no switch was requested; ending the login session")
			break
		}
		mode = next
	}

	// Whatever happened, the desktop's audio goes back and the manager is left
	// clean for whoever logs in next.
	RestoreAudio(ctx, w.StateDir, w.logf)
	Sanitize(ctx, w.Systemctl)
	return nil
}

// choices is the configuration as it is now, not as it was at login.
//
// A re-read that fails is not a reason to refuse a session: the values from
// login are stale at worst, and a console on the wrong display beats no console
// at all. Reload is nil in tests, which is what keeps them off the real file.
func (w *Wrapper) choices() Config {
	if w.Reload == nil {
		return w.Choices
	}
	cfg, err := w.Reload()
	if err != nil {
		w.logf("console: could not re-read the configuration, using the one from login: %v", err)
		return w.Choices
	}
	return cfg
}

// desktopCommand is the session to come back to, as chosen now.
//
// The entry validated before the loop started is the floor. A way back that
// might not exist is worse than one that is out of date, so anything the re-read
// cannot resolve -- a session that has been uninstalled, an entry that would
// host itself -- falls back to it rather than failing.
func (w *Wrapper) desktopCommand(cfg Config) ([]string, []string) {
	if cfg.DesktopSession == "" || cfg.DesktopSession == w.DesktopSession {
		return w.DesktopExec, desktopEnv(w.DesktopSession, w.DesktopNames, cfg.DesktopNames)
	}
	entry, ok := FindEntryByFile(FindEntries(SessionDirs()), cfg.DesktopSession)
	if !ok || len(entry.Exec) == 0 || HostsConsole(entry) {
		w.logf("console: cannot come back to %s, using %s", cfg.DesktopSession, w.DesktopSession)
		return w.DesktopExec, desktopEnv(w.DesktopSession, w.DesktopNames, cfg.DesktopNames)
	}
	return entry.Exec, desktopEnv(entry.File(), entry.DesktopNames, cfg.DesktopNames)
}

// desktopEnv is what the desktop's own session entry would have set had the
// login manager started it directly.
//
// Without this the desktop comes up with an empty XDG_CURRENT_DESKTOP, and
// portals and polkit agents key off that -- so the session gets the wrong ones,
// for its whole life, with nothing to say why. It used to come from the
// DesktopNames line of the per-user hosting entry; that entry cannot carry it
// once it is installed once for every account.
func desktopEnv(session string, names []string, recorded string) []string {
	// The entry's own declaration first, then what setup saw the running
	// session claim. Many entries declare nothing -- Omarchy's does not -- and
	// under uwsm the identity comes from the Exec line instead, so the recorded
	// value is what covers them.
	joined := strings.Join(names, ":")
	if joined == "" {
		joined = strings.TrimSpace(recorded)
	}
	env := []string{}
	if joined != "" {
		env = append(env,
			"XDG_CURRENT_DESKTOP="+joined,
			"XDG_SESSION_DESKTOP="+joined)
	}
	if session != "" {
		env = append(env, "DESKTOP_SESSION="+strings.TrimSuffix(session, ".desktop"))
	}
	return env
}

// commandFor prepares the machine for a mode and returns what to run.
func (w *Wrapper) commandFor(ctx context.Context, mode Mode) ([]string, []string, error) {
	cfg := w.choices()
	if mode != ModeConsole {
		RestoreAudio(ctx, w.StateDir, w.logf)
		argv, env := w.desktopCommand(cfg)
		return argv, env, nil
	}
	if len(w.ConsoleExec) == 0 {
		return nil, nil, errors.New("no gamescope session is installed")
	}
	if cfg.TVDescription != "" {
		if err := PrepareAudio(ctx, w.StateDir, cfg.TVDescription, w.logf); err != nil {
			// Sound on the wrong speakers is a poor console, but it is not a
			// reason to refuse to start one.
			w.logf("console: audio stays where it is: %v", err)
		}
	}
	// gamescope picks its output from OUTPUT_CONNECTOR. Setting it on the user
	// manager rather than writing a drop-in keeps it transient -- no file, no
	// daemon-reload -- and Sanitize clears it again on the way out.
	//
	// Said out loud because this is the one thing about a console session that
	// nothing else reports: the display it came up on is the whole point, and
	// when it was wrong there was no line anywhere that said so.
	if cfg.TVName == "" {
		w.logf("console: no display has been chosen, so gamescope will pick one")
	} else {
		// gamescope enumerates connectors once and never looks again, so handing
		// it the machine before the displays have presented themselves leaves it
		// running with nothing selected and no way to recover.
		AwaitConnector(ctx, cfg.TVName, connectorWait, w.logf)
		w.logf("console: pointing gamescope at %s", cfg.TVName)
		if err := w.Systemctl.Run(ctx, "set-environment", "OUTPUT_CONNECTOR="+cfg.TVName); err != nil {
			w.logf("console: could not point gamescope at %s: %v", cfg.TVName, err)
		}
	}

	name := w.ConsoleSessionName
	if name == "" {
		name = GamescopeDesktopName
	}
	env := []string{
		"XDG_CURRENT_DESKTOP=" + GamescopeDesktopName,
		"XDG_SESSION_DESKTOP=" + GamescopeDesktopName,
		"DESKTOP_SESSION=" + name,
	}
	return w.ConsoleExec, env, nil
}

func orDefault(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

// RealLauncher runs a compositor and waits for it.
func RealLauncher(ctx context.Context, argv []string, extraEnv []string) error {
	if len(argv) == 0 {
		return errors.New("nothing to run")
	}
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Env = append(os.Environ(), extraEnv...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s: %w", argv[0], err)
	}
	return nil
}
