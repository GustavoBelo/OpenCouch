package console

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The hosting session entry is written out in three places: EntryContent here,
// a heredoc in the AUR PKGBUILD, and a file(WRITE) in app/CMakeLists.txt that
// feeds the RPM. They have already drifted once -- TryExec was added to this one
// and the packaged copies kept shipping without it, which is the copy most users
// get and the one that decides whether a broken engine locks them out.
//
// Comparing whole files is not possible: each substitutes its own install path
// with its own syntax. What has to hold is that every key this one considers
// load-bearing appears in all of them.
func TestPackagedSessionEntriesCarryTheSameKeys(t *testing.T) {
	root := repoRoot(t)

	packaged := map[string]string{
		"AUR PKGBUILD":       filepath.Join(root, "packaging", "aur", "open-couch-engine", "PKGBUILD"),
		"app/CMakeLists.txt": filepath.Join(root, "app", "CMakeLists.txt"),
	}

	// Keys, not whole lines: the value is an install path that legitimately
	// differs between the three.
	required := []string{
		"Name=" + HostingEntryName(),
		"TryExec=",
		"Type=Application",
		HostingMarker + "=true",
	}

	for name, path := range packaged {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("cannot read %s: %v", name, err)
		}
		body := string(data)
		for _, key := range required {
			if !strings.Contains(body, key) {
				t.Errorf("%s writes a hosting entry without %q; "+
					"the packaged session would behave differently from the one `setup` writes", name, key)
			}
		}
	}
}

// repoRoot walks up until it finds the module's parent, so the test does not
// depend on where `go test` was invoked from.
func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 6; i++ {
		if _, err := os.Stat(filepath.Join(dir, "packaging")); err == nil {
			return dir
		}
		dir = filepath.Dir(dir)
	}
	t.Skip("not running inside the repository; nothing to compare against")
	return ""
}
