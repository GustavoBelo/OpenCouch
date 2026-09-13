// Command open-couch-engine hands the machine between the desktop and Steam's
// gamescope session, and back.
//
// The graphical app drives this over QProcess, and a session entry runs
// `host-session` for the whole login. Both contracts are narrow on purpose:
// `check` and `version` are what the app probes with, and every other command
// either prints JSON for the app or a paragraph for a person.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/GustavoBelo/OpenCouch/engine/internal/console"
	"github.com/GustavoBelo/OpenCouch/engine/internal/notify"
)

// version is set at build time with -ldflags "-X main.version=X.Y.Z". The
// graphical app compares it against its own minimum, so an engine that cannot
// say what it is has to read as too old rather than as fine.
var version = "0.0.0"

// CheckIdentity is what `check` prints so a caller can tell this engine from
// anything else answering to the same name. The number is the command
// interface, bumped only when the app has to be able to refuse an older one.
//
// It has to stay byte-for-byte identical to kCheckIdentity in
// app/src/engineclient.cpp. They are compared for equality, so a change to one
// alone makes the app report every engine as missing.
const CheckIdentity = "open-couch-engine console-mode/1"

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		usage()
		return errors.New("no command given")
	}

	// A switch kills the process that asked for it, but everything up to that
	// point should still stop cleanly when the user presses Ctrl-C.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	command, rest := args[0], args[1:]
	switch command {
	case "version", "--version", "-v":
		fmt.Println(version)
		return nil
	case "check":
		// The app calls this to find out whether an engine is installed at all.
		// It answers for the binary, not for the machine: `doctor` is what says
		// whether a console session could actually start.
		//
		// It prints an identity rather than just exiting 0, because exiting 0
		// proves nothing: the bash engine this replaced also has a `check` that
		// succeeds, reports the same version number, and then answers `status`
		// with log lines instead of JSON. An app that trusted the exit code
		// would talk to it, get an empty status, and show "not ready" forever
		// with nothing to say why.
		fmt.Println(CheckIdentity)
		return nil
	case "config-path":
		base, err := baseDir()
		if err != nil {
			return err
		}
		fmt.Println(console.ConfigPath(base))
		return nil
	case "host-session":
		return hostSession(ctx)
	case "enter":
		return enter(ctx, rest)
	case "leave":
		return leave(ctx)
	case "cancel":
		return cancel()
	case "status":
		return status(ctx)
	case "doctor":
		return doctor(ctx)
	case "setup":
		return setup(ctx, rest)
	case "outputs":
		return outputs()
	case "tv":
		return setTV(rest)
	case "boot":
		return setBoot(rest)
	case "controller":
		return setController(rest)
	case "disable":
		return setEnabled(false)
	case "enable":
		return setEnabled(true)
	case "log":
		return showLog(rest)
	case "help", "-h", "--help":
		usage()
		return nil
	}
	usage()
	return fmt.Errorf("unknown command %q", command)
}

func usage() {
	fmt.Fprint(os.Stderr, `open-couch-engine — hand the machine to Steam's gamescope session, and back

  host-session   run the wrapper (this is what a session entry points at)
  enter [--yes]  switch to the console; without --yes it announces and waits
  leave          switch back to the desktop
  cancel         call off a countdown that is already running
  status         what is configured and what is running, as JSON
  doctor         what a console session still needs, as a list
  setup [--desktop FILE]
                 write the hosting session entry and say how to install it
  outputs        every connector on the machine, as JSON
  tv <CONNECTOR> choose the display the console takes over
  boot <MODE>    where a fresh login starts: desktop, console or last
  controller <on|off>
                 offer the console when a gamepad is switched on
  disable        stop hosting the console; the next login goes straight to the desktop
  enable         host the console again after disable, or after safe mode
  log [--clear | --list | --session <ID>]
                 the wrapper's log for this login, or the logins kept before it
  config-path    where the settings file lives
  check          succeed if this engine can run
  version        print the engine version
`)
}

