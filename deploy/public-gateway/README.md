# 复用 Mac 配置部署 WorkBuddy2API + New API

此目录提供通用部署模板，账号和密码需在目标服务器配置。假设一台 Linux 服务器已安装 Docker Engine 和 Compose v2，80/443 未被其他网站占用。若已有宝塔、Nginx 或 Caddy，应复用原反向代理，不要再抢占端口。

**本模板默认通过 Compose 更新 WorkBuddy，不会自动启用网页更新。** 首次部署完成后，如需在 WorkBuddy 面板点击更新，再完成第 7 节的一次性配置；仅拉取新镜像不会安装宿主机更新服务。

## 1. 确认要迁移的配置

本机检查到两套配置：

- Mac App：`/Users/renhao/Library/Application Support/WorkBuddy2API/`
- 源码运行：`/Users/renhao/works/workbuddy2api-panel/`

使用桌面 App 时选第一套；源码运行时以启动参数 `-config` 和进程工作目录为准，不能把两套账号目录随意合并。

默认只迁移配置和账号，历史数据可选：

| 路径 | 是否迁移 | 内容 |
| --- | --- | --- |
| `config.json` | 必需 | API Key、模型设置、调度和超时等配置 |
| `auths/` | 必需 | 登录凭据及刷新凭据 |
| `data/` | 可选 | 账号运行状态、用量和其他历史数据 |

不迁移 `data/` 时，服务器从新的运行状态开始，旧用量、余额等历史记录不会带过去；部分状态和缓存会重新建立。下面的默认步骤采用这种方式。希望保留历史记录时，使用第 2 步的完整打包命令。

已确认 App 配置使用 `./auths` 和 `./data/state.json`，没有配置外部 Redis、额外提示词文件或设备凭据文件。模板通过保持工作目录结构复用这些相对路径。以后若增加指向其他目录的文件，需要额外迁移并修改路径。

账号未失效且上游允许服务器网络访问时，通常无需重新登录；失效账号仍需重新授权。New API 的用户和分发额度是另一套系统，需首次初始化；WorkBuddy 的历史用量不会自动变成 New API 的用户账单。

## 2. Mac 上停止 App 服务并打包

先点击桌面 App 的“停止服务”。默认只打包配置和账号：

```bash
umask 077
tar -czf "$HOME/Desktop/workbuddy-migration.tar.gz" \
  -C "$HOME/Library/Application Support/WorkBuddy2API" \
  config.json auths
```

如果希望同时保留账号运行状态和历史数据，改用下面的命令（两种方式选一种）：

```bash
umask 077
tar -czf "$HOME/Desktop/workbuddy-migration.tar.gz" \
  -C "$HOME/Library/Application Support/WorkBuddy2API" \
  config.json auths data
```

迁移包包含账号密钥，仅通过 SSH/SCP 传输，不上传 Git 或网盘公开链接。切换到服务器后先保持本地服务停止，避免两个实例同时刷新同一批凭据、执行签到任务。

以下命令中的 `USER@SERVER` 要替换成服务器 SSH 登录地址，也可用已配置的 SSH 别名：

```bash
ssh USER@SERVER 'mkdir -p ~/ai-gateway'
scp -r /Users/renhao/works/workbuddy2api-panel/deploy/public-gateway/. USER@SERVER:~/ai-gateway/
scp "$HOME/Desktop/workbuddy-migration.tar.gz" USER@SERVER:~/ai-gateway/
```

## 3. 在服务器准备数据和环境变量

以下命令在服务器执行，首次部署时使用空的 `wb2api` 目录：

```bash
cd ~/ai-gateway
docker compose version
test ! -e wb2api && mkdir wb2api
tar -xzf workbuddy-migration.tar.gz -C wb2api
test -f wb2api/config.json
test -d wb2api/auths
mkdir -p wb2api/data
sudo chown -R 10001:10001 wb2api
sudo chmod -R go-rwx wb2api
```

`mkdir -p wb2api/data` 会在未迁移历史数据时创建空目录；如果迁移包已包含 `data/`，则保留其中的文件。`10001` 是本 fork Dockerfile 的服务用户。不要把 `wb2api` 挂载为只读：账号刷新、状态保存和面板保存需要写文件。

运行下面脚本生成 `.env`，把示例域名换成自己的域名。脚本拒绝覆盖已有 `.env`，避免重置正在使用的数据库密码：

