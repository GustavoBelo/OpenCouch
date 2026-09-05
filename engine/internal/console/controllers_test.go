package console

import (
	"os"
	"path/filepath"
	"testing"
)

func TestConnectedControllersNeverNegative(t *testing.T) {
	if ConnectedControllers() < 0 {
		t.Fatal("negative controller count")
	}
}

// The sysfs bitmap is space-separated hex words, most significant first, so
// bit 0x130 lands in the fifth word counting back from the end.
func TestKeyBitSetReadsGamepadButton(t *testing.T) {
	cases := []struct {
		name   string
		bitmap string
		want   bool
	}{
		// A real Xbox pad: BTN_SOUTH..BTN_THUMBR set in the 0x130 block.
		{"gamepad", "3 0 0 7 0 0 0 0 0 0", false},
		{"gamepad bit set", "1000000000000 0 0 0 0", true},
		// A keyboard from this host: four words, so bit 304 is out of range.
		{"keyboard", "1000000000007 ff800000000007ff febeffdfffefffff fffffffffffffffe", false},
		// A mouse from this host: nine words, but the 0x130 word is zero.
		{"mouse", "7e40000 0 800000000000 0 0 1400b00100000 300180001100800 e000000000000 2", false},
		{"empty", "", false},
		{"garbage", "not-hex", false},
	}
	for _, tc := range cases {
		if got := keyBitSet(tc.bitmap, btnGamepad); got != tc.want {
			t.Fatalf("%s: keyBitSet(%q) = %v, want %v", tc.name, tc.bitmap, got, tc.want)
		}
	}
}

func TestConnectedControllersCountsEvdevGamepads(t *testing.T) {
	root := t.TempDir()
	write := func(dir, bitmap string) {
		t.Helper()
		path := filepath.Join(root, dir, "device", "capabilities")
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		if err := os.WriteFile(filepath.Join(path, "key"), []byte(bitmap+"\n"), 0o644); err != nil {
			t.Fatalf("write: %v", err)
		}
	}
	write("event0", "1000000000007 ff800000000007ff febeffdfffefffff fffffffffffffffe") // keyboard
	write("event1", "1000000000000 0 0 0 0")                                            // gamepad
	write("event2", "1000000000000 0 0 0 0")                                            // second gamepad
	write("mouse0", "1000000000000 0 0 0 0")                                            // not an event node

	oldRoot, oldGlob := InputClassRoot, LegacyJoystickGlob
	InputClassRoot = root
	LegacyJoystickGlob = filepath.Join(root, "nonexistent-js*")
	defer func() { InputClassRoot, LegacyJoystickGlob = oldRoot, oldGlob }()

	if got := ConnectedControllers(); got != 2 {
		t.Fatalf("expected 2 gamepads, got %d", got)
	}
}

// joydev being loaded is not enough for /dev/input/js* to exist; the glob is
// empty on this host while a controller would still show up in evdev.
func TestConnectedControllersFallsBackToLegacyNodes(t *testing.T) {
	root := t.TempDir()
	jsDir := t.TempDir()
	for _, name := range []string{"js0", "js1"} {
		if err := os.WriteFile(filepath.Join(jsDir, name), nil, 0o644); err != nil {
			t.Fatalf("write: %v", err)
		}
	}

	oldRoot, oldGlob := InputClassRoot, LegacyJoystickGlob
	InputClassRoot = filepath.Join(root, "missing")
	LegacyJoystickGlob = filepath.Join(jsDir, "js*")
	defer func() { InputClassRoot, LegacyJoystickGlob = oldRoot, oldGlob }()

	if got := ConnectedControllers(); got != 2 {
		t.Fatalf("expected the legacy fallback to find 2, got %d", got)
	}
}