// baseDir is where the settings live. It follows the XDG variable so a test or
// a sandbox can move it, and falls back to the spec's default rather than to
// the working directory.
func baseDir() (string, error) {
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, "open-couch"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".config", "open-couch"), nil
}

func ensureBaseDir() (string, error) {
	dir, err := baseDir()
	if err != nil {
		return "", err
	}
	return dir, os.MkdirAll(dir, 0o755)
}

// load gathers what nearly every command needs, so no command has to remember
// the order these depend on each other in.
type env struct {
	Base       string
	Config     console.Config
	RuntimeDir string
	StateDir   string
	Entries    []console.Entry
}

func load() (env, error) {
	base, err := ensureBaseDir()
	if err != nil {
		return env{}, err
	}
	cfg, err := console.LoadConfig(base)
	if err != nil {
		return env{}, err
	}
	runtimeDir, err := console.RuntimeDir()
	if err != nil {
		return env{}, err
	}
	stateDir, err := console.StateDir()
	if err != nil {
		return env{}, err
	}
	return env{
		Base:       base,
		Config:     cfg,
		RuntimeDir: runtimeDir,
		StateDir:   stateDir,
		Entries:    console.FindEntries(console.SessionDirs()),
	}, nil
}

// loadForHosting is load() for the one caller that must not fail.
//
// Every step load() gives up on is downgraded here to a note in the log and the
// emptiest value the wrapper can still work from: a blank configuration hosts
// the first desktop it finds, and an empty state or runtime directory is
// already "nothing to record" everywhere the wrapper touches one.
//
// A configuration file that will not parse is the case this is really for. It
// is the exact shape of failure safe mode exists to break -- every login ends in
// milliseconds and the greeter offers the same session straight back -- except
// that it happens before the wrapper runs, so nothing counts it and nothing
// holds the console back. Hosting the desktop with the defaults puts the user
// somewhere they can fix the file from.
//
// The notes come back rather than going to the log here because the log lives
// in the state directory, which is one of the things being resolved.
func loadForHosting() (env, []string) {
	var notes []string
	note := func(format string, args ...any) { notes = append(notes, fmt.Sprintf(format, args...)) }

	// The state directory first: the log goes there, so resolving it before
	// anything else is what lets the rest of these notes be read afterwards.
	stateDir, err := console.StateDir()
	if err != nil {
		note("console: there is no state directory (%v), so this login is not recorded and safe mode cannot count it", err)
	}
	runtimeDir, err := console.RuntimeDir()
	if err != nil {
		note("console: there is no runtime directory (%v), so switching sessions will not work in this login", err)
	}
	// A failure here still leaves a path worth trying: ensureBaseDir only makes
	// the directory, and a config that is sitting in one it could not create is
	// a config that reads fine.
	base, err := ensureBaseDir()
	if err != nil {
		note("console: the configuration directory could not be prepared (%v); hosting with whatever can still be read", err)
	}
	var cfg console.Config
	if base != "" {
		if cfg, err = console.LoadConfig(base); err != nil {
			note("console: %s could not be read (%v); hosting with the defaults", console.ConfigPath(base), err)
			// The user hears this one. The machine looks fine from the outside
			// -- it logs in, it just ignores everything they chose -- and the
			// desktop about to come up is the only place the news can reach
			// them.
			console.RecordFailure(stateDir, "Open Couch could not read its settings ("+console.ConfigPath(base)+
				"), so it started your desktop with the defaults. Fix or delete that file and log in again.")
			cfg = console.Config{}
		}
	}
	// A blank configuration carries no boot mode, and everything downstream
	// reads one. LoadConfig normalizes what it returns; what is built here has
	// to be normalized too.
	cfg.Normalize()

	return env{
		Base:       base,
		Config:     cfg,
		RuntimeDir: runtimeDir,
		StateDir:   stateDir,
		Entries:    console.FindEntries(console.SessionDirs()),
	}, notes
}