```bash
python3 - <<'PY'
from pathlib import Path
import os, secrets
os.umask(0o077)
domain = 'api.example.com'  # 改成自己的域名，只填主机名
lines = [
    'API_DOMAIN=' + domain,
    'WORKBUDDY_IMAGE=ghcr.io/haohaomin/workbuddy2api-panel:latest',
    'NEW_API_IMAGE=calciumion/new-api:latest',
    'POSTGRES_PASSWORD=' + secrets.token_hex(24),
    'REDIS_PASSWORD=' + secrets.token_hex(24),
    'SESSION_SECRET=' + secrets.token_hex(32),
    'SECURE_COOKIE=false',
    'TRUSTED_URL=',
]
with Path('.env').open('x') as f:
    f.write('\n'.join(lines) + '\n')
PY
docker compose config --quiet
docker compose pull workbuddy new-api postgres redis caddy
```

`latest` 用于首次拉取。正式分发前建议把两个应用镜像固定到已验收的版本或 digest，升级时再显式修改，避免一次 pull 引入未经验证的版本。如果自己的 GHCR 包尚未公开，需要先把包设为 Public，或用具备读取包权限的凭据登录 GHCR。

## 4. 先通过 SSH 完成初始化

服务器执行：

```bash
docker compose up -d workbuddy new-api
docker compose ps
docker compose logs --tail=50 workbuddy new-api
```

此时没有开放公网 Web 入口。Mac 另开终端并保持连接：

```bash
ssh -N -L 13000:127.0.0.1:3000 -L 17863:127.0.0.1:7863 USER@SERVER
```

- `http://127.0.0.1:17863/panel/`：WorkBuddy 面板，使用原来的内部 API Key。确认账号、模型和一次实际调用正常。
- `http://127.0.0.1:13000`：New API，完成首次管理员初始化，检查并关闭不需要的公开注册。

在 New API 中添加渠道：

| 字段 | 填写 |
| --- | --- |
| 类型 | OpenAI 兼容渠道（通常界面叫 OpenAI），不要选要求完整 URL 的“自定义”类型 |
| 名称 | WorkBuddy |
| 代理地址 / Base URL | `http://workbuddy:7863`，不要再追加 `/v1` |
| 密钥 | 迁移的 `config.json` 中的 `api_key`，仅管理员保存 |
| 模型 | 按 WorkBuddy `/v1/models` 的真实 ID 录入，保留 `cn:` / `global:` 前缀 |
| 分组 | 建立一个 WorkBuddy 分组，绑定渠道与用户令牌 |

如果 New API 的上游地址校验拦截私网地址，只为受信的 `workbuddy` 服务配置允许规则，不要为了接通而开放所有任意地址。

不要直接使用渠道默认的 GPT 模型测试；改选实际存在的模型。为自定义模型设置价格/倍率，给测试用户创建有限额令牌，验证非流式、流式、工具调用、图片和额度拦截。启用 OpenAI 流式 usage 选项（若当前版本提供）；检查日志中的输入/输出 token，不能把调用成功当作用量正确。Claude Code 的 Messages 和 Responses 客户端需分别验收，协议转换并不保证所有功能等价。

WorkBuddy 内部密钥同时能访问其管理接口，不发给普通用户；对外只发 New API 用户令牌。

## 5. 绑定域名，开放 HTTPS

在 DNS 控制台添加 A 记录：`api` 指向服务器公网 IPv4。只有服务器确实提供 IPv6 时才添加 AAAA。云安全组和系统防火墙放行 TCP 80/443，保留必要的 SSH 管理访问；不开放 3000、7863、5432、6379。

服务器在 `~/ai-gateway` 执行，把登录 Cookie 切换到 HTTPS 模式：

```bash
python3 - <<'PY'
from pathlib import Path
p = Path('.env')
lines = p.read_text().splitlines()
values = dict(line.split('=', 1) for line in lines if '=' in line)
domain = values['API_DOMAIN']
assert domain and domain != 'api.example.com', '请先修改 API_DOMAIN'
lines = [
    'SECURE_COOKIE=true' if line.startswith('SECURE_COOKIE=') else
    'TRUSTED_URL=https://' + domain if line.startswith('TRUSTED_URL=') else line
    for line in lines
]
p.write_text('\n'.join(lines) + '\n')
PY
docker compose --profile public up -d
docker compose logs --tail=50 caddy
```

访问 `https://你的域名`，重新登录。切换后 New API 登录应通过这个 HTTPS 域名进行，不再通过 HTTP 隧道登录。

客户端一般填写：

- OpenAI 兼容 Base URL：`https://你的域名/v1`（若客户端自动补 `/v1` 则填根地址）。
- API Key：New API 为该用户创建的令牌。
- 模型：对应令牌分组已开放的真实模型 ID。

Caddy 仅代理 New API，不把 WorkBuddy 管理面板映射到公网。WorkBuddy 面板继续使用 SSH 隧道访问。证书自动签发需要 DNS 正确、80/443 可达以及持久化的 Caddy 数据卷。

## 6. 数据备份与更新

