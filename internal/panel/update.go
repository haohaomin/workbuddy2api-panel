package panel

import (
	"context"
	"net/http"
	"time"

	"github.com/misakano7545/workbuddy2api-panel/internal/updater"
)

func (p *Panel) updateStatus(w http.ResponseWriter, r *http.Request) {
	if p.cfg.DockerUpdater != nil {
		writeJSON(w, http.StatusOK, p.dockerUpdateSnapshot(r.Context()))
		return
	}
	if p.cfg.Updater == nil {
		writeErr(w, http.StatusNotImplemented, "update api not available")
		return
	}
	writeJSON(w, http.StatusOK, p.cfg.Updater.Status())
}

func (p *Panel) checkUpdate(w http.ResponseWriter, r *http.Request) {
	if p.cfg.DockerUpdater != nil {
		p.dockerUpdateAction(w, r, "check")
		return
	}
	if p.cfg.Updater == nil {
		writeErr(w, http.StatusNotImplemented, "update api not available")
		return
	}
	if err := p.cfg.Updater.Check(r.Context()); err != nil {
		writeErr(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, p.cfg.Updater.Status())
}

func (p *Panel) installUpdate(w http.ResponseWriter, r *http.Request) {
	if p.cfg.DockerUpdater != nil {
		p.dockerUpdateAction(w, r, "install")
		return
	}
	if p.cfg.Updater == nil {
		writeErr(w, http.StatusNotImplemented, "update api not available")
		return
	}
	if err := p.cfg.Updater.Install(context.WithoutCancel(r.Context())); err != nil {
		writeErr(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]any{
		"ok":         true,
		"restarting": true,
		"status":     p.cfg.Updater.Status(),
	})
	p.cfg.Updater.RestartAfter(800 * time.Millisecond)
}

func (p *Panel) dockerUpdateSnapshot(ctx context.Context) updater.Status {
	s, err := p.cfg.DockerUpdater.Request(ctx, "status")
	s.CurrentVersion = p.cfg.Version
	s.Deployment = "docker_agent"
	s.InstallHint = "Docker 网页更新：检查时下载最新镜像，确认后重建本服务；启动失败尝试回滚。仅支持手动更新。"
	if err != nil {
		s.LastError, s.CanInstall = err.Error(), false
		s.Phase = "unavailable"
	}
	if p.apiKey() == "" {
		s.CanInstall = false
		s.InstallHint = "请先设置非空 API 密钥，再使用 Docker 网页更新。"
	}
	return s
}

func (p *Panel) dockerUpdateAction(w http.ResponseWriter, r *http.Request, action string) {
	// Unlike the ordinary panel, host operations must never allow anonymous use.
	if p.apiKey() == "" {
		writeErr(w, http.StatusForbidden, "Docker 网页更新需要先设置非空 API 密钥")
		return
	}
	s, err := p.cfg.DockerUpdater.Request(r.Context(), action)
	if err != nil {
		writeErr(w, http.StatusBadGateway, err.Error())
		return
	}
	s.CurrentVersion = p.cfg.Version
	if action == "install" {
		writeJSON(w, http.StatusAccepted, map[string]any{"ok": true, "restarting": true, "status": s})
	} else {
		writeJSON(w, http.StatusAccepted, s)
	}
}
