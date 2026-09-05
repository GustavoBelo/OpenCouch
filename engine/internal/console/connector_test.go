package console

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func drmFixture(t *testing.T, connector, status, modes string) string {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, "card1-"+connector)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(dir, "status"), status+"\n")
	write(t, filepath.Join(dir, "modes"), modes)
	return root
}

// "connected" alone is not ready: it appears before the EDID has been read, and
// a connector with no modes is exactly the one gamescope enumerates and then
// refuses to select.
func TestConnectorReadyNeedsModesAsWellAsConnected(t *testing.T) {
	ready := drmFixture(t, "HDMI-A-1", "connected", "3840x2160\n1920x1080\n")
	if !ConnectorReady(ready, "HDMI-A-1") {
		t.Error("a connected display with modes was not called ready")
	}

	noModes := drmFixture(t, "HDMI-A-1", "connected", "")
	if ConnectorReady(noModes, "HDMI-A-1") {
		t.Error("a connector with no modes must not be called ready")
	}

	unplugged := drmFixture(t, "HDMI-A-1", "disconnected", "")
	if ConnectorReady(unplugged, "HDMI-A-1") {
		t.Error("a disconnected connector must not be called ready")
	}

	if ConnectorReady(ready, "HDMI-A-2") {
		t.Error("a connector that does not exist must not be called ready")
	}
	if ConnectorReady(ready, "") {
		t.Error("no connector is not a ready connector")
	}
}

func TestAwaitConnectorReturnsAtOnceWhenReady(t *testing.T) {
	old := DRMRoot
	DRMRoot = drmFixture(t, "HDMI-A-1", "connected", "3840x2160\n")
	defer func() { DRMRoot = old }()

	start := time.Now()
	if !AwaitConnector(context.Background(), "HDMI-A-1", time.Minute, nil) {
		t.Fatal("a ready connector was not recognised")
	}
	if time.Since(start) > time.Second {
		t.Error("a ready connector should not be waited for")
	}
}

// A television that is switched off never becomes ready. Refusing to start the
// console for that reason would be worse than starting it on a display the user
// is about to switch on.
func TestAwaitConnectorGivesUpRatherThanBlockingForever(t *testing.T) {
	old := DRMRoot
	DRMRoot = drmFixture(t, "HDMI-A-1", "disconnected", "")
	defer func() { DRMRoot = old }()

	done := make(chan bool, 1)
	go func() { done <- AwaitConnector(context.Background(), "HDMI-A-1", 400*time.Millisecond, nil) }()
	select {
	case ready := <-done:
		if ready {
			t.Fatal("a disconnected display was reported ready")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("AwaitConnector never gave up")
	}
}

// An empty connector is not something to wait for -- there is nothing to wait on.
func TestAwaitConnectorWithNoConnectorDoesNotWait(t *testing.T) {
	if !AwaitConnector(context.Background(), "", time.Minute, nil) {
		t.Error("no connector configured should not block the console")
	}
}
