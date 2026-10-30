<p align="center">
  <img src="https://raw.githubusercontent.com/DGZSbot/ai-icon/refs/heads/main/WorkBuddy.png" alt="WorkBuddy2API" width="120">
</p>

<h1 align="center">WorkBuddy2API Panel++</h1>

<p align="center">
  <b>把腾讯 WorkBuddy / CodeBuddy 账号变成 OpenAI 兼容 API 的多账号网关 · 附 Web 管理面板</b><br>
  Web 面板 · OAuth 浏览器登录 · 账号池轮转 · 工具与视觉 · 联网检索 · 定时任务 · 流式 / 非流式<br>
  <b>同步上游功能更新 · macOS 桌面应用 · 一键更新与回滚 · 公网部署</b>
</p>

<p align="center">
  <img alt="Go" src="https://img.shields.io/badge/Go-1.26.10-00ADD8?logo=go&logoColor=white&style=flat-square">
  <img alt="API" src="https://img.shields.io/badge/API-OpenAI%20%7C%20Anthropic-412991?style=flat-square">
  <img alt="Deploy" src="https://img.shields.io/badge/Deploy-macOS_App%20%7C%20Binary%20%7C%20Docker-2496ED?style=flat-square">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-green?style=flat-square"></a>
</p>

---

基于 [misakano7545/workbuddy2api-panel](https://github.com/misakano7545/workbuddy2api-panel) 的个人增强分支：**持续同步上游全部功能更新，并在此基础上扩充个人功能**，包括 macOS 桌面应用、一键更新和服务器部署。

WorkBuddy2API 将 WorkBuddy / CodeBuddy 账号接入自托管网关，提供 OpenAI 与 Anthropic 兼容接口。上游的 Web 面板、账号池、协议适配及后续功能与修复持续合入；本仓的个人扩展在同步时保留。构建发布、更新源和项目说明由本仓独立维护。

[下载安装包](https://github.com/haohaomin/workbuddy2api-panel/releases/latest) · [服务器部署](deploy/public-gateway/README.md) · [Docker 网页更新](scripts/docker-updater/README.md) · [反馈问题](https://github.com/haohaomin/workbuddy2api-panel/issues)

## 与直接上游的区别

以下列出在直接上游 `misakano7545/workbuddy2api-panel` 基础上增加的个人功能。同步上游功能与修复是本仓的维护原则；“同步”不代表两仓的发布流程、版本号和更新源相同。

| 本仓增量 | 具体变化 |
| --- | --- |
| **macOS 原生 App** | 提供 Apple 芯片和 Intel 的 DMG。保留控制窗口，支持启动 / 停止服务、打开面板、查看日志和退出应用。 |
| **桌面一键更新** | 检查新版、下载校验、替换 App 并重启；启动失败时尝试回滚，保留用户数据。支持清除旧版应用备份。 |
| **按部署方式更新** | Web 面板区分桌面应用、独立二进制和容器部署，显示对应更新能力与操作提示。独立二进制更新增加启动就绪校验。 |
| **Docker 网页更新器** | 可选的宿主机更新服务，只重建指定的 WorkBuddy 容器；校验新容器、失败时尝试恢复旧镜像。需要一次性安装，不是普通容器默认具备的功能。 |
| **自动构建发布** | 推送 `main` 后自动构建并发布 Windows / Linux 安装包、macOS DMG 与更新包；GHCR 工作流独立发布多架构镜像。使用上海时间版本号。 |
| **公网部署模板** | 提供 WorkBuddy + New API + PostgreSQL + Redis + Caddy 的 Compose 模板，覆盖配置迁移、HTTPS、用户 API Key 分发、用量管理和备份。 |

Web 管理面板、浏览器登录、多账号调度、模型管理、工具与视觉请求适配、签到和任务排程等是与上游共有的基础能力，不作为本仓独有功能重复列举。模型可用性和能力仍取决于账号及上游服务。

**本仓的安装包、更新清单和 WorkBuddy 容器镜像均来自 `haohaomin/workbuddy2api-panel`。** Go module / import 保留上游路径，不影响更新来源。

## 安装与使用

### macOS 桌面应用

1. 在 [Releases](https://github.com/haohaomin/workbuddy2api-panel/releases/latest) 下载以 `darwin-arm64.dmg`（Apple 芯片）或 `darwin-amd64.dmg`（Intel）结尾的安装包。
2. 将 `WorkBuddy2API.app` 拖入「应用程序」并打开。应用启动本地服务，点击「打开面板」管理账号。
3. 在面板中选择「添加账号」，完成浏览器授权，再为客户端配置 API 地址和密钥。

- 「停止服务」保留窗口，之后可再次启动。
- 关闭窗口或退出应用，会停止由本应用启动的服务；最小化不停止服务。
- 在控制窗口中「检查更新 → 更新并重启」。自动检查只提示新版，不自动安装。
- 「清除备份」仅删除更新留下的旧 App，不删除账号和配置。

数据保存在 `~/Library/Application Support/WorkBuddy2API/`，更新 App 会保留该目录。当前应用采用 ad-hoc 签名，未进行 Apple 公证；遇到系统拦截时，先核对下载来源，再通过 macOS 系统设置处理。

### Windows / Linux

从 [Releases](https://github.com/haohaomin/workbuddy2api-panel/releases/latest) 下载对应系统和架构的 ZIP，解压后运行。Windows 新安装会把配置、账号和运行数据放在 `%LOCALAPPDATA%\WorkBuddy2API\`；如果当前目录已有 `config.json`，则继续使用当前目录，兼容绿色版和旧部署。

```powershell
# Windows
.\wb2api.exe
```

```bash
# Linux
chmod +x ./wb2api
./wb2api
```

首次运行会生成 `config.json` 和随机 `api_key`。打开 `http://127.0.0.1:7863/panel/`，使用该密钥登录并添加账号。也可以显式指定配置文件：`wb2api.exe -config D:\WorkBuddy2API\config.json`。Windows 安装版不需要管理员权限即可更新用户目录中的程序。

### Docker / 公网部署

WorkBuddy 镜像：

```text
ghcr.io/haohaomin/workbuddy2api-panel:latest
```

支持 `linux/amd64` 与 `linux/arm64`。生产部署建议固定已验收的镜像版本或 digest。

- **公网入口、用户 Key 和用量管理**：按 [部署指南](deploy/public-gateway/README.md) 配置 New API 与 Caddy。WorkBuddy 保持在私网，由 New API 向用户分发独立令牌。
- **从网页更新 Docker 服务**：按 [Docker 网页更新器指南](scripts/docker-updater/README.md) 安装宿主机服务。仅支持手动触发，不执行每日定时安装；更新期间会短暂中断，失败时尝试镜像回滚。
- **已有容器部署**：保留原配置、账号和数据挂载，先备份再更新。不要用删除数据卷的方式升级。

### 客户端连接

| 配置项 | 本地默认值 |
| --- | --- |
| Web 管理面板 | `http://127.0.0.1:7863/panel/` |
| OpenAI 兼容 Base URL | `http://127.0.0.1:7863/v1` |
| Anthropic 兼容 Base URL | `http://127.0.0.1:7863`（客户端自行追加 `/v1/messages`） |
| API Key | `config.json` 中的 `api_key` |
| 模型 | 从面板或 `GET /v1/models` 获取真实 ID，保留 `cn:` / `global:` 等前缀 |

支持 `POST /v1/chat/completions`、`POST /v1/responses` 和 `POST /v1/messages`。客户端若自动补 `/v1`，填写根地址即可。

通过 New API 访问时，使用公网网关地址及 New API 为用户创建的令牌。**WorkBuddy 内部密钥同时用于管理接口，不应分发给普通用户。**

## 配置与数据

| 路径 | 用途 |
| --- | --- |
| `config.json` | 网关密钥、模型和调度等配置；字段参考 [配置示例](config.example.json) |
| `auths/` | 账号凭据，迁移与备份时保留 |
| `data/` | 运行状态、用量和历史记录；首次迁移可不带，旧历史不会转移 |

桌面 App 的上述路径位于应用数据目录；源码 / 二进制以启动工作目录和 `-config` 参数为准；Docker 以实际挂载为准。不要将凭据、实际配置或备份包提交到 Git。

## 发布与开发

- **版本号**：上海时间，例如 `v2026.10.30.1424` 表示 2026 年 10 月 30 日 14:24。与上游 `1.x` 独立，不按两者数字大小判断新旧。
- **发布触发**：推送 `main` 后由 GitHub Actions 自动打时间标签、测试、构建并创建 Release，无需手动改版本。仅修改 AutoBot 专用文件时按工作流规则跳过。
- **Docker 镜像**：由独立工作流发布，Release 完成不代表镜像已完成，部署前检查对应构建状态。
- **本地构建**：未注入发布版本时显示 `dev`。发布规则见 [AGENTS.md](AGENTS.md)。

源码运行需要符合 [go.mod](go.mod) 的 Go 工具链：

```bash
git clone https://github.com/haohaomin/workbuddy2api-panel.git
cd workbuddy2api-panel
go run ./cmd/server
```

macOS App 构建还需要 Xcode Command Line Tools：

```bash
bash scripts/macos/build-app.sh arm64  # Intel 使用 amd64
open dist/WorkBuddy2API.app
```

## 来源与许可

本仓直接基于 [misakano7545/workbuddy2api-panel](https://github.com/misakano7545/workbuddy2api-panel)，继承自 `linguo2625469/workbuddy2api-panel` 和原始项目 `Sliverkiss/workbuddy2api`。感谢上游作者与贡献者，原作者版权声明保留在 [LICENSE](LICENSE) 中。

本项目采用 MIT 许可，是非官方工具，与腾讯无隶属关系。请仅使用获得授权的账号，并遵守相关服务条款；上游接口变化可能导致功能不可用。

## Star 趋势

[![Star History Chart](https://api.star-history.com/svg?repos=haohaomin/workbuddy2api-panel&type=Date)](https://star-history.com/#haohaomin/workbuddy2api-panel&Date)
