package console

import (
	"os"
	"path/filepath"
	"strings"
)

// BootMode says which compositor a fresh login starts in.
//
// A console that boots to a desktop with an icon on it is not really a console.
// But making that the default would be wrong the other way: someone who
// installs this to play on the TV occasionally should not have their computer
// stop presenting a desktop.
type BootMode string

const (
	// BootDesktop always starts at the desktop. The default, and what a machine
	// did before console mode existed.
	BootDesktop BootMode = "desktop"
	// BootConsole always starts in the console, the way a games machine does.
	BootConsole BootMode = "console"
	// BootLast starts wherever the last session ended: shut down playing, boot
	// playing. It asks the user to decide nothing and never surprises them,
	// which is why it is what `console boot` suggests.
	BootLast BootMode = "last"
)

func (b BootMode) Valid() bool {
	switch b {
	case BootDesktop, BootConsole, BootLast:
		return true
	}
	return false
}

// lastModeFile records where the previous session ended, for BootLast. It lives
// in the state directory rather than the runtime one because it has to survive
// the machine being switched off, which is the only case it exists for.
const lastModeFile = "last-session"

// ReadLastMode returns the mode the previous session ended in.
func ReadLastMode(stateDir string) (Mode, bool) {
	data, err := os.ReadFile(filepath.Join(stateDir, lastModeFile))
	if err != nil {
		return "", false
	}
	switch mode := Mode(strings.TrimSpace(string(data))); mode {
	case ModeDesktop, ModeConsole:
		return mode, true
	default:
		return "", false
	}
}

// WriteLastMode records the mode now running, so a BootLast machine comes back
// to it.
func WriteLastMode(stateDir string, mode Mode) {
	_ = os.WriteFile(filepath.Join(stateDir, lastModeFile), []byte(string(mode)+"\n"), 0o600)
}

// BootModeFor decides what a fresh hosting session should start in.
//
// A pending request always wins: it is the one case where somebody has just
// said what they want, and a preference should not override an instruction.
// This is what makes `console enter` work when it is the compositor's own exit
// that hands control back to the wrapper.
func BootModeFor(boot BootMode, requested Mode, hasRequest bool, last Mode, hasLast bool) Mode {
	if hasRequest {
		return requested
	}
	switch boot {
	case BootConsole:
		return ModeConsole
	case BootLast:
		if hasLast {
			return last
		}
		return ModeDesktop
	default:
		return ModeDesktop
	}
}
