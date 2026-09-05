// Package audio finds the sound output that belongs to a given display, and
// switches to it.
//
// Finding "the TV's audio output" is the whole difficulty. A graphics card
// presents one HDMI audio device per connector as a *pin*, and the sinks
// PulseAudio derives from them are named after the card, not the display: every
// one of them says "Navi 48 HDMI/DP Audio Controller". On a machine with the
// desk monitor on one connector and the TV on another, picking a sink by its
// name or description picks the wrong one about half the time -- and the half it
// got wrong here was the common one, so a console session played its sound out
// of the desk monitor.
//
// The link that does hold is the EDID. ALSA publishes each pin's ELD under
// /proc/asound, monitor name included, and that name comes from the same EDID
// the compositor reports for the connector. Matching there says which pin is the
// TV; the pin index then names the port (hdmi-output-N) and the card profile
// that exposes it.
package audio

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// ELDRoot is where ALSA publishes each HDMI pin's ELD. A variable so tests can
// point it at a fixture.
var ELDRoot = "/proc/asound"

// Target is everything needed to put sound on a display: which card, which
// profile exposes its pin, and which port that pin is.
type Target struct {
	Card string
	// ALSACard is the card index, which is what tells a live sink apart from a
	// stale one reporting the same port.
	ALSACard          int
	CardActiveProfile string
	CardProfile       string
	Port              string
	// SinkName is the sink already serving the display's port, empty when the
	// card has to switch profile before one exists.
	SinkName string
}

// Resolve finds the card, profile and port a display's audio lives on, matching
// against the display's EDID description.
//
// It refuses rather than guesses. Falling back to "any HDMI output" is what sent
// sound to the desk monitor, and a session that plays out of the wrong speakers
// is worse than one that leaves the sound where the user had it.
func Resolve(ctx context.Context, description string) (Target, error) {
	if strings.TrimSpace(description) == "" {
		return Target{}, errors.New("the display has no description to match its audio output against")
	}
	pin, err := AwaitPin(ctx, description)
	if err != nil {
		return Target{}, err
	}
	cards, err := ListCards(ctx)
	if err != nil {
		return Target{}, err
	}
	card, ok := CardForALSAIndex(cards, pin.Card)
	if !ok {
		return Target{}, fmt.Errorf("no audio card found for ALSA card %d", pin.Card)
	}
	port := PortForPin(pin.Pin)
	profile, ok := card.ProfileForPort(port)
	if !ok {
		return Target{}, fmt.Errorf("no available audio profile carries the port %s", port)
	}
	return Target{
		Card:              card.Name,
		ALSACard:          card.ALSACard,
		CardActiveProfile: card.ActiveProfile,
		CardProfile:       profile,
		Port:              port,
		SinkName:          card.SinkOnPort(port),
	}, nil
}

// Activate makes the display's port live and returns the sink serving it.
//
// The card profile is verified by effect rather than by exit status. pactl
// accepts a profile switch and reports success whether or not a usable sink
// comes out the other side, and this repository has been bitten enough times by
// commands that exit 0 and do nothing.
func (t Target) Activate(ctx context.Context) (Sink, error) {
	if t.CardProfile != "" && t.CardProfile != t.CardActiveProfile {
		if _, err := run(ctx, "pactl", "set-card-profile", t.Card, t.CardProfile); err != nil {
			return Sink{}, fmt.Errorf("select audio card profile %s: %w", t.CardProfile, err)
		}
	}
	// The sink is created asynchronously, so a read straight after the switch
	// finds nothing.
	deadline := time.Now().Add(5 * time.Second)
	for {
		sinks, err := ListSinks(ctx)
		if err == nil {
			if s, ok := SinkOnPort(sinks, t.Port, t.ALSACard); ok {
				return s, nil
			}
		}
		if time.Now().After(deadline) {
			return Sink{}, fmt.Errorf("no audio output appeared on the port %s", t.Port)
		}
		select {
		case <-ctx.Done():
			return Sink{}, ctx.Err()
		case <-time.After(150 * time.Millisecond):
		}
	}
}

