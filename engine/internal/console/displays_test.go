package console

import (
	"os"
	"path/filepath"
	"testing"
)

// edidFor builds the part of an EDID this reads: the header, the packed vendor
// id, the product code, and one monitor-name descriptor.
func edidFor(vendor string, product uint16, name string) []byte {
	edid := make([]byte, 128)
	copy(edid, []byte{0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00})

	packed := uint16(0)
	for i := 0; i < 3 && i < len(vendor); i++ {
		packed |= uint16(vendor[i]-'A'+1) << uint(10-5*i)
	}
	edid[8] = byte(packed >> 8)
	edid[9] = byte(packed)
	edid[10] = byte(product)
	edid[11] = byte(product >> 8)

	if name != "" {
		// The first descriptor slot is a timing one, so the reader has to walk
		// past it to find the text.
		edid[54] = 0x01
		block := edid[72 : 72+18]
		block[3] = 0xfc
		copy(block[5:], name)
		if len(name) < 13 {
			block[5+len(name)] = 0x0a
		}
	}
	return edid
}

func writeConnector(t *testing.T, root, dir, status, modes string, edid []byte) {
	t.Helper()
	path := filepath.Join(root, dir)
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
	if status != "" {
		if err := os.WriteFile(filepath.Join(path, "status"), []byte(status+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if modes != "" {
		if err := os.WriteFile(filepath.Join(path, "modes"), []byte(modes), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if edid != nil {
		if err := os.WriteFile(filepath.Join(path, "edid"), edid, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestListDisplaysReadsTheKernelRatherThanACompositor(t *testing.T) {
	root := t.TempDir()
	writeConnector(t, root, "card0-HDMI-A-1", "connected", "1920x1080\n1280x720\n", edidFor("SAM", 0x0e01, "SAMSUNG"))
	writeConnector(t, root, "card0-DP-1", "connected", "2560x1440\n", edidFor("TCL", 0x1234, "25G64"))
	writeConnector(t, root, "card0-HDMI-A-2", "disconnected", "", nil)

	got := ListDisplays(root)
	if len(got) != 3 {
		t.Fatalf("got %d displays, want 3: %+v", len(got), got)
	}
	// Sorted by connector, so the order does not depend on the filesystem.
	if got[0].Connector != "DP-1" || got[1].Connector != "HDMI-A-1" || got[2].Connector != "HDMI-A-2" {
		t.Fatalf("connectors = %v, %v, %v", got[0].Connector, got[1].Connector, got[2].Connector)
	}
	if got[0].Description != "TCL 25G64" {
		t.Errorf("DP-1 description = %q, want %q", got[0].Description, "TCL 25G64")
	}
	if !got[0].Ready() || got[0].Modes != 1 {
		t.Errorf("DP-1 = %+v, want a ready display with one mode", got[0])
	}
	if got[1].Modes != 2 {
		t.Errorf("HDMI-A-1 modes = %d, want 2", got[1].Modes)
	}
	// A connector with nothing plugged in still has to be listed: it is where
	// the television will be, and the user picks it before switching it on.
	if got[2].Connected || got[2].Ready() {
		t.Errorf("HDMI-A-2 = %+v, want disconnected", got[2])
	}
	if got[2].Description != "HDMI-A-2" {
		t.Errorf("a display with no EDID should fall back to its connector, got %q", got[2].Description)
	}
}

// The writeback connector is listed by the kernel exactly like a real one.
// Offering it as a television would point gamescope at a display that does not
// exist.
func TestListDisplaysSkipsWriteback(t *testing.T) {
	root := t.TempDir()
	writeConnector(t, root, "card0-Writeback-1", "disconnected", "", nil)
	writeConnector(t, root, "card0-HDMI-A-1", "connected", "1920x1080\n", nil)

	got := ListDisplays(root)
	if len(got) != 1 || got[0].Connector != "HDMI-A-1" {
		t.Fatalf("got %+v, want only HDMI-A-1", got)
	}
}

// The monitor name is what ALSA publishes as each HDMI pin's monitor_name, so a
// description built from it matches the audio pin instead of relying on luck.
func TestDescribeEDIDPrefersTheDisplaysOwnName(t *testing.T) {
	if got := DescribeEDID(edidFor("SAM", 0x0e01, "SAMSUNG")); got != "SAM SAMSUNG" {
		t.Errorf("got %q, want %q", got, "SAM SAMSUNG")
	}
	// With no name descriptor, the product code is what separates two displays
	// from the same maker.
	if got := DescribeEDID(edidFor("TCL", 0x1234, "")); got != "TCL 1234" {
		t.Errorf("got %q, want %q", got, "TCL 1234")
	}
	// Anything that is not an EDID describes nothing, rather than describing
	// whatever the bytes happen to spell.
	for _, bad := range [][]byte{nil, make([]byte, 127), make([]byte, 128)} {
		if got := DescribeEDID(bad); got != "" {
			t.Errorf("DescribeEDID(%d bytes) = %q, want empty", len(bad), got)
		}
	}
}

// The description has to contain the ELD monitor name, because that is the only
// link between a display and the audio pin that carries its sound.
func TestDescriptionCarriesTheNameAudioMatchesOn(t *testing.T) {
	description := DescribeEDID(edidFor("TCL", 0x1234, "25G64"))
	pins := []struct{ name string }{{"25G64"}}
	for _, pin := range pins {
		if !contains(lower(description), lower(pin.name)) {
			t.Errorf("description %q does not contain the ELD monitor name %q", description, pin.name)
		}
	}
}

func lower(s string) string {
	out := []byte(s)
	for i, c := range out {
		if c >= 'A' && c <= 'Z' {
			out[i] = c + 32
		}
	}
	return string(out)
}