// hostSession runs the wrapper for the whole login.
//
// The login manager started this process, so returning from it ends the login,
// and the greeter answers a login that lasted a second by offering the same
// session again. Nothing in here may end one quickly, however broken the
// machine is: loadForHosting refuses to fail, and whatever error still comes
// back from the wrapper is held to the floor before the greeter is allowed to
// see it. Without that floor the fastest failures were the ones safe mode could
// not see -- it only counts logins the wrapper itself reached.
func hostSession(ctx context.Context) error {
	begun := time.Now()
	err := hostLogin(ctx)
	// Everything except the one refusal that is not a login at all. Somebody
	// typed this inside their own desktop: no login manager is waiting to offer
	// the session again, and they are at a terminal waiting to read the answer.
	if err != nil && !errors.Is(err, console.ErrNotALogin) {
		console.HoldFailedLogin(ctx, begun)
	}
	return err
}

func hostLogin(ctx context.Context) error {
	e, notes := loadForHosting()
	// A session's stderr goes wherever the login manager decided, which on SDDM
	// is nowhere a person can reach. Without a file there is no way to find out
	// why a session that lasted five seconds gave up.
	// A login begins here, so this is where the previous one's log stops being
	// the current one. Filed rather than overwritten: the account of a session
	// that ended badly is worth more than the one that is starting fine.
	if err := console.RotateLog(e.StateDir); err != nil {
		fmt.Fprintln(os.Stderr, "could not file the previous log away:", err)
	}
	logf := logger(e.StateDir)
	// What loadForHosting had to work around, now that there is somewhere to
	// say it. After the rotation above, so the notes belong to this login.
	for _, note := range notes {
		logf("%s", note)
	}

	// Nothing below refuses to start. This process is what the login manager
	// ran, so returning an error here ends the session as fast as it began, and
	// the greeter answers by offering the same hosting entry again -- a password
	// loop with no way out on a greeter that shows no session picker. Whatever
	// is wrong with the configuration can be fixed from inside a desktop; it
	// cannot be fixed from a login screen.
	desktop, ok := console.FindEntryByFile(e.Entries, e.Config.DesktopSession)
	if ok && console.HostsConsole(desktop) {
		logf("console: %s is a hosting session and would host itself forever; looking for another desktop", desktop.File())
		ok = false
	}
	if !ok {
		fallback, found := console.FallbackDesktop(e.Entries)
		if found {
			logf("console: the configured desktop %q is not installed; hosting %s instead. Run `open-couch-engine setup` to choose again",
				e.Config.DesktopSession, fallback.File())
			desktop = fallback
		} else {
			// No desktop at all. Handled by the wrapper rather than returned
			// here: it logs how to recover, waits so the login manager's retry
			// is not a spin, and ends the session once instead of dropping
			// straight back into a password loop.
			logf("console: no desktop session is installed; the wrapper will explain and hand back")
			desktop = console.Entry{}
		}
	}

	w := &console.Wrapper{
		DesktopExec:    desktop.Exec,
		DesktopSession: desktop.File(),
		DesktopNames:   desktop.DesktopNames,
		StateDir:       e.StateDir,
		RuntimeDir:     e.RuntimeDir,
		Choices:        e.Config,
		Boot:           e.Config.Boot,
		// Where `open-couch-engine disable` leaves its marker. The wrapper reads
		// it for itself, every time the answer matters, so `enable` from the
		// desktop it is holding takes effect in that same login.
		BaseDir: e.Base,
		Logf:    logf,
	}
	if e.Base != "" {
		// Started once, by the login manager, then hosting every session until
		// the user logs out. What it was told above was true at login; what it
		// acts on has to be what the file says now.
		w.Reload = func() (console.Config, error) { return console.LoadConfig(e.Base) }
	}
	if gamescope, ok := console.FindGamescopeSession(e.Entries); ok {
		w.ConsoleExec = gamescope.Exec
		w.ConsoleSessionName = strings.TrimSuffix(gamescope.File(), ".desktop")
	}
	return w.Run(ctx)
}

