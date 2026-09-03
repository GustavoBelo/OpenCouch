package console

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"

	"github.com/GustavoBelo/OpenCouch/engine/internal/atomicfile"
	"github.com/GustavoBelo/OpenCouch/engine/internal/audio"
)

// Prepared is what entering the console changed, kept so leaving can put it
// back.
//
// It is a file rather than memory because the process that made the change is
// killed by the change itself: the desktop compositor goes away, and whatever
// asked for the switch goes with it. Only the wrapper survives, and it reads
// this back on the way out.
type Prepared struct {
	// PreviousSink is the default output before the console took it.
	PreviousSink string `json:"previous_sink,omitempty"`
	// Card and PreviousCardProfile are recorded only when the card had to
	// switch profile, since HDMI profiles are exclusive and the TV's sink does
	// not exist until its profile is active.
	Card                string `json:"card,omitempty"`
	PreviousCardProfile string `json:"previous_card_profile,omitempty"`
}

func preparedPath(stateDir string) string { return filepath.Join(stateDir, "console-prepared.json") }

// ReadPrepared returns what a previous enter recorded, if anything.
func ReadPrepared(stateDir string) (Prepared, bool) {
	data, err := os.ReadFile(preparedPath(stateDir))
	if err != nil {
		return Prepared{}, false
	}
	var p Prepared
	if json.Unmarshal(data, &p) != nil {
		return Prepared{}, false
	}
	return p, true
}

func writePrepared(stateDir string, p Prepared) error {
	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	return atomicfile.Write(preparedPath(stateDir), append(data, '\n'), 0o600)
}

func clearPrepared(stateDir string) { _ = os.Remove(preparedPath(stateDir)) }

// PrepareAudio sends sound to the TV and records where it was.
//
// An existing record is never overwritten. Entering twice would otherwise record
// the TV as the desktop's own choice, and leaving would hand the desktop back to
// a television nobody is watching.
func PrepareAudio(ctx context.Context, stateDir, tvDescription string, logf func(string, ...any)) error {
	if _, already := ReadPrepared(stateDir); already {
		return nil
	}
	target, err := audio.Resolve(ctx, tvDescription)
	if err != nil {
		return err
	}
	previous, err := audio.DefaultSink(ctx)
	if err != nil {
		return err
	}

	record := Prepared{PreviousSink: previous}
	if target.CardProfile != "" && target.CardProfile != target.CardActiveProfile {
		record.Card = target.Card
		record.PreviousCardProfile = target.CardActiveProfile
	}
	// Write before changing anything: a crash between the two must leave a
	// record that can undo, not a change with no record.
	if err := writePrepared(stateDir, record); err != nil {
		return err
	}

	sink, err := target.Activate(ctx)
	if err != nil {
		// The card never produced a usable output, so put back whatever the
		// attempt disturbed rather than leaving sound in a half-switched state.
		RestoreAudio(ctx, stateDir, logf)
		return err
	}
	if err := audio.SelectSink(ctx, sink); err != nil {
		RestoreAudio(ctx, stateDir, logf)
		return err
	}
	logf("console: audio moved to the TV on %s (%s)", target.Port, sink.Name)
	return nil
}

// RestoreAudio puts sound back where the desktop had it.
//
// Order matters: the default output moves first, then the card profile. The
// other way round takes the TV's port away while streams are still on it, and
// PipeWire rehomes them to whatever it likes.
func RestoreAudio(ctx context.Context, stateDir string, logf func(string, ...any)) {
	record, ok := ReadPrepared(stateDir)
	if !ok {
		return
	}
	if record.PreviousSink != "" {
		sinks, err := audio.ListSinks(ctx)
		if err == nil {
			if restore, found := audio.SinkByName(sinks, record.PreviousSink); found {
				if err := audio.SelectSink(ctx, restore); err != nil {
					logf("console: could not put sound back on %s: %v", record.PreviousSink, err)
				}
			} else {
				// Headphones unplugged mid-session: there is nothing to go back
				// to, and forcing it would only fail.
				logf("console: the previous audio output %s is gone; leaving sound where it is", record.PreviousSink)
			}
		}
	}
	if record.Card != "" && record.PreviousCardProfile != "" {
		if err := audio.SetCardProfile(ctx, record.Card, record.PreviousCardProfile); err != nil {
			logf("console: could not restore the audio card profile %s: %v", record.PreviousCardProfile, err)
		}
	}
	clearPrepared(stateDir)
}
