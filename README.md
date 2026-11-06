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
| **Docker 网页更新器** | 可选的宿主机更新服务，只重建指定的 WorkBuddy 容器；校验新容器、失败时尝试恢复旧镜像。更新成功后清理更早的镜像备份，并保留上一版用于回滚。需要一次性安装。 |
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

从 [Releases](https://github.com/haohaomin/workbuddy2api-panel/releases/latest) 下载 Windows 安装包或绿色 ZIP。安装包是 per-user 安装，不需要管理员权限；绿色 ZIP 适合便携运行。Windows 新安装会把配置、账号和运行数据放在 `%LOCALAPPDATA%\WorkBuddy2API\`；如果当前目录已有 `config.json`，则继续使用当前目录，兼容旧部署。

安装包文件名为 `WorkBuddy2API-Setup-windows-amd64.exe` 或 `WorkBuddy2API-Setup-windows-arm64.exe`。安装、升级和卸载不会主动删除 `config.json`、`auths/` 或 `data/`；如需彻底清理，请在确认备份后手动删除 `%LOCALAPPDATA%\WorkBuddy2API\`。

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

**第一次部署注意：容器能运行，不代表已开启网页更新。** 只拉取镜像或完成公网部署模板，默认仍通过 Compose 更新。想在网页点击更新，必须再完成 [宿主机更新器的一次性安装和验收](scripts/docker-updater/README.md)。之后在 **WorkBuddy 面板 → 配置 → 版本与更新** 操作；不是 New API 的管理页面。

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

## 🎬 媒体生成：生图 / 改图 / 出视频 / MCP

网关除了对话，还把 WorkBuddy 的**媒体模型**包成 OpenAI 形态的 HTTP 接口，并额外给出一个 **MCP（Model Context Protocol）** 端点——Claude Code / Codex / Cursor / DeepSeekRuntime（DSH）这类 agent 配一行就能拿到「出图 / 出视频」工具，不必自己实现一遍鉴权、轮询和记账。

### 接口一览

| 方法 | 路径 | 用途 |
|---|---|---|
| POST | `/v1/images/generations` | 文生图 |
| POST | `/v1/images/edits` | 改图 / 图生图；`image` 可传公网 URL、`data:` URL 或 multipart 文件 |
| POST | `/v1/videos` | 提交视频任务（OpenAI Videos 资源的路径，等价于下一行）。缺省 `wait=true`：阻塞到出片后回 200；`wait=false`：秒回 `task_id` |
| POST | `/v1/videos/generations` | 同上 |
| GET | `/v1/videos/{task_id}` | 查任务（`queued` / `in_progress` / `completed` / `failed`） |
| GET | `/v1/videos/{task_id}/content` | 取成品字节（流式转发签名直链，不落盘；任务没出片回 409） |
| POST | `/v1/videos/tasks` | 查任务，body `{"task_id":"..."}`（给不方便用路径参数的客户端） |
| POST | `/v1/images/strip-watermark` | 裁掉底部纯白留白（顺带去水印），默认关闭；见「去水印」 |
| POST | `/mcp` | MCP（JSON-RPC 2.0，Streamable HTTP 形态），见下 |

视频回执按 OpenAI Videos 的 Video 资源出（`object:"video"`、`status` 四态、`seconds` 是字符串、`progress` 只有 0/100、`error` 是 `{code,message}` 对象），另带 `data[].url` / `videos[].url` / `usage.credit` 这几个自解释字段。OpenAI 的 Videos API 本身已于 2026-09-24 关停，这里对齐的是它还留在各家 SDK 里的形状。图片侧 `response_format:"b64_json"` 由网关取直链后转 base64（上游无视该参数）；`n>1` 直接回 400 —— 上游一次只出一张，宁可拒绝也不静默少给。

模型名照旧带域前缀：`cn:hunyuan-image-alpha`、`cn:hunyuan-image-alpha-edit`、`cn:minimax-video-h3`、`cn:kling-video-v3`。`/v1/models` 会把媒体模型单列并带 `image_generation` / `video_generation` 标记（`modalities.output` 分别是 `["image"]` / `["video"]`）；没配 `model` 时生图用 `cn:hunyuan-image-alpha`、生视频用 `cn:minimax-video-h3`。

### 生图 / 改图

```bash
curl -s http://127.0.0.1:7863/v1/images/generations \
  -H "Authorization: Bearer $WB2API_KEY" -H 'Content-Type: application/json' \
  -d '{"prompt":"一只戴礼帽的柴犬，像素风","size":"1024x1024"}'

# 改图：image 支持公网 URL / data: URL / multipart 文件
curl -s http://127.0.0.1:7863/v1/images/edits \
  -H "Authorization: Bearer $WB2API_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"cn:hunyuan-image-alpha-edit","prompt":"把背景换成星空","image":"https://…/in.png"}'
```

回执**原样透传**上游（`{created, data:[{url}], usage:{credit, …}}`），网关不转存字节——图是签名直链，约 24h 有效，要长期保存请自行落盘。实测 5.71 积分/张（`cn:hunyuan-image-alpha`）。

> 改图的输入图必须是上游**取得到**的地址。拿「刚生成的那张图的签名直链」直接回投给改图接口，实测上游会回 `invoke model error`（它取不到/不认那个 URL）；用 `data:` URL 或自己可控的公网地址最稳。

### 出视频（异步任务）

```bash
# 提交（不等待）
curl -s http://127.0.0.1:7863/v1/videos/generations \
  -H "Authorization: Bearer $WB2API_KEY" -H 'Content-Type: application/json' \
  -d '{"prompt":"一杯热咖啡，热气缓缓上升","seconds":4,"wait":false}'
# → {"id":"1312831544-WandVideo-…","object":"video","task_id":"…","status":"queued", …}

# 查（阻塞到出片；不用 wait 参数时 POST 就是阻塞语义）
curl -s http://127.0.0.1:7863/v1/videos/1312831544-WandVideo-… \
  -H "Authorization: Bearer $WB2API_KEY"
```

请求参数：`prompt`（必填）、`model`、`seconds`（实测 4-15）、`resolution`、`aspect_ratio`（`16:9` / `9:16` / `1:1`）、`negative_prompt`、`enable_audio`（默认 `true`）、`watermark`（默认 `true`）、`image`（图生视频，公网/签名 URL）、`last_image`（尾帧）、`wait`（缺省 `true`）、`timeout_seconds`（缺省 900，封顶 1800）。除 `wait` / `timeout_seconds` 外都原样交给上游。

回执（出片后）：

```json
{"id":"…","object":"video","task_id":"…","status":"completed","model":"cn:minimax-video-h3",
 "created_at":1793801279,"completed_at":1793801403,"size":"768P","seconds":4,
 "data":[{"url":"https://aigc-output-video-….cos.ap-guangzhou.myqcloud.com/….mp4?q-signature=…"}],
 "videos":[{"url":"…"}],
 "usage":{"credit":57.14,"output_video_tokens":200000,"output_video_duration":4,"output_video_coefficient":1},
 "hint":"视频地址是签名直链（约 12 小时有效）；需要长期保存请自行落盘。"}
```

实测口径（2026-11-04，CN 池）：

| 模型 | 请求 | 实际扣费 | 出片耗时 | 回执 size |
|---|---|---|---|---|
| `cn:minimax-video-h3` | 4s / 16:9 / 有声 | 57.14 | ≈124s | `768P` |
| `cn:minimax-video-h3` | 4s 图生视频 | 57.14 | ≈124s | `768P` |
| `cn:kling-video-v3` | 4s（实际出 5s） | 102.86 | ≈473s | 不回该字段 |

几个必须知道的坑：

- **上游不校验 `aspect_ratio` / `resolution`**：`4:3`、`999x999` 都能提交成功并正常出片。网关同样不假装校验（只把合法值写进文档），免得把上游未来支持的比例挡在外面。
- **上游 `usage` 只回一次**：第一次查到 `completed` 时回，之后重复查询没有 `usage`（kling 连 `size` 都不回）。网关在任务台账里缓存这次用量，重复查询照样能拿到 `credit` / `size` / `seconds`。
- **计费只记一次**：提交不扣钱，出片完成那一刻按 `usage.credit` 记一次（任务台账里的「已记账」标记 + 同步/异步两条路径共用同一把锁），重复查询、并发查询都不会重复记账。
- **任务是账号级可见**：上游任务只对提交它的账号可见，账号结构里没有数字租户 id 可以反推，所以网关自己维护「task → 账号」台账；**台账在进程内存里**，重启后查询会退化成逐个账号试、命中即收养（此时若上游不再回 `usage`，这次查询就不带积分明细，但也不会重复扣费）。
- **kling 慢一个量级**：MCP 默认 `wait=true`，客户端超时要给到 15 分钟以上；只想拿任务号就传 `wait=false`。

### MCP 端点（`POST /mcp`）

MCP 端点走 **Streamable HTTP** 的纯 POST 形态（不提供 SSE 流、不维护 session）：客户端发一条 JSON-RPC 就回一条 JSON-RPC。鉴权与 REST 相同（`Authorization: Bearer <api_key>`）；`GET /mcp` 回 405 + `Allow: POST`（客户端据此退回纯 POST）。

```bash
curl -s http://127.0.0.1:7863/mcp \
  -H "Authorization: Bearer $WB2API_KEY" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"0"}}}'