func enter(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("enter", flag.ContinueOnError)
	yes := fs.Bool("yes", false, "skip the countdown and switch now")
	if err := fs.Parse(args); err != nil {
		return err
	}

	e, err := load()
	if err != nil {
		return err
	}
	if unmet := console.Unmet(console.Requirements(ctx, e.Config, nil, e.Entries, console.ConfigPath(e.Base))); len(unmet) > 0 {
		return fmt.Errorf("console mode is not ready:\n  - %s", strings.Join(unmet, "\n  - "))
	}

	if !*yes {
		// The graphical app draws its own countdown and then calls this with
		// --yes, because it survives the switch and can offer a real button.
		// This path is for the launcher entry and the command line, which have
		// nowhere to draw: the notification is the only warning the user gets.
		notifier := notify.Dial()
		if notifier != nil {
			defer notifier.Close()
		}
		if err := console.Countdown(ctx, console.CountdownOpts{
			Grace:      console.DefaultGrace,
			Display:    displayName(e.Config),
			RuntimeDir: e.RuntimeDir,
			Notifier:   notifier,
			Logf:       func(string, ...any) {},
		}); err != nil {
			return err
		}
	}

	// The wrapper's log is the only place these two lines can be read back: by
	// the time anything goes wrong the compositor is gone and so is the
	// terminal this was typed into.
	logf := logger(e.StateDir)

	// Ask Steam to quit while X and Wayland are still up: a SIGTERM'd Steam
	// hangs then crashes on the way out, graphical-session.target waits for it,
	// and the crash makes the next Steam run a client update. Nothing below
	// depends on this working.
	console.QuitSteam(ctx, logf)

	if err := console.Request(e.RuntimeDir, console.ModeConsole); err != nil {
		return err
	}
	logf("enter: asked for the console, request left in %s", console.RequestPath(e.RuntimeDir))

	err = console.StopCompositor(ctx, e.RuntimeDir, console.DetectCompositor())
	switch {
	case err == nil:
		logf("enter: the compositor stopped and the wrapper took over")
		return nil
	case errors.Is(err, console.ErrSwitchPending):
		logf("enter: the compositor accepted the stop; the wrapper has not started the next session yet")
		return nil
	default:
		// Deliberately not cleared. Stopping the compositor kills this process,
		// so an error here often means the stop worked and took the reporter
		// down with it -- `uwsm stop` ends the very session this is running in.
		// Clearing on that reading is what turned switches into logouts. A
		// request nobody consumes expires on its own (requestMaxAge).
		logf("enter: could not confirm the stop, leaving the request to expire on its own: %v", err)
		return err
	}
}

func leave(ctx context.Context) error {
	e, err := load()
	if err != nil {
		return err
	}
	if err := console.Request(e.RuntimeDir, console.ModeDesktop); err != nil {
		return err
	}
	if err := console.StopConsoleSession(ctx, nil); err != nil {
		console.ClearRequest(e.RuntimeDir)
		return err
	}
	return nil
}

func cancel() error {
	runtimeDir, err := console.RuntimeDir()
	if err != nil {
		return err
	}
	return console.RequestCancel(runtimeDir)
}

