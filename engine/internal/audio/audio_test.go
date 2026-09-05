package audio

import (
	"os"
	"path/filepath"
	"testing"
)

// The TV's audio output is found through the EDID, because nothing else links
// a display connector to a sound device. Every HDMI sink on this card is
// described as the graphics card itself.
func TestMatchPinFindsTheDisplayByItsEDIDName(t *testing.T) {
	pins := []Pin{
		{Card: 1, Pin: 0, MonitorName: "25G64"},   // the desk monitor
		{Card: 1, Pin: 1, MonitorName: "SAMSUNG"}, // the TV
	}

	got, ok := MatchPin(pins, "Samsung Electric Company SAMSUNG 0x01000E00")
	if !ok || got.Pin != 1 {
		t.Fatalf("expected the TV on pin 1, got %+v ok=%v", got, ok)
	}

	got, ok = MatchPin(pins, "Technical Concepts Ltd 25G64")
	if !ok || got.Pin != 0 {
		t.Fatalf("expected the desk monitor on pin 0, got %+v ok=%v", got, ok)
	}
}

// Refusing beats guessing: sending a console session's sound to the desk
// monitor is worse than leaving it where the user had it.
func TestMatchPinRefusesWhenNothingMatches(t *testing.T) {
	pins := []Pin{{Card: 1, Pin: 0, MonitorName: "25G64"}}
	if _, ok := MatchPin(pins, "Samsung Electric Company SAMSUNG"); ok {
		t.Fatal("a pin that is not the TV must not be offered as one")
	}
	if _, ok := MatchPin(nil, "Samsung Electric Company SAMSUNG"); ok {
		t.Fatal("no pins means no answer")
	}
}

// A two- or three-letter monitor name is inside half the descriptions on a
// machine, so it cannot be enough on its own.
func TestMatchPinIgnoresShortNames(t *testing.T) {
	pins := []Pin{{Card: 1, Pin: 0, MonitorName: "LG"}}
	if _, ok := MatchPin(pins, "LG Electronics OLED"); ok {
		t.Fatal("a two-letter name must not decide which pin is the TV")
	}
}

func TestMatchPinPrefersTheLongerName(t *testing.T) {
	pins := []Pin{
		{Card: 1, Pin: 0, MonitorName: "SAMS"},
		{Card: 1, Pin: 1, MonitorName: "SAMSUNG"},
	}
	got, ok := MatchPin(pins, "Samsung Electric Company SAMSUNG")
	if !ok || got.Pin != 1 {
		t.Fatalf("expected the more specific match, got %+v", got)
	}
}

func TestReadPinsSkipsPinsWithNoDisplay(t *testing.T) {
	root := t.TempDir()
	card := filepath.Join(root, "card1")
	if err := os.MkdirAll(card, 0o755); err != nil {
		t.Fatal(err)
	}
	writeELDFixture(t, filepath.Join(card, "eld#0.0"), "1", "25G64")
	writeELDFixture(t, filepath.Join(card, "eld#0.1"), "1", "SAMSUNG")
	// A connector with nothing plugged in reports present 0 and no name.
	writeELDFixture(t, filepath.Join(card, "eld#0.2"), "0", "")

	pins := ReadPins(root)
	if len(pins) != 2 {
		t.Fatalf("got %d pins, want 2: %+v", len(pins), pins)
	}
	if pins[0].Pin != 0 || pins[0].MonitorName != "25G64" {
		t.Errorf("first pin = %+v", pins[0])
	}
	if pins[1].Card != 1 || pins[1].Pin != 1 || pins[1].MonitorName != "SAMSUNG" {
		t.Errorf("second pin = %+v", pins[1])
	}
}

// The pin index is what names the port, and the port is what says which
// display a sink actually reaches.
func TestPortForProfile(t *testing.T) {
	cases := map[string]string{
		"output:hdmi-stereo":            "hdmi-output-0",
		"output:hdmi-stereo-extra1":     "hdmi-output-1",
		"output:hdmi-surround-extra2":   "hdmi-output-2",
		"output:hdmi-surround71-extra3": "hdmi-output-3",
	}
	for profile, want := range cases {
		got, ok := PortForProfile(profile)
		if !ok || got != want {
			t.Errorf("PortForProfile(%q) = %q ok=%v, want %q", profile, got, ok, want)
		}
	}
	for _, profile := range []string{"off", "pro-audio", "output:analog-stereo"} {
		if _, ok := PortForProfile(profile); ok {
			t.Errorf("PortForProfile(%q) claimed an HDMI port", profile)
		}
	}
}

