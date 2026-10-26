package updater

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

func TestReadinessFixture(t *testing.T) {
	mode := os.Getenv("WB2API_READY_FIXTURE")
	if mode == "" {
		t.Skip("subprocess fixture")
	}
	if os.Getenv(readyPathEnv) == "" {
		if path := os.Getenv("WB2API_ROLLBACK_MARKER"); path != "" {
			if err := os.WriteFile(path, []byte("restored"), 0600); err != nil {
				t.Fatal(err)
			}
		}
		return
	}
	switch mode {
	case "exit":
		return
	case "unready":
		time.Sleep(10 * time.Second)
	case "wrong-token":
		_ = os.Setenv(readyTokenEnv, "wrong")
		if err := ReportReady(); err != nil {
			t.Fatal(err)
		}
		time.Sleep(10 * time.Second)
	default:
		if err := ReportReady(); err != nil {
			t.Fatal(err)
		}
		if mode == "crash" {
			time.Sleep(40 * time.Millisecond)
			// Kill the process rather than returning through the race runtime's
			// exit delay: this fixture models an actual post-readiness crash.
			process, err := os.FindProcess(os.Getpid())
			if err != nil {
				t.Fatal(err)
			}
			if err := process.Kill(); err != nil {
				t.Fatal(err)
			}
			select {}
		}
		time.Sleep(10 * time.Second)
	}
}

func TestReadinessRequiresReceiptAndStableProcess(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	for _, mode := range []string{"healthy", "exit", "crash", "unready", "wrong-token"} {
		t.Run(mode, func(t *testing.T) {
			cmd := exec.Command(executable, "-test.run=^TestReadinessFixture$")
			cmd.Env = append(os.Environ(), "WB2API_READY_FIXTURE="+mode)
			safe, err := startVerified(cmd, 500*time.Millisecond, 150*time.Millisecond)
			if mode == "healthy" {
				if err != nil {
					t.Fatal(err)
				}
				_ = cmd.Process.Kill()
			} else if err == nil || !safe {
				t.Fatalf("failed child must be stopped before rollback: safe=%v err=%v", safe, err)
			}
		})
	}
}

// Exercise the real helper, including replacement and rollback, on every OS.
// Install's deployment restriction is deliberately not bypassed in production.
func TestHelperRollsBackAfterSuccessfulSpawn(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	original, err := os.ReadFile(executable)
	if err != nil {
		t.Fatal(err)
	}
	for _, mode := range []string{"exit", "crash", "healthy"} {
		t.Run(mode, func(t *testing.T) {
			dir := t.TempDir()
			ext := filepath.Ext(executable)
			target, stage, helper := filepath.Join(dir, "wb2api"+ext), filepath.Join(dir, ".wb2api-stage-test"+ext), filepath.Join(dir, ".wb2api-updater-test"+ext)
			for _, path := range []string{target, stage, helper} {
				if err := os.WriteFile(path, original, 0700); err != nil {
					t.Fatal(err)
				}
			}
			// Obtain a known exited PID for the old-process wait protocol.
			old := exec.Command(executable, "-test.run=^$")
			if err := old.Run(); err != nil {
				t.Fatal(err)
			}
			args, _ := json.Marshal([]string{"-test.run=^TestReadinessFixture$"})
			marker := filepath.Join(dir, "rollback.txt")
			cmd := exec.Command(helper, selfUpdateArg, strconv.Itoa(old.Process.Pid), stage, target, dir, string(args))
			cmd.Env = append(os.Environ(), "WB2API_READY_FIXTURE="+mode, "WB2API_ROLLBACK_MARKER="+marker)
			out, err := cmd.CombinedOutput()
			if (err != nil) != (mode != "healthy") {
				t.Fatalf("helper: %v\n%s", err, out)
			}
			_, markerErr := os.Stat(marker)
			if (markerErr == nil) != (mode != "healthy") {
				t.Fatalf("rollback marker: %v", markerErr)
			}
			got, err := os.ReadFile(target)
			if err != nil || !bytes.Equal(got, original) {
				t.Fatalf("target not installed/restored: %v", err)
			}
			if _, err := os.Stat(target + ".old"); !os.IsNotExist(err) {
				t.Fatalf("backup still present: %v", err)
			}
		})
	}
}