func status(ctx context.Context) error {
	e, err := load()
	if err != nil {
		return err
	}
	reqs := console.Requirements(ctx, e.Config, nil, e.Entries, console.ConfigPath(e.Base))

	type requirement struct {
		OK   bool   `json:"ok"`
		Have string `json:"have"`
		Want string `json:"want"`
	}
	out := struct {
		Version string `json:"version"`
		Ready   bool   `json:"ready"`
		Hosted  bool   `json:"hosted"`
		// HostingInstalled says a system session directory already carries the
		// entry for this binary -- a package put it there. It is what tells the
		// application whether setup still has anything to install, and so
		// whether to warn about needing root at all.
		HostingInstalled         bool          `json:"hosting_installed"`
		Mode                     string        `json:"mode"`
		TVName                   string        `json:"tv_name"`
		TVDescription            string        `json:"tv_description"`
		DesktopSession           string        `json:"desktop_session"`
		Boot                     string        `json:"boot"`
		EnterOnControllerConnect bool          `json:"enter_on_controller_connect"`
		Controllers              int           `json:"controllers"`
		ConfigPath               string        `json:"config_path"`
		Requirements             []requirement `json:"requirements"`
		Failure                  string        `json:"failure,omitempty"`
		// SafeMode is why the wrapper is hosting only the desktop after a run of
		// logins that ended early, empty when it is not. It is computed, not
		// stored: the same SafeModeReason call the wrapper decides the hold from.
		SafeMode string `json:"safe_mode,omitempty"`
		// SafeModeLogins is the number that sentence is built from. The panel
		// renders its own line from it, in the user's language, and keeps the
		// English above as the fallback for an engine too old to send this.
		SafeModeLogins int `json:"safe_mode_logins,omitempty"`
		// Disabled is set while `open-couch-engine disable` is in effect.
		Disabled bool `json:"disabled"`
	}{
		Version:                  version,
		Ready:                    len(console.Unmet(reqs)) == 0,
		Hosted:                   console.Hosted(e.RuntimeDir),
		HostingInstalled:         hostingInstalled(e),
		TVName:                   e.Config.TVName,
		TVDescription:            e.Config.TVDescription,
		DesktopSession:           e.Config.DesktopSession,
		Boot:                     string(e.Config.Boot),
		EnterOnControllerConnect: e.Config.EnterOnControllerConnect,
		Controllers:              console.ConnectedControllers(),
		ConfigPath:               console.ConfigPath(e.Base),
		Disabled:                 console.IsDisabled(e.Base),
	}
	if live, ok := console.ReadLive(e.RuntimeDir); ok {
		out.Mode = string(live.Mode)
	}
	// The same call the wrapper and the doctor use: the panel shows safe mode
	// for exactly as long as a switch would really be held. Suppressed when
	// disabled, the way the doctor does it -- `disabled` already carries the
	// reason, and a red "logins ended early" alarm would blame a fault on a
	// user who switched the console off on purpose.
	if !out.Disabled {
		now := time.Now()
		if why, held := console.SafeModeReason(e.StateDir, now); held {
			out.SafeMode = why
			out.SafeModeLogins = console.SafeModeLogins(e.StateDir, now)
		}
	}
	// Taken, not just read. The breadcrumb exists so the user hears once why
	// the console did not start, and this is the path that tells them: the app
	// polls status and shows what comes back. Leaving it would repeat the same
	// failure on every poll for the next ten minutes.
	if why, ok := console.TakeFailure(e.StateDir); ok {
		out.Failure = why
	}
	for _, r := range reqs {
		out.Requirements = append(out.Requirements, requirement{OK: r.OK, Have: r.Have, Want: r.Want})
	}

	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(out)
}

func doctor(ctx context.Context) error {
	e, err := load()
	if err != nil {
		return err
	}
	reqs := console.Requirements(ctx, e.Config, nil, e.Entries, console.ConfigPath(e.Base))
	for _, r := range reqs {
		if r.OK {
			fmt.Printf("  ok    %s\n", r.Have)
			continue
		}
		fmt.Printf("  MISS  %s\n", r.Want)
	}
	if unmet := console.Unmet(reqs); len(unmet) > 0 {
		return fmt.Errorf("%d of %d requirements are not met", len(unmet), len(reqs))
	}
	fmt.Println("\nConsole mode is ready.")
	return nil
}

