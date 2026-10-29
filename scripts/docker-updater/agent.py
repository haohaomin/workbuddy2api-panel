#!/usr/bin/env python3
"""Opt-in Linux host updater. Python 3.9+, Docker Compose v2, no pip packages.

Only fixed, administrator-configured Compose commands are exposed over a Unix
socket. The application never receives the Docker socket or host command input.
"""
import argparse
import fcntl
import json
import logging
import os
from pathlib import Path
import re
import signal
import socketserver
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler

IMAGE = "ghcr.io/haohaomin/workbuddy2api-panel:latest"
HINT = "Docker 网页更新：检查时下载最新镜像，确认后重建本服务；启动失败尝试回滚。仅支持手动更新。"


def atomic_json(path, value):
    tmp = path.with_suffix(".tmp")
    with tmp.open("w") as stream:
        json.dump(value, stream, ensure_ascii=False)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(tmp, path)
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def image_tag(image_id):
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", image_id):
        raise RuntimeError("Docker 返回的镜像 ID 无效")
    return "workbuddy2api-managed:" + image_id[7:]


class Agent:
    def __init__(self, config):
        self.config = config
        self.project = Path(config["project_directory"]).resolve(strict=True)
        self.service = config["service"]
        self.project_name = config["project_name"]
        for value in (self.service, self.project_name):
            if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", value):
                raise ValueError("service / project_name 必须是合法 Compose 名称")
        self.files = [(self.project / f).resolve(strict=True) for f in config["compose_files"]]
        if not self.files:
            raise ValueError("compose_files 不得为空")
        self.state_dir = Path(config.get("state_directory", "/var/lib/workbuddy-updater"))
        self.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        # Held for the lifetime of the process; protects startup recovery as well.
        self.lock_file = (self.state_dir / "agent.lock").open("a")
        try:
            fcntl.flock(self.lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.lock_file.close()
            raise
        self.journal = self.state_dir / "state.json"
        self.override = self.state_dir / "image.json"
        self.mu = threading.RLock()
        self.busy = False
        self.state = {
            "deployment": "docker_agent", "can_install": True,
            "auto_enabled": False, "auto_active": False,
            "install_hint": HINT, "phase": "idle", "message": "尚未检查 Docker 镜像",
            "checking": False, "installing": False, "update_available": False,
            "latest_version": "", "latest_image": "", "last_error": "",
        }
        if self.journal.exists():
            self.state.update(json.loads(self.journal.read_text()))
        self.port = int(config.get("container_port", 7863))
        if not 1 <= self.port <= 65535:
            raise ValueError("container_port 必须为有效端口")
        self.ready_timeout = max(10, int(config.get("ready_timeout", 90)))

    def run(self, *args, timeout=120):
        # Never log docker output: compose errors may contain interpolated secrets.
        with subprocess.Popen(
                ["docker", *args], cwd=self.project, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                start_new_session=True) as process:
            try:
                stdout, _ = process.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
                raise RuntimeError("Docker 命令超时，请检查 Docker 服务、网络和磁盘") from None
            if process.returncode:
                raise RuntimeError("Docker 命令失败（退出码 %d），请在宿主机检查镜像拉取 / Compose 配置 / 容器日志" % process.returncode)
            return stdout.strip()

    def compose(self, *args, pinned=False):
        command = ["compose", "--project-directory", str(self.project), "-p", self.project_name]
        for path in self.files:
            command += ["-f", str(path)]
        if pinned:
            command += ["-f", str(self.override)]
        return self.run(*command, *args)

    def container(self):
        ids = self.compose("ps", "-a", "-q", self.service).splitlines()
        if len(ids) != 1:
            raise RuntimeError("更新仅支持已启动的单实例 Compose 服务，请核对项目名称、服务名和 Compose 文件")
        data = json.loads(self.run("inspect", ids[0]))[0]
        labels = data["Config"].get("Labels") or {}
        if labels.get("com.docker.compose.project") != self.project_name or labels.get("com.docker.compose.service") != self.service:
            raise RuntimeError("容器身份与配置不符")
        return data

    def snapshot(self):
        with self.mu:
            return {k: v for k, v in self.state.items() if not k.startswith("_")}

    def save(self, **values):
        with self.mu:
            updated = {**self.state, **values}
            atomic_json(self.journal, updated)
            self.state = updated

    def start(self, action):
        with self.mu:
            if self.busy:
                raise RuntimeError("已有检查或更新任务正在进行")
            if self.state.get("_pending"):
                raise RuntimeError("上次回滚尚未成功，请先在宿主机恢复服务并重启更新服务")
            if action == "install" and not self.state.get("update_available"):
                raise RuntimeError("请先检查更新并下载新镜像")
            self.save(checking=action == "check", installing=action == "install",
                      phase="pulling" if action == "check" else "preparing",
                      message="正在下载并检查最新镜像…" if action == "check" else "正在准备替换容器…",
                      last_error="")
            if action == "check":
                self.save(update_available=False)
            self.busy = True
            threading.Thread(target=self.work, args=(action,), daemon=True).start()
            return self.snapshot()

    def work(self, action):
        try:
            if action == "check":
                self.check()
            else:
                self.install()
        except Exception as exc:
            logging.exception("Docker update %s failed", action)
            # An incomplete transaction stays in the journal for restart recovery.
            self.save(phase="rollback_failed" if self.state.get("_pending") else "failed",
                      message="更新操作失败", last_error=str(exc))
        finally:
            with self.mu:
                self.save(checking=False, installing=False,
                          can_install=not bool(self.state.get("_pending")))
                self.busy = False

    def check(self):
        current = self.container()
        if not current["State"]["Running"]:
            raise RuntimeError("当前容器未运行，请先恢复服务")
        self.probe(current)
        # Tag the old image before moving latest, protecting it from dangling-image cleanup.
        self.run("image", "tag", current["Image"], image_tag(current["Image"]))
        self.run("pull", IMAGE, timeout=900)
        target = json.loads(self.run("image", "inspect", IMAGE))[0]
        target_id = target["Id"]
        self.run("image", "tag", target_id, image_tag(target_id))
        # Re-read: an administrator may have changed the container during the pull.
        current = self.container()
        available = current["Image"] != target_id
        version = (target["Config"].get("Labels") or {}).get("io.workbuddy2api.version", "")
        self.save(_target=target_id, _base=current["Image"],
                  current_image=current["Image"], latest_image=target_id,
                  latest_version=version, update_available=available,
                  checked_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                  phase="ready" if available else "current",
                  message="新镜像已下载，点击立即更新后才会重建容器" if available else "当前容器已使用最新镜像")

    def pin(self, image_id):
        tag = image_tag(image_id)
        self.run("image", "tag", image_id, tag)
        atomic_json(self.override, {"services": {self.service: {"image": tag, "pull_policy": "never"}}})

    def recreate(self, image_id):
        self.pin(image_id)
        self.compose("up", "-d", "--no-deps", "--no-build", "--pull", "never",
                     "--force-recreate", self.service, pinned=True)

    def probe(self, container):
        # /healthz 503 is valid when no account is available. Require the application
        # identity and JSON shape; do not confuse account availability with startup.
        code = (
            "import http.client,json,sys; "
            f"c=http.client.HTTPConnection('127.0.0.1',{self.port},timeout=3); "
            "c.request('GET','/healthz'); r=c.getresponse(); d=json.loads(r.read(65536)); "
            "sys.exit(0 if r.status in (200,503) and r.getheader('X-Service')=='workbuddy2api' "
            "and d.get('service')=='workbuddy2api' and 'healthy' in d and 'total' in d else 1)"
        )
        self.run("exec", container["Id"], "python3", "-c", code, timeout=6)

    def wait_ready(self, image_id):
        deadline, stable_since, identity = time.monotonic() + self.ready_timeout, None, None
        while time.monotonic() < deadline:
            try:
                c = self.container()
                if c["Image"] != image_id or not c["State"]["Running"]:
                    raise RuntimeError("容器尚未就绪")
                self.probe(c)
                current_identity = (c["Id"], c.get("RestartCount"), c["State"].get("StartedAt"))
                if stable_since is None or current_identity != identity:
                    stable_since, identity = time.monotonic(), current_identity
                if time.monotonic() - stable_since >= 8:
                    return
            except (RuntimeError, ValueError, KeyError):
                stable_since = None
            time.sleep(2)
        raise RuntimeError("新容器未在期限内通过启动检查")

    def install(self):
        current = self.container()
        target = self.state["_target"]
        if current["Image"] != self.state["_base"]:
            self.save(update_available=False)
            raise RuntimeError("检查后容器已被其他操作更新，请重新检查")
        # Verify both local images and Compose configuration before touching the service.
        self.run("image", "inspect", current["Image"], target)
        self.compose("config", "--quiet")
        self.run("image", "tag", current["Image"], image_tag(current["Image"]))
        self.save(_old=current["Image"], _pending=True, phase="recreating",
                  message="正在重建容器，网页可能短暂断开…")
        try:
            self.recreate(target)
            self.save(phase="verifying", message="新容器已启动，正在验证稳定性…")
            self.wait_ready(target)
        except Exception as exc:
            self.rollback(str(exc))
            return
        self.save(_pending=False, phase="succeeded", message="更新成功，已通过启动检查",
                  current_image=target, update_available=False, last_error="")

    def rollback(self, reason):
        self.save(phase="rolling_back", message="启动检查失败，正在恢复旧镜像…", installing=True)
        try:
            self.recreate(self.state["_old"])
            self.wait_ready(self.state["_old"])
        except Exception as exc:
            self.save(phase="rollback_failed", can_install=False,
                      last_error=f"{reason}；回滚未成功：{exc}。请按部署文档手动恢复。")
            raise RuntimeError(self.state["last_error"]) from exc
        self.save(_pending=False, phase="rolled_back", message="已恢复旧镜像并通过启动检查",
                  current_image=self.state["_old"], last_error=reason + "；已回滚到旧镜像")

    def recover(self):
        # On a host/agent restart, never silently abandon a half-finished replacement.
        if self.state.get("_pending"):
            try:
                self.rollback("更新服务曾中断")
            except Exception:
                logging.exception("Startup rollback failed")
        elif self.state.get("checking") or self.state.get("installing"):
            self.save(phase="failed", last_error="上次操作中断，请重新检查更新")
        self.save(checking=False, installing=False, can_install=not bool(self.state.get("_pending")))


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def log_message(self, *_):
        pass

    def reply(self, status, value):
        data = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path != "/status":
            self.reply(404, {"error": "unknown action"})
            return
        self.reply(200, self.server.agent.snapshot())

    def do_POST(self):
        # No request parameters, paths, images, scripts or commands are accepted.
        if self.headers.get("Transfer-Encoding") or self.headers.get("Content-Length", "0") != "0":
            self.reply(400, {"error": "request body is not allowed"})
            return
        if self.path not in ("/check", "/install"):
            self.reply(404, {"error": "unknown action"})
            return
        try:
            self.reply(202, self.server.agent.start(self.path[1:]))
        except RuntimeError as exc:
            self.reply(409, {"error": str(exc)})


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="/etc/workbuddy-updater.json")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO)
    os.umask(0o077)
    agent = Agent(json.loads(Path(args.config).read_text()))
    agent.recover()
    socket = Path(agent.config.get("socket", "/run/workbuddy-updater/agent.sock"))
    socket.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(socket.parent, 0o755)
    socket.unlink(missing_ok=True)
    with Server(str(socket), Handler) as server:
        server.agent = agent
        os.chown(socket, 0, int(agent.config.get("socket_gid", 10001)))
        os.chmod(socket, 0o660)
        logging.info("Docker updater ready for %s/%s", agent.project_name, agent.service)
        server.serve_forever()


if __name__ == "__main__":
    main()
