// macosapp is the tiny launcher used by the macOS .app bundle.
// It keeps the server binary inside Contents/Resources, stores mutable data in
// ~/Library/Application Support/WorkBuddy2API, and opens the panel when ready.
package main

import (
	"context"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

const panelURL = "http://127.0.0.1:7863/panel/"

func dataDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "."
	}
	return filepath.Join(home, "Library", "Application Support", "WorkBuddy2API")
}

func panelReady() bool {
	ctx, cancel := context.WithTimeout(context.Background(), 1200*time.Millisecond)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, panelURL, nil)
	if err != nil {
		return false
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return false
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

func openPanel() {
	_ = exec.Command("/usr/bin/open", panelURL).Run()
}

func main() {
	root := dataDir()
	_ = os.MkdirAll(filepath.Join(root, "auths"), 0700)
	_ = os.MkdirAll(filepath.Join(root, "data"), 0700)

	// Reusing an already running instance makes launching the app idempotent.
	if panelReady() {
		openPanel()
		return
	}

	exe, err := os.Executable()
	if err != nil {
		return
	}
	bin := filepath.Join(filepath.Dir(filepath.Dir(exe)), "Resources", "wb2api")
	logPath := filepath.Join(root, "data", "server.log")
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return
	}
	defer logFile.Close()

	cmd := exec.Command(bin, "-config", filepath.Join(root, "config.json"))
	cmd.Dir = root
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	if err := cmd.Start(); err != nil {
		return
	}

	go func() {
		for i := 0; i < 30; i++ {
			if panelReady() {
				openPanel()
				return
			}
			time.Sleep(500 * time.Millisecond)
		}
	}()

	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	select {
	case <-sig:
		_ = cmd.Process.Signal(syscall.SIGTERM)
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			_ = cmd.Process.Kill()
		}
	case <-done:
	}
}
