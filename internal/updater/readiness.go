package updater

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const readyPathEnv = "WB2API_UPDATE_READY_PATH"
const readyTokenEnv = "WB2API_UPDATE_READY_TOKEN"

type readyReceipt struct {
	PID   int    `json:"pid"`
	Token string `json:"token"`
}

// ReportReady is called only after configuration is loaded and the HTTP port
// has been bound. A per-launch token and PID prevent accepting stale receipts.
// Ordinary launches (including rollback to an older binary) need no receipt.
func ReportReady() error {
	path, token := os.Getenv(readyPathEnv), os.Getenv(readyTokenEnv)
	_ = os.Unsetenv(readyPathEnv)
	_ = os.Unsetenv(readyTokenEnv)
	if path == "" && token == "" {
		return nil
	}
	if path == "" || token == "" {
		return errors.New("更新启动凭据不完整")
	}
	data, err := json.Marshal(readyReceipt{PID: os.Getpid(), Token: token})
	if err != nil {
		return err
	}
	if err := os.WriteFile(path+".tmp", data, 0600); err != nil {
		return err
	}
	return os.Rename(path+".tmp", path)
}

func withoutReadinessEnv(env []string) []string {
	var clean []string
	for _, entry := range env {
		key, _, _ := strings.Cut(entry, "=")
		if !strings.EqualFold(key, readyPathEnv) && !strings.EqualFold(key, readyTokenEnv) {
			clean = append(clean, entry)
		}
	}
	return clean
}

// startVerified retains the old executable until this exact child has reported
// readiness and remained alive. On failure it reaps the child before rollback;
// if termination cannot be confirmed, the caller must preserve both binaries.
func startVerified(cmd *exec.Cmd, timeout, stable time.Duration) (safeToRestore bool, err error) {
	dir, err := os.MkdirTemp(filepath.Dir(cmd.Path), ".wb2api-ready-*")
	if err != nil {
		return true, err
	}
	defer os.RemoveAll(dir)
	path, token := filepath.Join(dir, "ready.json"), rand.Text()
	env := cmd.Env
	if env == nil {
		env = os.Environ()
	}
	cmd.Env = append(withoutReadinessEnv(env), readyPathEnv+"="+path, readyTokenEnv+"="+token)
	if err := cmd.Start(); err != nil {
		return true, err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	var readyAt time.Time
	for {
		select {
		case exitErr := <-done:
			return true, fmt.Errorf("新版本在启动验证期间退出: %v", exitErr)
		case <-deadline.C:
			_ = cmd.Process.Kill()
			select {
			case <-done:
				return true, errors.New("新版本未在期限内就绪，已停止并准备回滚")
			case <-time.After(5 * time.Second):
				return false, errors.New("无法确认新进程已退出，保留 .old 备份，未执行回滚")
			}
		case <-ticker.C:
			if readyAt.IsZero() {
				data, readErr := os.ReadFile(path)
				var receipt readyReceipt
				if readErr == nil && json.Unmarshal(data, &receipt) == nil && receipt.PID == cmd.Process.Pid && receipt.Token == token {
					readyAt = time.Now()
					deadline.Reset(stable + time.Second)
				}
			} else if time.Since(readyAt) >= stable {
				select {
				case exitErr := <-done:
					return true, fmt.Errorf("新版本就绪后退出: %v", exitErr)
				default:
					return false, nil
				}
			}
		}
	}
}
