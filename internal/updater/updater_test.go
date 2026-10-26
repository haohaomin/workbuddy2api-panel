package updater

import (
	"archive/zip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestParseVersion(t *testing.T) {
	tests := []struct {
		tag  string
		want string
		ok   bool
	}{
		{"v2026.9.26.711", "2026.9.26.711", true},
		{"2026.10.23.1859", "2026.10.23.1859", true},
		{"v2026.09.26.0711", "", false},
		{"v2026.9.26.0711", "", false},
		{"v1.2.3", "", false},
		{"v2026.2.29.1200", "", false},
		{"v2026.10.24.2460", "", false},
		{"v999999999999.10.24.1200", "", false},
		{"v2026.10.24.-10", "", false},
	}
	for _, tt := range tests {
		got, ok := parseVersion(tt.tag)
		if ok != tt.ok || got.text != tt.want {
			t.Errorf("parseVersion(%q) = (%+v, %v), want text=%q ok=%v", tt.tag, got, ok, tt.want, tt.ok)
		}
	}
}

func TestCheckUsesLatestWhenManifestMissing(t *testing.T) {
	body := `{"tag_name":"v2026.10.23.1859","html_url":"https://github.com/another/project/releases/tag/v2026.10.23.1859","body":"notes","draft":false,"prerelease":false}`
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/update.json") {
			http.NotFound(w, r)
			return
		}
		if r.URL.Path != "/repos/example/project/releases/latest" {
			t.Errorf("unexpected request path %s", r.URL.Path)
		}
		_, _ = w.Write([]byte(body))
	}))
	defer server.Close()
	m := New("2026.10.22.1823", "example/project", "", Settings{})
	m.apiBaseURL, m.manifestBaseURL = server.URL, server.URL
	if err := m.Check(context.Background()); err != nil {
		t.Fatal(err)
	}
	got := m.Status()
	if !got.UpdateAvailable || got.LatestVersion != "2026.10.23.1859" || got.ReleaseNotes != "notes" ||
		got.ReleaseURL != "https://github.com/example/project/releases/tag/v2026.10.23.1859" {
		t.Fatalf("unexpected status: %+v", got)
	}
}

func TestManifestSelectionAndFailure(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		status     int
		wantErr    bool
	}{
		{"valid", `{"schema":1,"release":{"tag_name":"v2026.10.23.1859"}}`, 200, false},
		{"draft", `{"schema":1,"release":{"tag_name":"v2026.10.23.1859","draft":true}}`, 200, true},
		{"prerelease", `{"schema":1,"release":{"tag_name":"v2026.10.23.1859","prerelease":true}}`, 200, true},
		{"schema", `{"schema":2}`, 200, true},
		{"invalid", `broken`, 200, true},
		{"unavailable", `busy`, 503, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				if !strings.HasSuffix(r.URL.Path, "/update.json") {
					t.Error("unexpected API fallback")
				}
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer server.Close()
			m := New("2026.10.22.1823", "example/project", "", Settings{})
			m.apiBaseURL, m.manifestBaseURL = server.URL, server.URL
			if err := m.Check(context.Background()); (err != nil) != tc.wantErr {
				t.Fatalf("check: %v", err)
			}
			if calls != 1 {
				t.Fatalf("calls=%d", calls)
			}
		})
	}
}

func TestCheckReportsReleaseAPIError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "rate limited", http.StatusForbidden)
	}))
	defer server.Close()
	m := New("2026.10.22.1823", "example/project", "", Settings{})
	m.apiBaseURL, m.manifestBaseURL = server.URL, server.URL
	if err := m.Check(context.Background()); err == nil {
		t.Fatal("expected API error")
	}
	got := m.Status()
	if got.LastError == "" || got.CheckedAt == "" {
		t.Fatalf("error status not recorded: %+v", got)
	}
}

func TestVerifySHA256(t *testing.T) {
	path := filepath.Join(t.TempDir(), "asset.zip")
	content := []byte("release archive")
	if err := os.WriteFile(path, content, 0600); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(content)
	if err := verifySHA256(path, hex.EncodeToString(sum[:])); err != nil {
		t.Fatal(err)
	}
	if err := verifySHA256(path, "wrong"); err == nil {
		t.Fatal("expected mismatch")
	}
}