以下普通 Compose 命令用于尚未启用网页更新器的部署。启用第 7 节后，凡是可能重建 WorkBuddy 的操作，都要保留补充 Compose 文件和已生成的镜像固定文件，按 [网页更新器的人工维护说明](../../scripts/docker-updater/README.md#固定版本人工恢复与排错) 执行，不能再直接照抄本节的普通 `up` 命令。

需要备份：`wb2api/`、`.env`、Compose/Caddy 配置、`newapi-data/`、`newapi-logs/`，以及 PostgreSQL 数据库。New API 用户、额度、渠道和账单主要在 PostgreSQL，不在 WorkBuddy 的 config.json 中。

首次迁移时可以不带旧 `data/`；服务器投入使用后，备份仍建议包含新生成的 `wb2api/data/`，以保留服务器上的运行状态和历史记录。

维护窗口可先停止两个应用，再导出数据库并归档文件，完成后启动：

```bash
cd ~/ai-gateway
umask 077
docker compose stop new-api workbuddy
docker compose exec -T postgres pg_dump -U newapi -d newapi -Fc > newapi.dump
sudo tar -czf "backup-$(date +%Y%m%d-%H%M%S).tar.gz" \
  wb2api .env compose.yml Caddyfile newapi-data newapi-logs newapi.dump
docker compose --profile public up -d
```

确认导出和归档成功，再把备份保存在服务器之外。Caddy 证书数据和 Redis 在命名卷里；如需完整迁移，也应备份它们。不要执行 `docker compose down -v`，它会删除数据库等数据卷。

仅更新 WorkBuddy 时，先备份并修改 `.env` 中的 `WORKBUDDY_IMAGE`（使用已验收的版本或 digest），再执行：

```bash
docker compose pull workbuddy
docker compose up -d --no-deps workbuddy
docker compose ps workbuddy
```

此模板默认通过 Compose 更新镜像；如需网页触发更新，另行配置 [Docker 网页更新器](../../scripts/docker-updater/README.md)。WorkBuddy 更新源始终是 `haohaomin/workbuddy2api-panel`。New API 独立从其官方镜像更新。

## 7. 启用 WorkBuddy 网页更新（可选）

完成前面的部署后，在 Linux 宿主机按 [Docker 网页更新器指南](../../scripts/docker-updater/README.md) 获取源码、安装服务并验收。只复制本目录到服务器时，还没有 `scripts/docker-updater/`，需按该指南补取；源码目录与 `~/ai-gateway` 部署目录是两回事。

本模板对应的配置如下，以容器标签和实际路径为准：

| 更新器配置 | 本模板的填写方式 |
| --- | --- |
| `project_directory` | `cd ~/ai-gateway && pwd` 得到的绝对路径，不填写 `~` |
| `project_name` | `wb2api-public` |
| `compose_files` | `["compose.yml", "docker-compose.web-update.yml"]`；若原部署还有其他补充文件，保留它们的原顺序 |
| `service` | `workbuddy`，补充文件里的服务名也必须一致 |
| `container_port` | `7863` |
| `socket_gid` | 默认 `10001`；修改过容器运行用户时按实际 GID 填写 |

使用指南中的命令时，把通用示例的 `docker-compose.yml` / `wb2api` / 项目目录与项目名替换为上表的值，不能另起一个项目。启动宿主机服务后，仅重建 `workbuddy` 以加入 socket 挂载和环境变量，保留原 `./wb2api:/app/user-data` 数据挂载。

通过第 4 节的 SSH 隧道访问 WorkBuddy 面板，在 **配置 → 版本与更新** 验收：应显示 Docker 网页更新，点击检查后能够完成镜像下载或提示已是最新。公网 New API 页面没有这个 WorkBuddy 更新入口。以后从这里手动更新 WorkBuddy；New API、数据库和 Caddy 不由该更新器升级。

## 参考与验证范围

- New API 官方 Compose：https://github.com/QuantumNous/new-api/blob/main/docker-compose.yml
- New API 环境变量：https://github.com/QuantumNous/new-api/blob/main/.env.example
- OpenAI 渠道 URL 拼接：https://github.com/QuantumNous/new-api/blob/main/relay/channel/openai/adaptor.go
- Caddy HTTPS：https://caddyserver.com/docs/automatic-https

此模板根据当前仓库和上述官方配置编写。已在一台 Linux ARM64 服务器的现有 Compose 部署上验证更新器安装、容器接线、鉴权、服务重启后重连和镜像检查/下载；这不是全新空白服务器的全流程验收，也未通过生产故障注入验证回滚。首次部署仍需在目标服务器执行 `docker compose config --quiet`，并按上述步骤验收实际调用、网页更新和数据保留。