func setup(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("setup", flag.ContinueOnError)
	chosen := fs.String("desktop", "", "session entry file to come back to, e.g. omarchy.desktop")
	force := fs.Bool("force", false, "write the entry again even if one is already installed")
	if err := fs.Parse(args); err != nil {
		return err
	}

	e, err := load()
	if err != nil {
		return err
	}

	// Asking which session is running is only a guess at which desktop to come
	// back to, and inside a hosted session it is the wrong one: the answer is
	// the hosting entry, which would make the wrapper start a wrapper. So the
	// guess is checked, and --desktop overrides it outright.
	desktop := *chosen
	if desktop == "" {
		desktop = console.CurrentDesktopSession(ctx, nil)
	}
	if desktop == "" {
		return fmt.Errorf("could not tell which desktop session is running.\n%s", desktopChoices(e.Entries))
	}
	if !strings.HasSuffix(desktop, ".desktop") {
		desktop += ".desktop"
	}
	entry, ok := console.FindEntryByFile(e.Entries, desktop)
	if !ok {
		return fmt.Errorf("no session entry named %q in %s.\n%s",
			desktop, strings.Join(console.SessionDirs(), ", "), desktopChoices(e.Entries))
	}
	if console.HostsConsole(entry) {
		return fmt.Errorf("%q hosts sessions itself, so it is not somewhere to come back to -- "+
			"recording it would have this wrapper start that one.\n%s",
			desktop, desktopChoices(e.Entries))
	}
	if console.IsGamescopeSession(entry) {
		return fmt.Errorf("%q is the console session, not a desktop.\n%s", desktop, desktopChoices(e.Entries))
	}

	self, err := os.Executable()
	if err != nil {
		return err
	}

	// A package may have installed the entry already, in which case the only
	// thing left to do is record the choice and log out. --force writes it
	// anyway, which is the way out when the installed one came from an older
	// version and no longer matches what this one would write.
	if installed, ok := console.InstalledHostingEntry(e.Entries, self); ok && !*force {
		if err := recordDesktop(e, entry); err != nil {
			return err
		}
		fmt.Printf("The hosting session is already installed (%s).\n\n", installed.Path)
		fmt.Printf("Log out and pick %q at your login screen, then run `open-couch-engine doctor`.\n",
			installed.Name)
		fmt.Printf("\nTo write it again anyway: open-couch-engine setup --force\n")
		return nil
	}
	wrapperCommand := self + " " + console.WrapperCommand
	body := console.EntryContent(entry.Name, self)

	path := filepath.Join(e.Base, console.HostingEntryFile)
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		return err
	}

	if err := recordDesktop(e, entry); err != nil {
		return err
	}

	fmt.Println(console.SetupInstructions(console.DetectLoginManager(ctx, nil), path, console.HostingEntryName(), wrapperCommand))
	return nil
}