func TestExtractBinaryRequiresExactRegularFile(t *testing.T) {
	dir := t.TempDir()
	archivePath := filepath.Join(dir, "release.zip")
	f, err := os.Create(archivePath)
	if err != nil {
		t.Fatal(err)
	}
	zw := zip.NewWriter(f)
	entry, err := zw.Create("wb2api")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := entry.Write([]byte("binary")); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	stage := filepath.Join(dir, "stage")
	if err := os.WriteFile(stage, nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := extractBinary(archivePath, stage, "wb2api"); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(stage)
	if err != nil || string(got) != "binary" {
		t.Fatalf("stage=%q err=%v", got, err)
	}
	if err := extractBinary(archivePath, stage, "../wb2api"); err == nil {
		t.Fatal("expected exact name match")
	}
}

func TestAssetDigestMustBeSHA256(t *testing.T) {
	asset := releaseAsset{Name: "wb2api-panel-2026.10.23.1859-windows-amd64.zip", Size: 20, Digest: "sha512:" + fmt.Sprintf("%0128x", 1)}
	if hasSHA256Digest(asset.Digest) {
		t.Fatal("sha512 digest unexpectedly accepted")
	}
}

func TestTrustedGitHubURL(t *testing.T) {
	tests := []struct {
		raw     string
		initial bool
		want    bool
	}{
		{"https://github.com/misakano7545/workbuddy2api-panel/releases/download/v1/file.zip", true, true},
		{"https://objects.githubusercontent.com/github-production-release-asset/file.zip", false, true},
		{"https://release-assets.githubusercontent.com/file.zip", false, true},
		{"https://github.com.evil.example/file.zip", false, false},
		{"https://github.com:444/file.zip", false, false},
		{"https://user:pass@github.com/file.zip", false, false},
		{"http://github.com/file.zip", false, false},
	}
	for _, tt := range tests {
		u, err := url.Parse(tt.raw)
		if err != nil {
			t.Fatalf("parse %q: %v", tt.raw, err)
		}
		if got := isTrustedGitHubURL(u, tt.initial); got != tt.want {
			t.Errorf("isTrustedGitHubURL(%q, %v)=%v want %v", tt.raw, tt.initial, got, tt.want)
		}
	}
}

func TestReplaceBinary(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "wb2api")
	stage := filepath.Join(dir, "stage")
	if err := os.WriteFile(target, []byte("old"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(stage, []byte("new"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := replaceBinary(stage, target); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(target)
	if err != nil || string(got) != "new" {
		t.Fatalf("target=%q err=%v", got, err)
	}
	if _, err := os.Stat(target + ".old"); !os.IsNotExist(err) {
		t.Fatalf("backup should be removed, stat err=%v", err)
	}
}

func TestReplaceBinaryRestoresOnFailure(t *testing.T) {
	target := filepath.Join(t.TempDir(), "wb2api")
	if err := os.WriteFile(target, []byte("old"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, _, err := replaceBinaryWithRollback(target+".missing", target); err == nil {
		t.Fatal("expected missing stage error")
	}
	got, err := os.ReadFile(target)
	if err != nil || string(got) != "old" {
		t.Fatalf("old target not restored: target=%q err=%v", got, err)
	}
}

func TestReplaceBinaryRollbackAfterInstall(t *testing.T) {
	dir := t.TempDir()
	target, stage := filepath.Join(dir, "wb2api"), filepath.Join(dir, "stage")
	for path, data := range map[string]string{target: "old", stage: "new"} {
		if err := os.WriteFile(path, []byte(data), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	restore, _, err := replaceBinaryWithRollback(stage, target)
	if err != nil {
		t.Fatal(err)
	}
	restore()
	restore()
	got, err := os.ReadFile(target)
	if err != nil || string(got) != "old" {
		t.Fatalf("rollback target=%q err=%v", got, err)
	}
}

func TestInstallRejectsAlreadyPendingUpdate(t *testing.T) {
	m := New("dev", "", "", Settings{})
	m.status.Installing = true
	if err := m.Install(context.Background()); err == nil {
		t.Fatal("pending installation must not allow another helper")
	}
	if !m.Status().Installing {
		t.Fatal("duplicate request must preserve pending state")
	}
}

func TestScheduleUsesShanghaiAndRunsOncePerDay(t *testing.T) {
	m := New("dev", "", "", Settings{AutoEnabled: true, AutoTime: "04:00"})
	m.status.CanInstall = true // Exercise the scheduler independent of the test host.
	now := time.Date(2026, 10, 23, 20, 0, 15, 0, time.UTC)
	auto, regular := m.scheduleDue(now)
	if !auto || !regular {
		t.Fatalf("startup schedule: auto=%v regular=%v", auto, regular)
	}
	m.lastCheck = now
	auto, regular = m.scheduleDue(now.Add(10 * time.Second))
	if auto || regular {
		t.Fatal("duplicate schedule within the same day")
	}
	auto, regular = m.scheduleDue(now.Add(24 * time.Hour))
	if !auto || !regular {
		t.Fatal("next day must be due")
	}
	m.Configure(Settings{AutoEnabled: false, AutoTime: "05:00"})
	if auto, _ := m.scheduleDue(now.Add(49 * time.Hour)); auto {
		t.Fatal("disabled schedule ran")
	}
	if got := m.Status(); got.AutoEnabled || got.AutoTime != "05:00" {
		t.Fatalf("hot settings not exposed: %+v", got)
	}
}

func TestDownloadRejectsExternalRedirectAndWrongSize(t *testing.T) {
	m := New("dev", "", "", Settings{})
	requests := 0
	m.client.Transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		requests++
		return &http.Response{
			StatusCode: http.StatusFound, Header: http.Header{"Location": {"https://evil.example/asset.zip"}},
			Body: io.NopCloser(strings.NewReader("")), Request: r,
		}, nil
	})
	asset := &releaseAsset{BrowserDownloadURL: "https://github.com/example/asset.zip"}
	if err := m.downloadAsset(context.Background(), asset, io.Discard); err == nil || requests != 1 {
		t.Fatalf("external redirect followed: requests=%d err=%v", requests, err)
	}
	m.client.Transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader("short")), Header: make(http.Header)}, nil
	})
	asset.Size = 20
	if err := m.downloadAsset(context.Background(), asset, io.Discard); err == nil {
		t.Fatal("truncated download accepted")
	}
	if hasSHA256Digest("sha256:" + strings.Repeat("z", 64)) {
		t.Fatal("non-hex digest accepted")
	}
}

func TestDeploymentCapabilities(t *testing.T) {
	for _, tc := range []struct {
		os, arch, version, exe string
		container, managed     bool
		want                   string
	}{
		{"darwin", "arm64", "2026.10.23.1859", "/Applications/WorkBuddy2API.app/Contents/Resources/wb2api", false, false, "macos_app"},
		{"darwin", "amd64", "2026.10.23.1859", "/bin/wb2api", false, false, "macos_binary"},
		{"linux", "amd64", "2026.10.23.1859", "/bin/wb2api", true, false, "container"},
		{"linux", "amd64", "2026.10.23.1859", "/bin/wb2api", false, true, "managed"},
		{"windows", "arm64", "2026.10.23.1859", "wb2api.exe", false, false, "standalone"},
		{"linux", "amd64", "dev", "/bin/wb2api", false, false, "development"},
		{"linux", "386", "2026.10.23.1859", "/bin/wb2api", false, false, "unsupported"},
	} {
		got, hint := deploymentInfo(tc.os, tc.arch, tc.version, tc.exe, tc.container, tc.managed)
		if got != tc.want || hint == "" {
			t.Fatalf("%+v: %s %s", tc, got, hint)
		}
	}
	m := New("dev", "", "", Settings{AutoEnabled: true, AutoTime: "04:00"})
	if m.Status().AutoActive {
		t.Fatal("unsupported automatic installation reported active")
	}
	auto, _ := m.scheduleDue(time.Date(2026, 10, 23, 20, 0, 0, 0, time.UTC))
	if auto {
		t.Fatal("unsupported deployment ran automatic install schedule")
	}
}
