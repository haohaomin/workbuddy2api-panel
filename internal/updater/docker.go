package updater

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"time"
)

// DockerClient talks only to the opt-in host agent over its mounted Unix socket.
// The agent owns the job, so replacing this container cannot cancel an update.
type DockerClient struct {
	client *http.Client
}

// NewDockerClient returns nil when Docker web updates have not been configured.
func NewDockerClient(socket string) *DockerClient {
	if socket == "" {
		return nil
	}
	return &DockerClient{client: &http.Client{
		Timeout: 3 * time.Second,
		Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", socket)
		}},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}
}

func (c *DockerClient) Request(ctx context.Context, action string) (Status, error) {
	method, path := http.MethodGet, "/status"
	switch action {
	case "status":
	case "check", "install":
		method, path = http.MethodPost, "/"+action
	default:
		return Status{}, fmt.Errorf("unsupported Docker update action")
	}
	req, err := http.NewRequestWithContext(ctx, method, "http://localhost"+path, nil)
	if err != nil {
		return Status{}, err
	}
	res, err := c.client.Do(req)
	if err != nil {
		return Status{}, fmt.Errorf("无法连接 Docker 更新服务，请检查宿主机服务及 socket 挂载: %w", err)
	}
	defer res.Body.Close()
	var result struct {
		Status
		Error string `json:"error"`
	}
	if err := json.NewDecoder(io.LimitReader(res.Body, 64<<10)).Decode(&result); err != nil {
		return Status{}, fmt.Errorf("Docker 更新服务响应无效: %w", err)
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return Status{}, fmt.Errorf("Docker 更新服务 (%d): %s", res.StatusCode, result.Error)
	}
	result.Status.Deployment = "docker_agent"
	result.Status.AutoEnabled, result.Status.AutoActive = false, false
	return result.Status, nil
}