```

工具（5 个）：

| 工具 | 说明 |
|---|---|
| `list_generation_models` | 列可用的生图 / 出视频模型（读目录旁路缓存，不打上游），带计费与直链时效说明 |
| `generate_image` | 文生图，参数 `prompt`（必填）、`model`、`size`、`quality`、`n`；同步回 URL |
| `edit_image` | 改图，参数 `prompt`（必填）、`image`（URL 或 `data:` URL，必填）、`model` |
| `generate_video` | 出视频，参数 `prompt`（必填）、`model`、`seconds`、`resolution`、`aspect_ratio`、`negative_prompt`、`enable_audio`、`image`、`last_image`、`wait`（缺省 `true`） |
| `get_video_task` | 查任务 / 收片，参数 `task_id` |

客户端配置（Claude Code / DSH / 任何支持 HTTP MCP 的宿主）：

```json
{"mcpServers":{"wb2api":{"type":"http","url":"http://127.0.0.1:7863/mcp",
  "headers":{"Authorization":"Bearer <api_key>"}}}}
```

约定：**工具执行失败**（上游 4xx/5xx、任务 failed）回 `result.isError=true` + 上游原话进 `content[0].text`，让模型自己读到「时长只支持 4-15 秒」这类可行动信息；**参数不合法**（缺 `prompt` / 缺 `task_id` / 未知工具）才走 JSON-RPC `-32602`。工具调用内部直接复用网关自己的 HTTP handler（`httptest` 形态），所以换号、错误策略、记账、请求日志与 REST 完全同一条路径——不会出现「REST 记了账、MCP 漏了账」这种分叉。

### 去水印（可选，默认关闭）

成品右下角有「AI生成 / WORKBUDD>.」水印。它是**白色半透明**、锚在右下角（距右边 / 下边各约 10px）：1024 / 1536 边长档量出来固定 **111×51px**，1344×1792 档约 126×80px，**不随画布缩放**。

两条路，按需选：

1. **白底上它本来就不显眼**——纯白区像素均值 255.0 / 标准差 0.1，成品最终排在白底上时肉眼看不出来，可以不处理。
2. **要彻底去干净就裁**：让画面底部真有一条纯白留白，再把这条留白整条裁掉，水印必然一起消失（水印最高约 80px，留白 ≥ 90px 才安全）。

模型不总肯留白（实测：杯子 38.5%、猫 31.2%、深色木桌那张只有 1.0%），所以稳的打法是两步：

```bash
# 1) 生成时直接要留白（不给白边就补一刀）
curl -s http://127.0.0.1:7863/v1/images/generations   -H "Authorization: Bearer $KEY" -H "Content-Type: application/json"   -d '{"model":"cn:hunyuan-image-alpha","size":"1024x1536",
       "prompt":"……；画面最下方三分之一是完全纯白留白，不要有任何物体、阴影、反光、文字"}'

