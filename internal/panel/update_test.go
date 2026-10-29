package panel

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/misakano7545/workbuddy2api-panel/internal/updater"
)

func TestUpdateAPIRequiresAuthentication(t *testing.T) {
	for _, endpoint := range []struct{ method, path string }{
		{http.MethodGet, "/panel/api/update"},
		{http.MethodPost, "/panel/api/update/check"},
		{http.MethodPost, "/panel/api/update/install"},
	} {
		p := newTestPanel()
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(endpoint.method, endpoint.path, nil)
		p.ServeHTTP(rec, req)
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s: got %d", endpoint.path, rec.Code)
		}
		req.Header.Set("Authorization", "Bearer test-key")
		rec = httptest.NewRecorder()
		p.ServeHTTP(rec, req)
		if rec.Code != http.StatusNotImplemented {
			t.Errorf("unconfigured %s: got %d", endpoint.path, rec.Code)
		}
	}
}

func TestUpdateStatusAndUnsupportedInstall(t *testing.T) {
	p := New(Config{APIKey: "test-key", Updater: updater.New("dev", "", "", updater.Settings{AutoEnabled: true, AutoTime: "06:30"})})
	req := httptest.NewRequest(http.MethodGet, "/panel/api/update", nil)
	req.Header.Set("Authorization", "Bearer test-key")
	rec := httptest.NewRecorder()
	p.ServeHTTP(rec, req)
	var status updater.Status
	if err := json.Unmarshal(rec.Body.Bytes(), &status); err != nil {
		t.Fatal(err)
	}
	if rec.Code != http.StatusOK || status.CurrentVersion != "dev" || status.CanInstall || !status.AutoEnabled || status.AutoTime != "06:30" {
		t.Fatalf("unexpected status: %d %+v", rec.Code, status)
	}
	req = httptest.NewRequest(http.MethodPost, "/panel/api/update/install", nil)
	req.Header.Set("Authorization", "Bearer test-key")
	rec = httptest.NewRecorder()
	p.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadGateway || p.cfg.Updater.Status().Installing {
		t.Fatalf("dev install must fail without pending state: %d %s", rec.Code, rec.Body.String())
	}
}

func TestUpdateFrontendStates(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node unavailable")
	}
	script := `
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const src = fs.readFileSync(process.argv[2], 'utf8');
const nodes = new Map();
const timers = new Map();
let timerID = 0;
let response, fail = false, navigated;
const ctx = {
  $: id => { if (!nodes.has(id)) nodes.set(id, {textContent:'', scrollIntoView(){}}); return nodes.get(id); },
  api: async () => { if(fail) throw Error('offline'); return response; },
  toast(){}, confirm: () => true, go: v => { navigated = v; },
  AbortController,
  setTimeout: (fn, delay) => { timers.set(++timerID, {fn, delay}); return timerID; },
  clearTimeout: id => timers.delete(id)
};
vm.createContext(ctx);
vm.runInContext('let updateData = null, updateBusy = false;\n' +
  src.slice(src.indexOf('function displayVersion('), src.indexOf('async function loadOverview(')), ctx);
vm.runInContext(src.slice(src.indexOf('const CFG_MAP ='), src.indexOf('/* Go 时长字段即时校验')), ctx);
(async () => {
  assert.equal(ctx.displayVersion('dev'), 'dev');
  assert.equal(ctx.displayVersion('v2026.10.23.1859'), 'v2026.10.23.1859');
  response = {current_version:'2026.10.22.1823', latest_version:'2026.10.23.1859', update_available:true, can_install:true};
  await ctx.checkForUpdates();
  assert.equal(nodes.get('btnUpdateInstall').disabled, false, 'install re-enabled after checking');
  nodes.get('navUpdate').onclick();
  assert.equal(navigated, 'config');
  fail = true;
  await ctx.checkForUpdates();
  assert.equal(nodes.get('btnUpdateCheck').disabled, false, 'retry after network error');
  assert.equal(nodes.get('btnUpdateInstall').disabled, false);
  fail = false;
  ctx.renderUpdateStatus({...response, last_error:'checksum mismatch'});
  assert(nodes.get('updateNote').textContent.includes('checksum mismatch'));
  ctx.renderUpdateStatus({...response, can_install:false, install_hint:'请在桌面窗口更新'});
  assert.equal(nodes.get('updateAutoEnabled').disabled, true);
  assert.equal(nodes.get('updateAutoTime').disabled, true);
  assert.equal(nodes.get('updateInstallHint').textContent, '请在桌面窗口更新');
  ctx.$('cfgForm').elements = {
    update_auto_enabled: Object.assign(nodes.get('updateAutoEnabled'), {type:'checkbox', checked:true}),
    update_auto_time: Object.assign(nodes.get('updateAutoTime'), {type:'time', value:'04:00'})
  };
  assert.strictEqual(ctx.collectConfig().update, undefined, 'saving unrelated settings preserves unsupported update config');
  ctx.renderUpdateStatus({...response, can_install:true});
  assert.equal(nodes.get('updateAutoEnabled').disabled, false);
  assert.equal(ctx.collectConfig().update.auto_enabled, true, 'supported deployment saves schedule');
  nodes.get('updateAutoEnabled').dataset = {environmentManaged:'true'};
  ctx.renderUpdateCapabilities();
  assert.equal(nodes.get('updateAutoEnabled').disabled, true);
  ctx.renderUpdateStatus({...response, can_install:false});
  assert.equal(nodes.get('btnUpdateInstall').hidden, true, 'unsupported platform hides install');
  response = {status:{...response, installing:true}};
  ctx.renderUpdateStatus(response.status);
  assert.equal(nodes.get('btnUpdateInstall').disabled, true);
  assert.equal(nodes.get('btnUpdateCheck').disabled, true);
  response = {deployment:'docker_agent', current_version:'dev', can_install:true, checking:true, message:'正在下载镜像'};
  ctx.renderUpdateStatus(response);
  assert.equal(nodes.get('updateNote').textContent, '正在下载镜像');
  assert.equal(nodes.get('btnUpdateCheck').disabled, true);
  assert.equal(nodes.get('updateAutoTime').disabled, true, 'Docker never enables the native daily schedule');
  assert.strictEqual(ctx.collectConfig().update, undefined);
  ctx.renderUpdateStatus({...response, checking:false, phase:'rolled_back', last_error:'启动失败；已回滚到旧镜像'});
  assert(nodes.get('updateNote').textContent.includes('已回滚'));
  assert.equal(nodes.get('btnUpdateCheck').disabled, false);
  assert.equal(ctx.updateTarget({deployment:'docker_agent', latest_image:'sha256:abcdef1234567890'}), '镜像 abcdef123456');
  assert.equal(timers.size, 1, 'overview renders must not duplicate the Docker polling loop');
  const tick = async () => {
    const [id, timer] = [...timers.entries()].find(([,t]) => t.delay === 3000);
    timers.delete(id);
    await timer.fn();
  };
  response = {...response, checking:false, installing:true};
  ctx.renderUpdateStatus(response);
  fail = true;
  await tick();
  assert(nodes.get('updateNote').textContent.includes('重连'));
  assert.equal(timers.size, 1, 'transient disconnect keeps polling');
  fail = false;
  response = {...response, installing:false, phase:'unavailable', can_install:false};
  await tick();
  assert.equal(timers.size, 1, 'agent reconnect continues even with overview refresh disabled');
  response = {...response, phase:'succeeded', message:'更新成功'};
  await tick();
  assert.equal(timers.size, 0, 'finished jobs stop the polling loop');
})().catch(e => { console.error(e); process.exitCode = 1; });
`
	path := filepath.Join(t.TempDir(), "update.cjs")
	if err := os.WriteFile(path, []byte(script), 0600); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command(node, path, "app.js").CombinedOutput(); err != nil {
		t.Fatalf("node: %v\n%s", err, out)
	}
}

