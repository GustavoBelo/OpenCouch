package console

import (
	"os"
	"path/filepath"
	"testing"
)

// Everything the file records has to survive a save and a load. A field that
// silently does not round-trip is a setting the user changes and then finds
// changed back.
func TestConfigRoundTrips(t *testing.T) {
	dir := t.TempDir()
	want := Config{
		Enabled:                  true,
		TVName:                   "DP-1",
		TVDescription:            "Technical Concepts Ltd 25G64",
		DesktopSession:           "omarchy.desktop",
		Boot:                     BootConsole,
		EnterOnControllerConnect: true,
	}
	if err := SaveConfig(dir, want); err != nil {
		t.Fatal(err)
	}

	got, err := LoadConfig(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Errorf("round trip = %+v, want %+v", got, want)
	}
}

// A missing file is a machine that has not configured console mode, not an
// error: every status path loads this before it knows whether to care.
func TestLoadConfigOnNothingIsAnEmptyConfig(t *testing.T) {
	cfg, err := LoadConfig(t.TempDir())
	if err != nil {
		t.Fatalf("LoadConfig = %v, want a blank config", err)
	}
	if cfg.Configured() {
		t.Errorf("cfg = %+v, want nothing configured", cfg)
	}
}

// Normalize has to run on the way in as well as out, or a hand-edited file with
// stray whitespace names a connector that no display has.
func TestLoadConfigNormalises(t *testing.T) {
	dir := t.TempDir()
	body := `{"enabled":true,"tv_name":"  DP-1  ","desktop_session":" omarchy.desktop ","boot":"nonsense"}`
	if err := os.WriteFile(filepath.Join(dir, "console.json"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}

	cfg, err := LoadConfig(dir)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.TVName != "DP-1" {
		t.Errorf("TVName = %q, want it trimmed", cfg.TVName)
	}
	if cfg.DesktopSession != "omarchy.desktop" {
		t.Errorf("DesktopSession = %q, want it trimmed", cfg.DesktopSession)
	}
	// An unreadable boot mode has to land somewhere safe, and the desktop is
	// the only safe answer: booting into a console that cannot start leaves the
	// machine with no session at all.
	if cfg.Boot != BootDesktop {
		t.Errorf("Boot = %q, want the desktop for an unknown mode", cfg.Boot)
	}
}

// Migrating from couch mode carries the TV over so the user does not choose the
// same display twice.
func TestMigrateFromCouchCarriesTheDisplay(t *testing.T) {
	dir := t.TempDir()
	body := `{"enabled":true,"layout":{"tv_key":"sam|q80","tv_name":"HDMI-A-1"},"enter_on_controller_connect":true}`
	if err := os.WriteFile(filepath.Join(dir, "couch.json"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}

	cfg, err := LoadConfig(dir)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.TVName != "HDMI-A-1" {
		t.Errorf("cfg = %+v, want the couch TV carried over", cfg)
	}
}

// The controller trigger is deliberately NOT carried over. Under couch mode it
// rearranged some displays; now it ends the desktop session and everything open
// on it, so it has to be chosen again with that in mind.
func TestMigrateFromCouchRefusesToCarryTheTrigger(t *testing.T) {
	dir := t.TempDir()
	body := `{"enabled":true,"layout":{"tv_key":"sam|q80","tv_name":"HDMI-A-1"},"enter_on_controller_connect":true}`
	if err := os.WriteFile(filepath.Join(dir, "couch.json"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}

	cfg, err := LoadConfig(dir)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.EnterOnControllerConnect {
		t.Fatal("the controller trigger was carried over; switching a pad on would now close the desktop unasked")
	}
}

// Migration must not write anything back. The couch file is someone's existing
// configuration, and a load is not a save.
func TestMigrateFromCouchWritesNothing(t *testing.T) {
	dir := t.TempDir()
	body := `{"enabled":true,"layout":{"tv_key":"sam|q80","tv_name":"HDMI-A-1"}}`
	if err := os.WriteFile(filepath.Join(dir, "couch.json"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}

	if _, err := LoadConfig(dir); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(ConfigPath(dir)); !os.IsNotExist(err) {
		t.Errorf("loading wrote console.json: %v", err)
	}
}

// A couch file with no display is nothing to migrate from, and inventing a
// blank config from it would hide the fact that nothing is set up.
func TestMigrateFromCouchIgnoresAFileWithNoDisplay(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "couch.json"), []byte(`{"enabled":true,"layout":{}}`), 0o600); err != nil {
		t.Fatal(err)
	}

	cfg, err := LoadConfig(dir)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Configured() {
		t.Errorf("cfg = %+v, want nothing carried over", cfg)
	}
}