# 留白不够？用改图补一条白边（约 5.71 credit）
curl -s http://127.0.0.1:7863/v1/images/edits   -H "Authorization: Bearer $KEY"   -F image=@photo.png   -F 'prompt=把图片最下方约三分之一区域涂成纯白色（#FFFFFF）空白留白，不要改变上方画面'

# 2) 裁掉留白（本地解码裁剪，不扣积分）
curl -s http://127.0.0.1:7863/v1/images/strip-watermark   -H "Authorization: Bearer $KEY" -H "Content-Type: application/json"   -d '{"image":"https://….myqcloud.com/….png","min_blank_px":90}'
```

回执（`data_url` 是裁好的图，`return:"meta"` 时只回数字不返回图）：

```json
{
  "object": "image.strip",
  "width": 1024, "height": 1536, "out_width": 1024, "out_height": 944,
  "boundary": 944, "blank_px": 592, "blank_ratio": 0.385, "blank_lum": 254.4,
  "min_blank": 90, "white_lum": 248, "safe": true, "format": "png",
  "data_url": "data:image/png;base64,…",
  "usage": {"credit": 0, "hint": "本地后处理，不消耗上游积分"}
}
```

参数：`image`（必填：上游产物域 URL / `data:` URL / 裸 base64）、`min_blank_px`（默认 90）、`keep_blank`（裁完在内容下方留几像素白边，默认 0）、`format`（`png` / `jpeg`，省略跟随输入）、`quality`（JPEG 默认 92）、`return`（`data_url` 默认；`meta` 只回数字，适合先校验留白够不够）。

留白不够时回 **422 `no_blank_strip`**，`gateway_hint` 里带实测数字和下一步（先 `edit_image` 涂白）。MCP 侧同名工具 `strip_watermark`，回 MCP `image` content（base64）+ 文本元数据。

开关 `features.watermark_strip_enabled`（默认 `false`，面板保存后热生效）：关着时端点回 **403 `watermark_strip_disabled`**，MCP 的 `strip_watermark` 也不出现在 `tools/list` 里，其它生成接口完全不受影响。默认关是因为它要把成品图回读、解码、再 base64 回传（1024×1536 PNG 约 2.5MB → base64 3.4MB），只在真要彻底去水印时划算。

边界：只裁「整条纯白留白」，不做 inpainting；`min_blank_px` 调小会切到画面内容；裁切会改画幅，介意就 `keep_blank` 少裁一点。图片地址只允许上游产物域（`.myqcloud.com`），防止被当成 SSRF 跳板。

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