func TestDockerUpdateAPI(t *testing.T) {
	// Short path: macOS Unix sockets have a small path limit.
	dir, err := os.MkdirTemp("", "wb-agent-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	socket := filepath.Join(dir, "s")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	calls := make(chan string, 10)
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls <- r.Method + " " + r.URL.Path
		writeJSON(w, http.StatusAccepted, updater.Status{CanInstall: true, Installing: r.URL.Path == "/install", Checking: r.URL.Path == "/check"})
	})}
	go server.Serve(listener)
	defer server.Close()
	p := New(Config{Version: "dev", APIKey: "test-key", DockerUpdater: updater.NewDockerClient(socket)})
	for _, action := range []string{"check", "install"} {
		for _, key := range []string{"", "wrong", "test-key"} {
			req := httptest.NewRequest(http.MethodPost, "/panel/api/update/"+action, nil)
			req.Header.Set("Authorization", "Bearer "+key)
			rec := httptest.NewRecorder()
			p.ServeHTTP(rec, req)
			if key != "test-key" {
				if rec.Code != http.StatusUnauthorized {
					t.Fatalf("anonymous: %d", rec.Code)
				}
				select {
				case call := <-calls:
					t.Fatalf("unauthorized call: %s", call)
				default:
				}
			} else {
				if rec.Code != http.StatusAccepted {
					t.Fatalf("%s: %d %s", action, rec.Code, rec.Body.String())
				}
				if call := <-calls; call != "POST /"+action {
					t.Fatalf("wrong call: %s", call)
				}
			}
		}
	}
	p.cfg.APIKey = ""
	rec := httptest.NewRecorder()
	p.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/panel/api/update/install", nil))
	if rec.Code != http.StatusForbidden {
		t.Fatalf("unconfigured key: %d", rec.Code)
	}
	s := p.dockerUpdateSnapshot(context.Background())
	if s.CanInstall || s.AutoActive || s.Deployment != "docker_agent" {
		t.Fatalf("bad status: %+v", s)
	}
	<-calls
	p.cfg.APIKey = "test-key"
	server.Close()
	s = p.dockerUpdateSnapshot(context.Background())
	if s.CanInstall || s.LastError == "" || s.Phase != "unavailable" {
		t.Fatalf("offline: %+v", s)
	}
}