// AwaitPin waits for ALSA to notice the display.
//
// A display that has just been switched on takes a moment to present its ELD,
// and the layout is often applied immediately before this runs, so the first
// read is frequently too early.
func AwaitPin(ctx context.Context, description string) (Pin, error) {
	deadline := time.Now().Add(5 * time.Second)
	for {
		if pin, ok := MatchPin(ReadPins(ELDRoot), description); ok {
			return pin, nil
		}
		if time.Now().After(deadline) {
			return Pin{}, fmt.Errorf("no HDMI audio pin is presenting the display (%s)", description)
		}
		select {
		case <-ctx.Done():
			return Pin{}, ctx.Err()
		case <-time.After(200 * time.Millisecond):
		}
	}
}

// PortForPin names the PulseAudio port for an ALSA HDMI pin index.
func PortForPin(pin int) string {
	return fmt.Sprintf("hdmi-output-%d", pin)
}

// Pin is one HDMI audio pin and the display attached to it.
type Pin struct {
	Card int
	Pin  int
	// MonitorName is the EDID monitor name, which is what ties this pin to a
	// display connector.
	MonitorName string
}

// ReadPins lists the HDMI audio pins that currently have a display on them.
//
// Files are named eld#<device>.<pin>; a pin with no display reports
// monitor_present 0 and is skipped, since it cannot be anyone's display.
func ReadPins(root string) []Pin {
	cards, err := filepath.Glob(filepath.Join(root, "card*"))
	if err != nil {
		return nil
	}
	pins := []Pin{}
	for _, cardDir := range cards {
		index, err := strconv.Atoi(strings.TrimPrefix(filepath.Base(cardDir), "card"))
		if err != nil {
			continue
		}
		elds, err := filepath.Glob(filepath.Join(cardDir, "eld#*"))
		if err != nil {
			continue
		}
		for _, path := range elds {
			pin, ok := readELD(path, index)
			if ok {
				pins = append(pins, pin)
			}
		}
	}
	sort.Slice(pins, func(i, j int) bool {
		if pins[i].Card != pins[j].Card {
			return pins[i].Card < pins[j].Card
		}
		return pins[i].Pin < pins[j].Pin
	})
	return pins
}

func readELD(path string, card int) (Pin, bool) {
	_, after, ok := strings.Cut(filepath.Base(path), ".")
	if !ok {
		return Pin{}, false
	}
	pinIndex, err := strconv.Atoi(after)
	if err != nil {
		return Pin{}, false
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return Pin{}, false
	}

	pin := Pin{Card: card, Pin: pinIndex}
	present := false
	for _, line := range strings.Split(string(data), "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), "\t")
		if !ok {
			continue
		}
		value = strings.TrimSpace(value)
		switch key {
		case "monitor_present":
			present = value == "1"
		case "monitor_name":
			pin.MonitorName = value
		}
	}
	if !present || pin.MonitorName == "" {
		return Pin{}, false
	}
	return pin, true
}

// MatchPin finds the pin whose EDID monitor name appears in the display's
// description, which is where the compositor puts the same string.
//
// The longest match wins, so a TV named "SAMSUNG" does not lose to a pin whose
// name is a shorter substring of the same description.
func MatchPin(pins []Pin, description string) (Pin, bool) {
	lowered := strings.ToLower(description)
	best := Pin{}
	found := false
	for _, pin := range pins {
		name := strings.ToLower(strings.TrimSpace(pin.MonitorName))
		// Two- and three-letter names match half the descriptions on a machine.
		if len(name) < 4 || !strings.Contains(lowered, name) {
			continue
		}
		if !found || len(name) > len(best.MonitorName) {
			best, found = pin, true
		}
	}
	return best, found
}

type Card struct {
	Name          string
	ALSACard      int
	ActiveProfile string
	// Profiles maps a port name to the available profiles that carry it.
	Profiles map[string][]string
	// Sinks maps a port name to the sink currently serving it.
	Sinks map[string]string
}

// ProfileForPort picks the profile to switch to so the port becomes usable.
//
// The active profile wins when it already carries the port, so a session does
// not disturb a card that is already right. Otherwise the shortest name wins,
// which is how stereo beats the surround variants of the same port.
func (c Card) ProfileForPort(port string) (string, bool) {
	candidates := c.Profiles[port]
	if len(candidates) == 0 {
		return "", false
	}
	for _, name := range candidates {
		if name == c.ActiveProfile {
			return name, true
		}
	}
	best := candidates[0]
	for _, name := range candidates[1:] {
		if len(name) < len(best) {
			best = name
		}
	}
	return best, true
}

