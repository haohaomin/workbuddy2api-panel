import http.client
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from agent import Agent, Handler, IMAGE, Server, image_tag

OLD = "sha256:" + "a" * 64
NEW = "sha256:" + "b" * 64
NEXT = "sha256:" + "c" * 64


class FakeAgent(Agent):
    """Docker boundary fake: run the real transaction and journal implementation."""
    def __init__(self, config):
        super().__init__(config)
        self.current = OLD
        self.remote = NEW
        self.calls = []
        self.managed_images = {}
        self.fail_image_removals = False
        self.fail_pull = False
        self.fail_ready = set()
        self.pull_gate = None

    def run(self, *args, timeout=120):
        self.calls.append(args)
        if args[:2] == ("image", "tag"):
            source, tag = args[2:]
            image_id = source if source.startswith("sha256:") else self.managed_images[source]
            self.managed_images[tag] = image_id
            return ""
        if args[:2] == ("image", "ls"):
            return "\n".join(json.dumps({
                "Repository": tag.rsplit(":", 1)[0], "Tag": tag.rsplit(":", 1)[1],
                "ID": image_id,
            }) for tag, image_id in sorted(self.managed_images.items()))
        if args[:2] == ("image", "rm"):
            if self.fail_image_removals:
                raise RuntimeError("模拟镜像清理失败")
            del self.managed_images[args[2]]
            return ""
        if args[0] == "pull":
            if self.pull_gate:
                self.pull_gate.wait(2)
            if self.fail_pull:
                raise RuntimeError("模拟拉取失败")
        if args[:2] == ("image", "inspect") and args[2:] == (IMAGE,):
            return json.dumps([{"Id": self.remote, "Config": {"Labels": {"io.workbuddy2api.version": "2026.10.28.1200"}}}])
        if args[0] == "compose":
            if "up" in args:
                override = json.loads(self.override.read_text())
                tag = override["services"][self.service]["image"]
                self.current = "sha256:" + tag.split(":", 1)[1]
            if "ps" in args:
                return "container-id"
        if args[0] == "inspect":
            return json.dumps([{
                "Id": "container-id", "Image": self.current, "RestartCount": 0,
                "State": {"Running": True, "StartedAt": "now"},
                "Config": {"Labels": {"com.docker.compose.project": self.project_name,
                                       "com.docker.compose.service": self.service}},
            }])
        return ""

    def wait_ready(self, image):
        if image in self.fail_ready:
            raise RuntimeError("模拟启动失败")


class AgentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "compose.yml").write_text("services: {}")
        self.config = {
            "project_directory": str(self.root), "project_name": "gateway",
            "compose_files": ["compose.yml"], "service": "workbuddy",
            "state_directory": str(self.root / "state"),
        }
        self.agent = FakeAgent(self.config)

    def tearDown(self):
        self.agent.lock_file.close()
        self.tmp.cleanup()

    def test_success_installs_checked_image_not_newer_remote(self):
        a = self.agent
        stale = "sha256:" + "d" * 64
        stale_tag = image_tag(stale)
        a.managed_images[stale_tag] = stale
        a.check()
        self.assertTrue(a.snapshot()["update_available"])
        self.assertEqual(a.snapshot()["latest_version"], "2026.10.28.1200")
        a.remote = NEXT
        a.install()
        self.assertEqual(a.current, NEW)
        self.assertEqual(a.snapshot()["phase"], "succeeded")
        self.assertFalse(a.state["_pending"])
        up = next(c for c in a.calls if "up" in c)
        self.assertIn("--no-deps", up)
        self.assertIn("--no-build", up)
        self.assertEqual(up[up.index("--pull") + 1], "never")
        self.assertEqual(up[-1], "workbuddy")
        self.assertIn(str(a.override), up)
        self.assertFalse(any(c[0] in ("stop", "rm", "system") or "down" in c for c in a.calls))
        self.assertEqual(json.loads(a.override.read_text())["services"]["workbuddy"]["image"], image_tag(NEW))
        self.assertNotIn(stale_tag, a.managed_images)
        self.assertIn(image_tag(OLD), a.managed_images)
        self.assertIn(image_tag(NEW), a.managed_images)
        self.assertEqual(a.snapshot()["backup_cleanup_removed"], 1)
        self.assertIn("上一版回滚镜像已保留", a.snapshot()["message"])
        self.assertNotIn("_old", a.snapshot())

    def test_cleanup_failure_does_not_roll_back_a_healthy_update(self):
        a = self.agent
        stale = "sha256:" + "d" * 64
        stale_tag = image_tag(stale)
        a.managed_images[stale_tag] = stale
        a.check()
        a.fail_image_removals = True
        a.install()
        self.assertEqual(a.current, NEW)
        self.assertEqual(a.snapshot()["phase"], "succeeded")
        self.assertFalse(a.state["_pending"])
        self.assertIn(stale_tag, a.managed_images)
        self.assertEqual(a.snapshot()["backup_cleanup_failures"], 1)
        self.assertIn("清理失败，仍保留", a.snapshot()["message"])

    def test_pull_failure_leaves_container_running_and_no_candidate(self):
        a = self.agent
        a.fail_pull = True
        with self.assertLogs(level="ERROR"):
            a.work("check")
        self.assertEqual(a.current, OLD)
        self.assertFalse(a.snapshot()["update_available"])
        self.assertFalse(a.snapshot()["checking"])
        self.assertEqual(a.snapshot()["phase"], "failed")
        self.assertFalse(any("up" in c for c in a.calls))

    def test_failed_start_rolls_back_pinned_old_image(self):
        a = self.agent
        stale = "sha256:" + "d" * 64
        stale_tag = image_tag(stale)
        a.managed_images[stale_tag] = stale
        a.check()
        a.fail_ready = {NEW}
        a.work("install")
        self.assertEqual(a.current, OLD)
        self.assertEqual(a.snapshot()["phase"], "rolled_back")
        self.assertIn("已回滚", a.snapshot()["last_error"])
        self.assertFalse(a.state["_pending"])
        self.assertTrue(a.snapshot()["can_install"])
        self.assertEqual(json.loads(a.override.read_text())["services"]["workbuddy"]["image"], image_tag(OLD))
        self.assertIn(stale_tag, a.managed_images)
        self.assertFalse(any(c[:2] == ("image", "rm") for c in a.calls))

    def test_failed_rollback_blocks_new_jobs_and_keeps_journal(self):
        a = self.agent
        a.check()
        a.fail_ready = {NEW, OLD}
        with self.assertLogs(level="ERROR"):
            a.work("install")
        self.assertEqual(a.snapshot()["phase"], "rollback_failed")
        self.assertTrue(a.state["_pending"])
        self.assertFalse(a.snapshot()["can_install"])
        with self.assertRaisesRegex(RuntimeError, "回滚尚未成功"):
            a.start("check")
        a.fail_ready.clear()
        a.recover()
        self.assertEqual(a.current, OLD)
        self.assertFalse(a.state["_pending"])

    def test_restart_recovers_transaction_from_disk(self):
        self.agent.check()
        self.agent.save(_old=OLD, _pending=True, installing=True, phase="verifying")
        self.agent.lock_file.close()
        self.agent = FakeAgent(self.config)
        self.agent.current = NEW
        self.agent.recover()
        self.assertEqual(self.agent.current, OLD)
        self.assertEqual(self.agent.snapshot()["phase"], "rolled_back")
        self.assertFalse(self.agent.snapshot()["installing"])

    def test_single_process_lock(self):
        with self.assertRaises(BlockingIOError):
            other = Agent(self.config)
            other.lock_file.close()

    def test_changed_container_requires_recheck(self):
        a = self.agent
        a.check()
        a.current = NEXT
        with self.assertRaisesRegex(RuntimeError, "重新检查"):
            a.install()
        self.assertEqual(a.current, NEXT)
        self.assertFalse(a.state["update_available"])
        self.assertFalse(any("up" in c for c in a.calls))

    def test_latest_image_same_as_current(self):
        self.agent.remote = OLD
        self.agent.check()
        self.assertFalse(self.agent.snapshot()["update_available"])
        with self.assertRaisesRegex(RuntimeError, "先检查"):
            self.agent.start("install")

    def test_concurrent_requests_do_not_start_duplicate_jobs(self):
        a = self.agent
        a.pull_gate = threading.Event()
        result = a.start("check")
        self.assertTrue(result["checking"])
        try:
            with self.assertRaisesRegex(RuntimeError, "正在进行"):
                a.start("check")
        finally:
            a.pull_gate.set()
            deadline = time.monotonic() + 3
            while a.busy and time.monotonic() < deadline:
                time.sleep(.01)
        self.assertFalse(a.busy)
        self.assertEqual(sum(c[0] == "pull" for c in a.calls), 1)

    def test_ready_requires_continuous_identity_and_correct_image(self):
        a = self.agent
        clock = [0]
        a.current = NEW
        calls = []

        def probe(_):
            calls.append(clock[0])
            if clock[0] == 4:
                raise RuntimeError("connection reset")

        with patch("agent.time.monotonic", side_effect=lambda: clock[0]), patch("agent.time.sleep", side_effect=lambda n: clock.__setitem__(0, clock[0] + n)), patch.object(a, "probe", side_effect=probe):
            Agent.wait_ready(a, NEW)
        self.assertGreaterEqual(clock[0], 14, "failed probe must reset the stability window")

    def test_compose_recreate_error_also_rolls_back(self):
        a = self.agent
        a.check()
        original = a.recreate

        def recreate(image):
            if image == NEW:
                raise RuntimeError("模拟 Compose 创建失败")
            original(image)

        with patch.object(a, "recreate", side_effect=recreate):
            a.work("install")
        self.assertEqual(a.current, OLD)
        self.assertEqual(a.snapshot()["phase"], "rolled_back")

    def test_probe_accepts_empty_pool_but_rejects_wrong_service(self):
        from subprocess import run

        class Health(BaseHTTPRequestHandler):
            identity = "workbuddy2api"

            def do_GET(handler):
                handler.send_response(503)
                handler.send_header("X-Service", handler.identity)
                handler.end_headers()
                handler.wfile.write(json.dumps({"service": handler.identity, "healthy": 0, "total": 0}).encode())

            def log_message(self, *_):
                pass

        with ThreadingHTTPServer(("127.0.0.1", 0), Health) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            self.agent.port = server.server_port

            def execute_probe(*args, **_):
                result = run([sys.executable, "-c", args[-1]], capture_output=True)
                if result.returncode:
                    raise RuntimeError("probe rejected response")

            try:
                with patch.object(self.agent, "run", side_effect=execute_probe):
                    self.agent.probe({"Id": "test"})
                    Health.identity = "another-service"
                    with self.assertRaises(RuntimeError):
                        self.agent.probe({"Id": "test"})
            finally:
                server.shutdown()
                thread.join(2)

    def test_command_timeout_kills_children_before_rollback(self):
        docker = self.root / "docker"
        marker = self.root / "late-mutation"
        child = f"import time,pathlib; time.sleep(.4); pathlib.Path({str(marker)!r}).touch()"
        docker.write_text(f"#!{sys.executable}\nimport subprocess,time,sys\nsubprocess.Popen([sys.executable, '-c', {child!r}])\ntime.sleep(10)\n")
        docker.chmod(0o700)
        with patch.dict(os.environ, {"PATH": str(self.root) + os.pathsep + os.environ.get("PATH", "")}):
            with self.assertRaisesRegex(RuntimeError, "超时"):
                Agent.run(self.agent, "compose", "up", timeout=.1)
        time.sleep(.5)
        self.assertFalse(marker.exists(), "timed-out Compose child must not mutate after rollback starts")

    def test_http_rejects_parameters_and_unknown_actions(self):
        path = str(self.root / "agent.sock")
        with Server(path, Handler) as server:
            server.agent = self.agent
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                for method, route, body, expected in [
                    ("GET", "/status", None, 200),
                    ("POST", "/install", None, 409),
                    ("POST", "/install?image=evil", None, 404),
                    ("POST", "/check", '{"command":"id"}', 400),
                    ("POST", "/exec", None, 404),
                ]:
                    conn = http.client.HTTPConnection("localhost")
                    conn.sock = socket.socket(socket.AF_UNIX)
                    conn.sock.connect(path)
                    conn.request(method, route, body)
                    res = conn.getresponse()
                    self.assertEqual(res.status, expected)
                    data = json.loads(res.read())
                    self.assertNotIn("_target", data)
                    conn.close()
            finally:
                server.shutdown()
                thread.join(2)


if __name__ == "__main__":
    unittest.main()