// Switching a card that is already right would drop the sound for a moment for
// nothing.
func TestProfileForPortKeepsTheActiveProfile(t *testing.T) {
	c := Card{
		ActiveProfile: "output:hdmi-surround-extra1",
		Profiles: map[string][]string{
			"hdmi-output-1": {"output:hdmi-stereo-extra1", "output:hdmi-surround-extra1"},
		},
	}
	if got, _ := c.ProfileForPort("hdmi-output-1"); got != "output:hdmi-surround-extra1" {
		t.Errorf("profile = %q, want the active one kept", got)
	}
}

// Otherwise stereo, which is the shortest name among a port's variants.
func TestProfileForPortPrefersStereo(t *testing.T) {
	c := Card{
		ActiveProfile: "output:hdmi-stereo",
		Profiles: map[string][]string{
			"hdmi-output-1": {"output:hdmi-stereo-extra1", "output:hdmi-surround71-extra1", "output:hdmi-surround-extra1"},
		},
	}
	got, ok := c.ProfileForPort("hdmi-output-1")
	if !ok || got != "output:hdmi-stereo-extra1" {
		t.Errorf("profile = %q, want output:hdmi-stereo-extra1", got)
	}
	if _, ok := c.ProfileForPort("hdmi-output-2"); ok {
		t.Error("a port no available profile carries must not be offered")
	}
}

func writeELDFixture(t *testing.T, path, present, name string) {
	t.Helper()
	body := "monitor_present\t\t" + present + "\neld_valid\t\t1\n"
	if name != "" {
		body += "monitor_name\t\t" + name + "\n"
	}
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

// PipeWire leaves a stale sink object behind on every profile switch and every
// compositor restart. This machine had twenty-three of them for three real
// outputs, and one leftover S/PDIF sink claimed hdmi-output-1 -- the TV's port.
// Taking the first match would have sent a console session's sound to the
// wrong device entirely.
func TestSinkOnPortIgnoresStaleEntriesFromOtherCards(t *testing.T) {
	sinks := []Sink{
		{Index: 63, Name: "iec958-stereo", ALSACard: 2, ActivePort: "hdmi-output-1"}, // stale, wrong card
		{Index: 60, Name: "hdmi-stereo-extra1", ALSACard: 1, ActivePort: ""},         // stale, no port
		{Index: 2420, Name: "hdmi-stereo-extra1", ALSACard: 1, ActivePort: "hdmi-output-1"},
	}
	got, ok := SinkOnPort(sinks, "hdmi-output-1", 1)
	if !ok || got.Index != 2420 {
		t.Fatalf("SinkOnPort = %+v ok=%v, want the live sink on card 1", got, ok)
	}
}

// The newest index is the live one; an old object carries a node id that no
// longer refers to anything, and handing that to a helper switches nothing.
func TestSinkByNameTakesTheNewest(t *testing.T) {
	sinks := []Sink{
		{Index: 60, Name: "the-sink", NodeID: 100},
		{Index: 2420, Name: "the-sink", NodeID: 999},
		{Index: 429, Name: "the-sink", NodeID: 400},
	}
	got, ok := SinkByName(sinks, "the-sink")
	if !ok || got.NodeID != 999 {
		t.Fatalf("SinkByName = %+v, want the newest node id", got)
	}
	if _, ok := SinkByName(sinks, "absent"); ok {
		t.Error("a name that is not there must not be answered")
	}
}

// A caller that does not know the card should still get an answer rather than
// nothing, since refusing would be worse than the pre-existing behaviour.
func TestSinkOnPortWithoutACardFallsBackToThePortAlone(t *testing.T) {
	sinks := []Sink{{Index: 7, Name: "only", ALSACard: 3, ActivePort: "hdmi-output-1"}}
	if _, ok := SinkOnPort(sinks, "hdmi-output-1", -1); !ok {
		t.Fatal("an unknown card must not make the lookup fail")
	}
}