func (c Card) SinkOnPort(port string) string { return c.Sinks[port] }

func CardForALSAIndex(cards []Card, index int) (Card, bool) {
	for _, c := range cards {
		if c.ALSACard == index {
			return c, true
		}
	}
	return Card{}, false
}

// ListCards reads the sound cards, their profiles and which port each one
// carries.
//
// Ports are read from the profile list rather than from the card's own port
// names: pactl's JSON writer emits a null name for every port on a system whose
// device descriptions are not ASCII, and it writes a warning per port to stderr
// while doing it. The JSON on stdout stays valid, so the warnings are ignored.
func ListCards(ctx context.Context) ([]Card, error) {
	out, err := run(ctx, "pactl", "-f", "json", "list", "cards")
	if err != nil {
		return nil, err
	}
	var raw []struct {
		Name       string            `json:"name"`
		Properties map[string]string `json:"properties"`
		Profiles   map[string]struct {
			Sinks     int  `json:"sinks"`
			Available bool `json:"available"`
		} `json:"profiles"`
		ActiveProfile string `json:"active_profile"`
	}
	if err := json.Unmarshal([]byte(out), &raw); err != nil {
		return nil, fmt.Errorf("read audio cards: %w", err)
	}

	sinks, err := ListSinks(ctx)
	if err != nil {
		return nil, err
	}

	cards := make([]Card, 0, len(raw))
	for _, entry := range raw {
		c := Card{
			Name:          entry.Name,
			ALSACard:      -1,
			ActiveProfile: entry.ActiveProfile,
			Profiles:      map[string][]string{},
			Sinks:         map[string]string{},
		}
		if index, err := strconv.Atoi(entry.Properties["alsa.card"]); err == nil {
			c.ALSACard = index
		}
		for name, profile := range entry.Profiles {
			if !profile.Available || profile.Sinks == 0 {
				continue
			}
			port, ok := PortForProfile(name)
			if !ok {
				continue
			}
			c.Profiles[port] = append(c.Profiles[port], name)
		}
		for _, port := range c.Profiles {
			sort.Strings(port)
		}
		for _, s := range sinks {
			if s.ALSACard == c.ALSACard && s.ActivePort != "" {
				c.Sinks[s.ActivePort] = s.Name
			}
		}
		cards = append(cards, c)
	}
	return cards, nil
}

// PortForProfile maps an HDMI output profile to the port it exposes.
//
// PulseAudio's ALSA module names them by pin: the first is bare, the rest carry
// an "extraN" suffix that is the pin index.
func PortForProfile(name string) (string, bool) {
	rest, ok := strings.CutPrefix(name, "output:hdmi-")
	if !ok {
		return "", false
	}
	_, suffix, hasExtra := strings.Cut(rest, "-extra")
	if !hasExtra {
		return PortForPin(0), true
	}
	pin, err := strconv.Atoi(suffix)
	if err != nil {
		return "", false
	}
	return PortForPin(pin), true
}

type Sink struct {
	// Index is PulseAudio's sink index. PipeWire keeps stale sink objects
	// around -- one per profile switch and per compositor restart -- with the
	// same names and, worse, ports that no longer belong to them. The highest
	// index is the live one, so it is what decides between namesakes.
	Index int
	// NodeID is PipeWire's node id, which is what wpctl and Omarchy's helper
	// take. It is not the pactl index, and mixing the two silently switches the
	// wrong output.
	NodeID      int
	Name        string
	Description string
	// ALSACard is the card index this sink belongs to and ActivePort the port on
	// it. Together they say which display the sound actually comes out of, which
	// the name and description never do.
	ALSACard   int
	ActivePort string
}

