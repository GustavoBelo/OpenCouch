package console

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

// fakeProc builds a /proc whose only inhabitants are the pids given, each with
// the command line it was created with.
func fakeProc(t *testing.T, cmdlines map[int][]string) {
	t.Helper()
	root := t.TempDir()
	for pid, argv := range cmdlines {
		dir := filepath.Join(root, strconv.Itoa(pid))
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		body := ""
		for _, arg := range argv {
			body += arg + "\x00"
		}
		if err := os.WriteFile(filepath.Join(dir, "cmdline"), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	original := procRoot
	procRoot = root
	t.Cleanup(func() { procRoot = original })
}

func writeMarker(t *testing.T, runtimeDir, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(runtimeDir, hostedMarker), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

// The marker lives in XDG_RUNTIME_DIR, which outlives any single process. A
// wrapper killed with SIGKILL never runs its cleanup, so the file stays until
// the last logout -- and `console enter` believed it, ended the desktop with
// everything open on it, and found no wrapper to bring anything back.
func TestHostedRefusesAMarkerWhoseWrapperIsGone(t *testing.T) {
	dir := t.TempDir()
	fakeProc(t, nil)
	writeMarker(t, dir, "4242\n")

	if Hosted(dir) {
		t.Fatal("an orphaned marker was read as a live hosting session")
	}
}

// PIDs are reused. A marker naming a number that some unrelated program now
// holds is exactly as dangerous as an orphan, and existence alone cannot tell
// the two apart.
func TestHostedRefusesAPidThatIsSomethingElseNow(t *testing.T) {
	dir := t.TempDir()
	fakeProc(t, map[int][]string{4242: {"/usr/bin/firefox"}})
	writeMarker(t, dir, "4242\n")

	if Hosted(dir) {
		t.Fatal("a reused pid was read as the wrapper")
	}
}

func TestHostedAcceptsALiveWrapper(t *testing.T) {
	dir := t.TempDir()
	fakeProc(t, map[int][]string{99: {"/home/u/.local/bin/open-couch-engine", "host-session"}})
	writeMarker(t, dir, "99\n")

	if !Hosted(dir) {
		t.Fatal("a live wrapper was not recognised")
	}
}

// A marker with nothing readable in it predates the pid being recorded. The
// answer has to be no: a wrong "yes" costs the desktop and everything open on
// it, a wrong "no" costs one `console setup` and a login.
func TestHostedRefusesAMarkerItCannotRead(t *testing.T) {
	fakeProc(t, map[int][]string{99: {"open-couch-engine", "host-session"}})
	for _, body := range []string{"", "\n", "not-a-pid\n", "0\n", "-1\n"} {
		dir := t.TempDir()
		writeMarker(t, dir, body)
		if Hosted(dir) {
			t.Errorf("marker %q was read as a live hosting session", body)
		}
	}
}

func TestHostedIsNoWithoutAMarker(t *testing.T) {
	fakeProc(t, nil)
	if Hosted(t.TempDir()) {
		t.Fatal("a session with no marker was called hosted")
	}
}

// markHosted and Hosted have to agree: the wrapper writes its own pid, and this
// process is a test binary, not a `console session`. Round-tripping through the
// real /proc would therefore fail, which is precisely why the command line is
// what gets checked rather than mere existence.
func TestMarkHostedRecordsThePidHostedReads(t *testing.T) {
	dir := t.TempDir()
	if err := markHosted(dir); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(dir, hostedMarker))
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(string(data[:len(data)-1]))
	if err != nil || pid != os.Getpid() {
		t.Fatalf("marker = %q, want this process's pid %d", data, os.Getpid())
	}
}