func outputs() error {
	displays := console.ListDisplays(console.DRMRoot)
	type display struct {
		Connector   string `json:"connector"`
		Connected   bool   `json:"connected"`
		Ready       bool   `json:"ready"`
		Description string `json:"description"`
		Modes       int    `json:"modes"`
	}
	out := make([]display, 0, len(displays))
	for _, d := range displays {
		out = append(out, display{
			Connector:   d.Connector,
			Connected:   d.Connected,
			Ready:       d.Ready(),
			Description: d.Description,
			Modes:       d.Modes,
		})
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(out)
}

func setTV(args []string) error {
	if len(args) != 1 {
		return errors.New("usage: open-couch-engine tv <CONNECTOR>")
	}
	connector := args[0]
	base, err := ensureBaseDir()
	if err != nil {
		return err
	}
	cfg, err := console.LoadConfig(base)
	if err != nil {
		return err
	}

	var chosen console.Display
	found := false
	for _, d := range console.ListDisplays(console.DRMRoot) {
		if d.Connector == connector {
			chosen, found = d, true
			break
		}
	}
	if !found {
		return fmt.Errorf("no connector named %q; `open-couch-engine outputs` lists them", connector)
	}

	cfg.TVName = chosen.Connector
	// Recorded alongside the connector because the audio side has no other way
	// in: ALSA publishes the display's own name in each HDMI pin's ELD, and
	// that name is what says which pin carries this display's sound.
	cfg.TVDescription = chosen.Description
	if err := console.SaveConfig(base, cfg); err != nil {
		return err
	}
	fmt.Printf("Console mode will take over %s (%s).\n", chosen.Connector, chosen.Description)
	if !chosen.Connected {
		fmt.Println("It is not plugged in or switched on right now; the console will wait for it when it starts.")
	}
	return nil
}

// setController records whether a gamepad switching on should offer the
// console. Only the preference: acting on it is the wrapper's, in trigger.go.
func setController(args []string) error {
	if len(args) != 1 {
		return errors.New("usage: open-couch-engine controller <on|off>")
	}
	var enabled bool
	switch strings.ToLower(strings.TrimSpace(args[0])) {
	case "on", "true", "yes", "1":
		enabled = true
	case "off", "false", "no", "0":
		enabled = false
	default:
		return fmt.Errorf("%q is not on or off", args[0])
	}
	base, err := ensureBaseDir()
	if err != nil {
		return err
	}
	cfg, err := console.LoadConfig(base)
	if err != nil {
		return err
	}
	cfg.EnterOnControllerConnect = enabled
	return console.SaveConfig(base, cfg)
}

// setEnabled turns the console off or back on without touching anything a login
// manager reads -- a marker file in the user's own config directory.
//
// It is the recovery that needs no root. The README's older answer to a login
// that will not take is Ctrl+Alt+F2 and `sudo rm` of a file under
// /usr/share/wayland-sessions; from any shell, `open-couch-engine disable` does
// the same job for the common case, and the next login goes straight to the
// desktop. The session entry stays installed, so `enable` is all it takes to
// undo.
func setEnabled(on bool) error {
	base, err := ensureBaseDir()
	if err != nil {
		return err
	}
	if err := console.SetDisabled(base, !on); err != nil {
		return err
	}
	if on {
		// Turning it back on also clears a safe-mode hold and the run of failed
		// logins behind it, so the next login is judged from a clean slate.
		if stateDir, err := console.StateDir(); err == nil {
			console.RecordHostHealthy(stateDir, time.Now())
		}
		// Now, not next login: the wrapper reads the marker live, so the login
		// this was typed from can switch to the console straight away.
		fmt.Println("Open Couch will offer the console again, starting with this login.")
		return nil
	}
	fmt.Println("Open Couch will host only your desktop from now on, and your next login goes straight to it.")
	fmt.Println("The session entry stays installed; `open-couch-engine enable` turns the console back on.")
	fmt.Println()
	fmt.Println("To remove it entirely instead, from a text console (Ctrl+Alt+F2):")
	fmt.Printf("  sudo rm -f /usr/local/share/wayland-sessions/%s\n", console.HostingEntryFile)
	fmt.Printf("  sudo rm -f /usr/share/wayland-sessions/%s\n", console.HostingEntryFile)
	fmt.Printf("  rm -f ~/.local/share/wayland-sessions/%s\n", console.HostingEntryFile)
	fmt.Printf("  sudo rm -f /etc/sddm.conf.d/%s   # only if you set up autologin\n", console.AutologinDropIn)
	return nil
}

// showLog is the whole of the log contract with the application.
//
// One command with flags rather than the six the app used to call -- `log`,
// `clear-log`, `log-history`, `print-history-log`, `export-log`,
// `export-history-log` -- none of which this engine ever had. Writing a file to
// the user's home is not among them: the app already holds the text by then,
// and where to put it is a question for whatever is drawing the dialog.
func showLog(args []string) error {
	fs := flag.NewFlagSet("log", flag.ContinueOnError)
	clear := fs.Bool("clear", false, "empty the log for this login")
	list := fs.Bool("list", false, "the logins kept, as JSON")
	session := fs.String("session", "", "print one kept login by id")
	if err := fs.Parse(args); err != nil {
		return err
	}

	stateDir, err := console.StateDir()
	if err != nil {
		return err
	}

	switch {
	case *clear:
		return console.ClearLog(stateDir)
	case *list:
		sessions, err := console.LogSessions(stateDir)
		if err != nil {
			return err
		}
		encoder := json.NewEncoder(os.Stdout)
		encoder.SetIndent("", "  ")
		return encoder.Encode(sessions)
	case *session != "":
		text, err := console.ReadLogSession(stateDir, *session)
		if err != nil {
			return err
		}
		_, err = io.WriteString(os.Stdout, text)
		return err
	}

	text, err := console.ReadLog(stateDir)
	if err != nil {
		return err
	}
	_, err = io.WriteString(os.Stdout, text)
	return err
}

func setBoot(args []string) error {
	if len(args) != 1 {
		return errors.New("usage: open-couch-engine boot <desktop|console|last>")
	}
	mode := console.BootMode(args[0])
	if !mode.Valid() {
		return fmt.Errorf("%q is not a boot mode; use desktop, console or last", args[0])
	}
	base, err := ensureBaseDir()
	if err != nil {
		return err
	}
	cfg, err := console.LoadConfig(base)
	if err != nil {
		return err
	}
	cfg.Boot = mode
	return console.SaveConfig(base, cfg)
}

// displayName is what to call the display in a sentence the user reads: the
// name it calls itself, falling back to the connector when it has none.
func displayName(cfg console.Config) string {
	if cfg.TVDescription != "" {
		return cfg.TVDescription
	}
	return cfg.TVName
}

// logTimeLayout is RFC 3339 with milliseconds. The plain second was too coarse
// to see where the black screen between the desktop and gamescope goes: the
// waits it is made of -- Sanitize, SettleJobs, the audio move, the connector --
// are a few hundred milliseconds each, and rounding them to the second hid which
// one was the long pole.
const logTimeLayout = "2006-01-02T15:04:05.000Z07:00"

func logger(stateDir string) func(string, ...any) {
	// No state directory is a login whose cache directory could not be
	// resolved. Joining onto "" would put this login's console.log in whatever
	// the login manager left as the working directory.
	if stateDir == "" {
		return func(format string, args ...any) { fmt.Fprintf(os.Stderr, format+"\n", args...) }
	}
	path := filepath.Join(stateDir, "console.log")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return func(format string, args ...any) { fmt.Fprintf(os.Stderr, format+"\n", args...) }
	}
	return func(format string, args ...any) {
		line := fmt.Sprintf(time.Now().Format(logTimeLayout)+" "+format+"\n", args...)
		fmt.Fprint(os.Stderr, line)
		_, _ = file.WriteString(line)
	}
}

