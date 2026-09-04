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

// hostSession runs the wrapper for the whole login.
func hostSession(ctx context.Context) error {
	e, err := load()
	if err != nil {
		return err
	}
	desktop, ok := console.FindEntryByFile(e.Entries, e.Config.DesktopSession)
	if !ok {
		return fmt.Errorf("the desktop session %q was not found; run `open-couch-engine setup` or set desktop_session in %s",
			e.Config.DesktopSession, console.ConfigPath(e.Base))
	}
	if console.HostsConsole(desktop) {
		return fmt.Errorf("the configured desktop session %s is a hosting session; it would host itself forever", desktop.File())
	}

	// A session's stderr goes wherever the login manager decided, which on SDDM
	// is nowhere a person can reach. Without a file there is no way to find out
	// why a session that lasted five seconds gave up.
	logf := logger(e.StateDir)

	w := &console.Wrapper{
		DesktopExec:    desktop.Exec,
		DesktopSession: desktop.File(),
		DesktopNames:   desktop.DesktopNames,
		StateDir:       e.StateDir,
		RuntimeDir:     e.RuntimeDir,
		Choices:        e.Config,
		Boot:           e.Config.Boot,
		Logf:           logf,
		// Started once, by the login manager, then hosting every session until
		// the user logs out. What it was told above was true at login; what it
		// acts on has to be what the file says now.
		Reload: func() (console.Config, error) { return console.LoadConfig(e.Base) },
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

	if err := console.Request(e.RuntimeDir, console.ModeConsole); err != nil {
		return err
	}
	if err := console.StopCompositor(ctx, e.RuntimeDir, console.DetectCompositor()); err != nil {
		// The request outlives this process, and a request nobody acted on
		// would switch the next time the compositor ended for any reason at
		// all -- an ordinary logout, hours later.
		console.ClearRequest(e.RuntimeDir)
		return err
	}
	return nil
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
		Version                  string        `json:"version"`
		Ready                    bool          `json:"ready"`
		Hosted                   bool          `json:"hosted"`
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
	}{
		Version:                  version,
		Ready:                    len(console.Unmet(reqs)) == 0,
		Hosted:                   console.Hosted(e.RuntimeDir),
		TVName:                   e.Config.TVName,
		TVDescription:            e.Config.TVDescription,
		DesktopSession:           e.Config.DesktopSession,
		Boot:                     string(e.Config.Boot),
		EnterOnControllerConnect: e.Config.EnterOnControllerConnect,
		Controllers:              console.ConnectedControllers(),
		ConfigPath:               console.ConfigPath(e.Base),
	}
	if live, ok := console.ReadLive(e.RuntimeDir); ok {
		out.Mode = string(live.Mode)
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
	wrapperCommand := self + " " + console.WrapperCommand
	name := console.HostingEntryName(entry.Name)
	body := console.EntryContent(name, wrapperCommand)

	path := filepath.Join(e.Base, console.HostingEntryFile)
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		return err
	}

	// Recorded now rather than at the first switch: this is the moment the
	// desktop to come back to is known for certain, because it is the one
	// running.
	e.Config.DesktopSession = entry.File()
	// Same for its identity. Plenty of entries declare no DesktopNames --
	// Omarchy's does not, because under uwsm the Exec line carries it -- and the
	// running session is the only place the answer can be read rather than
	// guessed.
	if len(entry.DesktopNames) > 0 {
		e.Config.DesktopNames = strings.Join(entry.DesktopNames, ":")
	} else if live := strings.TrimSpace(os.Getenv("XDG_CURRENT_DESKTOP")); live != "" {
		e.Config.DesktopNames = live
	}
	if err := console.SaveConfig(e.Base, e.Config); err != nil {
		return err
	}

	fmt.Println(console.SetupInstructions(console.DetectLoginManager(ctx, nil), path, name, wrapperCommand))
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

func logger(stateDir string) func(string, ...any) {
	path := filepath.Join(stateDir, "console.log")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return func(format string, args ...any) { fmt.Fprintf(os.Stderr, format+"\n", args...) }
	}
	return func(format string, args ...any) {
		line := fmt.Sprintf(time.Now().Format(time.RFC3339)+" "+format+"\n", args...)
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
