package console

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Display is one connector the kernel knows about.
type Display struct {
	// Connector is the kernel's name for the port, which is also the only name
	// gamescope accepts: HDMI-A-1, DP-2, eDP-1.
	Connector string
	Connected bool
	// Description is what a person would recognise the display by, read from
	// its EDID. It is also what the audio side matches against, because ALSA
	// publishes the same EDID monitor name in each HDMI pin's ELD.
	Description string
	// Modes is how many modes the display has told the kernel about. Zero on a
	// connector that is "connected" but has not presented its EDID yet -- which
	// gamescope will enumerate and then refuse to select.
	Modes int
}

// Ready reports whether this display can be driven right now.
func (d Display) Ready() bool { return d.Connected && d.Modes > 0 }

// ListDisplays reports every connector on the machine.
//
// It reads the kernel directly rather than asking a compositor, for three
// reasons: the answer has to be the same on KDE, Hyprland and GNOME; the
// connector names gamescope wants are the kernel's, and a compositor's own
// naming does not always match; and the wrapper needs this between sessions,
// when no compositor is running to ask.
func ListDisplays(root string) []Display {
	dirs, err := filepath.Glob(filepath.Join(root, "card*-*"))
	if err != nil {
		return nil
	}
	displays := []Display{}
	for _, dir := range dirs {
		_, connector, ok := strings.Cut(filepath.Base(dir), "-")
		if !ok || connector == "" || isWriteback(connector) {
			continue
		}
		status, err := os.ReadFile(filepath.Join(dir, "status"))
		if err != nil {
			// A card directory with no status is not a connector: the glob also
			// catches things like card0-render, which have no display behind
			// them.
			continue
		}
		d := Display{
			Connector: connector,
			Connected: strings.TrimSpace(string(status)) == "connected",
		}
		if modes, err := os.ReadFile(filepath.Join(dir, "modes")); err == nil {
			d.Modes = len(strings.Fields(string(modes)))
		}
		if edid, err := os.ReadFile(filepath.Join(dir, "edid")); err == nil {
			d.Description = DescribeEDID(edid)
		}
		if d.Description == "" {
			d.Description = connector
		}
		displays = append(displays, d)
	}
	sort.Slice(displays, func(i, j int) bool {
		return displays[i].Connector < displays[j].Connector
	})
	return displays
}

// DescribeEDID reads the display's own name out of its EDID.
//
// The monitor-name descriptor is the string to reach for rather than the
// manufacturer code alone, because ALSA publishes that same string as each HDMI
// pin's monitor_name -- so a description built from it matches the audio pin
// exactly, instead of relying on one being a substring of the other.
func DescribeEDID(edid []byte) string {
	if len(edid) < 128 {
		return ""
	}
	header := []byte{0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00}
	for i, b := range header {
		if edid[i] != b {
			return ""
		}
	}
	vendor := edidVendor(edid)
	name := edidMonitorName(edid)
	switch {
	case vendor != "" && name != "":
		return vendor + " " + name
	case name != "":
		return name
	case vendor != "":
		// Nothing named it, so the product code is all there is to tell two
		// displays from the same maker apart.
		return fmt.Sprintf("%s %04X", vendor, uint16(edid[10])|uint16(edid[11])<<8)
	}
	return ""
}

// edidVendor decodes the three-letter PNP id packed into bytes 8 and 9 as five
// bits per letter.
func edidVendor(edid []byte) string {
	packed := uint16(edid[8])<<8 | uint16(edid[9])
	letters := make([]byte, 3)
	for i := 0; i < 3; i++ {
		shift := uint(10 - 5*i)
		value := byte(packed>>shift) & 0x1f
		if value == 0 || value > 26 {
			return ""
		}
		letters[i] = 'A' + value - 1
	}
	return string(letters)
}

// edidMonitorName reads the descriptor tagged 0xFC, which is where a display
// puts the name it calls itself.
func edidMonitorName(edid []byte) string {
	for _, offset := range []int{54, 72, 90, 108} {
		block := edid[offset : offset+18]
		if block[0] != 0 || block[1] != 0 || block[2] != 0 || block[4] != 0 {
			// A non-zero prefix is a timing descriptor, not a text one.
			continue
		}
		if block[3] != 0xfc {
			continue
		}
		text := block[5:18]
		if end := indexByte(text, 0x0a); end >= 0 {
			text = text[:end]
		}
		if name := strings.TrimSpace(string(text)); name != "" {
			return name
		}
	}
	return ""
}

func indexByte(b []byte, c byte) int {
	for i, v := range b {
		if v == c {
			return i
		}
	}
	return -1
}

// isWriteback reports whether a connector is the kernel's writeback pseudo-
// connector rather than a port with a display behind it.
//
// It is listed exactly like a real connector, disconnected and with no modes, so
// nothing but the name gives it away -- and offering it as a television to point
// gamescope at would produce a session on a display that does not exist.
func isWriteback(connector string) bool {
	return strings.HasPrefix(strings.ToLower(connector), "writeback")
}