// desktopChoices lists the entries that are actually desktops, for a message
// that refuses one that is not.
//
// A refusal that does not say what would work leaves the user to go and read a
// session directory themselves, which is the moment they pick the hosting entry
// again.
func desktopChoices(entries []console.Entry) string {
	choices := []string{}
	for _, entry := range entries {
		if console.HostsConsole(entry) || console.IsGamescopeSession(entry) {
			continue
		}
		choices = append(choices, "  open-couch-engine setup --desktop "+entry.File()+"   ("+entry.Name+")")
	}
	if len(choices) == 0 {
		return "No desktop session entries were found at all."
	}
	return "Pick one of:\n" + strings.Join(choices, "\n")
}

// recordDesktop remembers which desktop to come back to, and what it calls
// itself.
//
// Recorded at setup rather than at the first switch: this is the moment the
// answer is known for certain, because it is the session running right now.
// Plenty of entries declare no DesktopNames -- Omarchy's does not, because under
// uwsm the Exec line carries it -- so the running session is the only place the
// identity can be read rather than guessed.
func recordDesktop(e env, entry console.Entry) error {
	e.Config.DesktopSession = entry.File()
	if len(entry.DesktopNames) > 0 {
		e.Config.DesktopNames = strings.Join(entry.DesktopNames, ":")
	} else if live := strings.TrimSpace(os.Getenv("XDG_CURRENT_DESKTOP")); live != "" {
		e.Config.DesktopNames = live
	}
	return console.SaveConfig(e.Base, e.Config)
}

// hostingInstalled reports whether a system session directory already carries
// the hosting entry for this exact binary.
func hostingInstalled(e env) bool {
	self, err := os.Executable()
	if err != nil {
		return false
	}
	_, ok := console.InstalledHostingEntry(e.Entries, self)
	return ok
}
