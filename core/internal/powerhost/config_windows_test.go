package powerhost

import (
	"path/filepath"
	"testing"
)

// Loading a check-mode example performs no inventory or power operation.
func TestWindowsDeployExampleLoads(t *testing.T) {
	c, err := Load(filepath.Join("..", "..", "..", "deploy", "power-host.windows.example.json"))
	if err != nil {
		t.Fatal(err)
	}
	if c.Execute || c.WindowsDelaySec != 30 {
		t.Fatal("Windows example must remain in check mode")
	}
}