func ListSinks(ctx context.Context) ([]Sink, error) {
	out, err := run(ctx, "pactl", "-f", "json", "list", "sinks")
	if err != nil {
		return nil, err
	}
	var raw []struct {
		Index       int               `json:"index"`
		Name        string            `json:"name"`
		Description string            `json:"description"`
		ActivePort  string            `json:"active_port"`
		Properties  map[string]string `json:"properties"`
	}
	if err := json.Unmarshal([]byte(out), &raw); err != nil {
		return nil, fmt.Errorf("read audio outputs: %w", err)
	}
	sinks := make([]Sink, 0, len(raw))
	for _, entry := range raw {
		s := Sink{
			Index:       entry.Index,
			Name:        entry.Name,
			Description: entry.Description,
			ActivePort:  entry.ActivePort,
			ALSACard:    -1,
		}
		if index, err := strconv.Atoi(entry.Properties["alsa.card"]); err == nil {
			s.ALSACard = index
		}
		if id := entry.Properties["object.id"]; id != "" {
			_, _ = fmt.Sscanf(id, "%d", &s.NodeID)
		}
		if desc := entry.Properties["device.description"]; desc != "" {
			s.Description = desc
		}
		sinks = append(sinks, s)
	}
	return sinks, nil
}

func DefaultSink(ctx context.Context) (string, error) {
	return run(ctx, "pactl", "get-default-sink")
}

// SetCardProfile switches a card, which is how an HDMI pin becomes usable at
// all: the profiles are exclusive, so the TV's sink does not exist until its
// profile is active.
func SetCardProfile(ctx context.Context, card, profile string) error {
	_, err := run(ctx, "pactl", "set-card-profile", card, profile)
	return err
}

// SinkByName finds an output by name, newest first.
//
// Newest matters because a name is not unique: PipeWire leaves a stale object
// behind on every profile switch, and an old one carries a node id that no
// longer refers to anything. Handing that id to a helper switches nothing, or
// switches the wrong thing.
func SinkByName(sinks []Sink, name string) (Sink, bool) {
	return newest(sinks, func(s Sink) bool { return s.Name == name })
}

// SinkOnPort finds the live output serving a port on a given card.
//
// The card is part of the question, not a refinement of it. Stale sink objects
// report ports that have moved on -- this machine had an S/PDIF output claiming
// hdmi-output-1 -- so matching on the port alone can send a console session's
// sound to a completely different device.
func SinkOnPort(sinks []Sink, port string, alsaCard int) (Sink, bool) {
	return newest(sinks, func(s Sink) bool {
		return s.ActivePort == port && (alsaCard < 0 || s.ALSACard == alsaCard)
	})
}

func newest(sinks []Sink, match func(Sink) bool) (Sink, bool) {
	best, found := Sink{}, false
	for _, s := range sinks {
		if !match(s) {
			continue
		}
		if !found || s.Index > best.Index {
			best, found = s, true
		}
	}
	return best, found
}

// SelectSink switches the default output and drags playing streams with it, so
// something already making noise follows the picture to the TV.
func SelectSink(ctx context.Context, target Sink) error {
	if have("omarchy-audio-output-set-default") && target.NodeID > 0 {
		// Omarchy's helper does the same work and knows to leave DSP filter
		// chains where they are; prefer it where it exists.
		if _, err := run(ctx, "omarchy-audio-output-set-default",
			fmt.Sprint(target.NodeID), target.Name); err == nil {
			return nil
		}
	}
	if _, err := run(ctx, "pactl", "set-default-sink", target.Name); err != nil {
		return err
	}
	moveStreams(ctx, target)
	return nil
}

func moveStreams(ctx context.Context, target Sink) {
	out, err := run(ctx, "pactl", "-f", "json", "list", "sink-inputs")
	if err != nil {
		return
	}
	var inputs []struct {
		Index      int               `json:"index"`
		Properties map[string]string `json:"properties"`
	}
	if json.Unmarshal([]byte(out), &inputs) != nil {
		return
	}
	for _, input := range inputs {
		// A DSP filter chain's own output is a sink input with no application
		// behind it; moving that rewires the processing into itself.
		if input.Properties["application.name"] == "" {
			continue
		}
		_, _ = run(ctx, "pactl", "move-sink-input", fmt.Sprint(input.Index), target.Name)
	}
}

func run(ctx context.Context, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).Output()
	return strings.TrimSpace(string(out)), err
}

func have(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}
