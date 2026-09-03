package console

import (
	"context"
	"os"
	"testing"
	"time"
)

// A request has to be cleared when it is acted on. One that survived would
// switch again on the next exit, and the user would be unable to log out at all.
func TestTakeRequestClearsWhatItReturns(t *testing.T) {
	dir := t.TempDir()
	if err := Request(dir, ModeConsole); err != nil {
		t.Fatal(err)
	}

	mode, ok := TakeRequest(dir)
	if !ok || mode != ModeConsole {
		t.Fatalf("TakeRequest = %q ok=%v", mode, ok)
	}
	if _, ok := TakeRequest(dir); ok {
		t.Fatal("the request survived being acted on")
	}
	if _, err := os.Stat(RequestPath(dir)); !os.IsNotExist(err) {
		t.Errorf("the request file is still there: %v", err)
	}
}

// No request means a real log out, which is what keeps an ordinary logout
// working while the wrapper is hosting the session.
func TestTakeRequestOnNothingMeansLogOut(t *testing.T) {
	if _, ok := TakeRequest(t.TempDir()); ok {
		t.Fatal("no request must not be read as a switch")
	}
}

// A truncated or hand-edited file must not be read as a switch: acting on
// garbage would start a compositor nobody asked for.
func TestTakeRequestRejectsAnythingElse(t *testing.T) {
	for _, body := range []string{"", "\n", "gamescope", "console desktop", "CONSOLE"} {
		dir := t.TempDir()
		if err := os.WriteFile(RequestPath(dir), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		if mode, ok := TakeRequest(dir); ok {
			t.Errorf("TakeRequest(%q) = %q, want a refusal", body, mode)
		}
	}
}

func TestRequestRoundTripsBothModes(t *testing.T) {
	for _, want := range []Mode{ModeConsole, ModeDesktop} {
		dir := t.TempDir()
		if err := Request(dir, want); err != nil {
			t.Fatal(err)
		}
		if got, ok := TakeRequest(dir); !ok || got != want {
			t.Errorf("round trip of %q gave %q ok=%v", want, got, ok)
		}
	}
}

func TestClearRequestLeavesNothingBehind(t *testing.T) {
	dir := t.TempDir()
	if err := Request(dir, ModeConsole); err != nil {
		t.Fatal(err)
	}
	ClearRequest(dir)
	if _, ok := TakeRequest(dir); ok {
		t.Fatal("a cleared request was still acted on")
	}
	// Clearing nothing is not an error either.
	ClearRequest(dir)
}

// A switch is verified against the wrapper's own record of which session it is
// running, because the wrapper hosts whichever compositor the user configured
// and there is no socket, process name or IPC common to all of them.
func TestAwaitSessionEndFollowsTheGeneration(t *testing.T) {
	dir := t.TempDir()
	if _, ok := ReadLive(dir); ok {
		t.Fatal("an empty runtime directory has no session in it")
	}

	before := Live{Mode: ModeDesktop, Generation: 1}
	if err := WriteLive(dir, before); err != nil {
		t.Fatal(err)
	}
	got, ok := ReadLive(dir)
	if !ok || got != before {
		t.Fatalf("ReadLive = %v, %v, want %v, true", got, ok, before)
	}
	if AwaitSessionEnd(context.Background(), dir, before, 0) {
		t.Fatal("a session that is still running was reported as ended")
	}

	// The next session starting is an end: the file still exists and still
	// names a mode, and only the generation separates the two cases.
	if err := WriteLive(dir, Live{Mode: ModeConsole, Generation: 2}); err != nil {
		t.Fatal(err)
	}
	if !AwaitSessionEnd(context.Background(), dir, before, 0) {
		t.Fatal("the next session starting was not read as the previous one ending")
	}

	// So is the loop finishing.
	ClearLive(dir)
	if !AwaitSessionEnd(context.Background(), dir, before, 0) {
		t.Fatal("the wrapper's loop ending was not read as the session ending")
	}
}

// A record that cannot be read is not a running session. Reporting one would
// make a caller wait out its whole timeout for a switch that never started.
func TestReadLiveRefusesWhatItCannotParse(t *testing.T) {
	for _, body := range []string{"", "\n", "desktop\n", "desktop notanumber\n", "desktop 1 2\n"} {
		dir := t.TempDir()
		if err := os.WriteFile(dir+"/"+liveFile, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, ok := ReadLive(dir); ok {
			t.Errorf("%q was read as a running session", body)
		}
	}
}

// The daemon that arms an automatic entry and the command that calls it off are
// different processes; the runtime directory is what they share.
func TestCancelIsSeenOnceAndOnlyOnce(t *testing.T) {
	dir := t.TempDir()
	if TakeCancel(dir) {
		t.Fatal("nothing was cancelled, but a stand-down was reported")
	}
	if err := RequestCancel(dir); err != nil {
		t.Fatal(err)
	}
	if !TakeCancel(dir) {
		t.Fatal("a stand-down was asked for and not seen")
	}
	if TakeCancel(dir) {
		t.Fatal("the stand-down fired twice; the next entry would be cancelled too")
	}
}

// `open-couch-engine cancel` typed with nothing pending used to leave a file
// that sat in the runtime directory until the next entry -- minutes or hours
// later -- and called it off within a second, silently, blaming nobody.
func TestTakeCancelIgnoresAStaleRequest(t *testing.T) {
	dir := t.TempDir()
	if err := RequestCancel(dir); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-cancelMaxAge - time.Minute)
	if err := os.Chtimes(CancelPath(dir), old, old); err != nil {
		t.Fatal(err)
	}

	if TakeCancel(dir) {
		t.Error("a stale cancel called off an entry nobody had asked it to")
	}
	// Clearing it anyway is what disarms the trap, rather than leaving it for
	// the entry after this one.
	if _, err := os.Stat(CancelPath(dir)); !os.IsNotExist(err) {
		t.Errorf("the stale cancel was left behind: %v", err)
	}
}

// A cancel written while a countdown is running is the one that counts, and it
// still has to work.
func TestTakeCancelHonoursAFreshRequest(t *testing.T) {
	dir := t.TempDir()
	if err := RequestCancel(dir); err != nil {
		t.Fatal(err)
	}
	if !TakeCancel(dir) {
		t.Fatal("a cancel written just now was ignored")
	}
	if TakeCancel(dir) {
		t.Error("the cancel survived being acted on")
	}
}

// DropCancel is what a countdown calls before announcing anything, so a file
// left from before cannot call off an entry the user has not yet seen.
func TestDropCancelClearsWithoutActingOnIt(t *testing.T) {
	dir := t.TempDir()
	if err := RequestCancel(dir); err != nil {
		t.Fatal(err)
	}
	DropCancel(dir)
	if TakeCancel(dir) {
		t.Error("the dropped cancel was still there")
	}
	// Dropping nothing is not an error: every countdown does it.
	DropCancel(t.TempDir())
}
