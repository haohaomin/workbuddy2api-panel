# Linux Docker 网页更新

完成一次宿主机配置后，在面板 **配置 → 版本与更新** 点击 **检查更新 → 立即更新** 即可。仅支持 Linux、Docker Engine + Compose v2 或更新版本的单实例服务；宿主机需要 Python 3.9+ 和 systemd。现有 `docker run` 部署需先迁移到 Compose，保留原来的配置、账号和数据挂载。此功能只支持手动更新，不执行面板中的每日定时安装。

网页通过 Unix socket 请求宿主机上的更新服务。更新服务只能操作配置文件中指定的 Compose 项目和服务，拉取源固定为 `ghcr.io/haohaomin/workbuddy2api-panel:latest`。容器中不挂载 Docker socket，也不暴露额外网络端口。网页操作要求配置非空 `api_key`，使用现有面板 Bearer 鉴权。

## 第一次使用先看

**普通镜像和公网部署模板不会自动安装宿主机更新器。** 必须完成下面全部步骤：获取更新器文件 → 按实际 Compose 项目填写配置 → 启动宿主机服务 → 给 WorkBuddy 容器添加连接变量和 socket 挂载 → 验收网页入口。只升级镜像、只复制文件或只启动 systemd 服务，都不算启用完成。

更新操作位于 **WorkBuddy 管理面板**，不是 New API。使用公网部署模板时，WorkBuddy 面板默认只通过 SSH 隧道访问；公网域名打开的是 New API。

如果服务器只有镜像或复制过去的 `deploy/public-gateway` 目录，还没有更新器源码，先在服务器获取本仓代码。已有源码则直接进入对应目录，不必重复克隆：

```bash
git clone https://github.com/haohaomin/workbuddy2api-panel.git "$HOME/workbuddy2api-panel-source"
cd "$HOME/workbuddy2api-panel-source"
test -f scripts/docker-updater/agent.py
```

源码目录只是获取安装文件的位置，**不是**现有 Compose 项目目录。不要因此另起一套容器。

## 一次性安装

以下命令在 Linux **宿主机**上、包含本功能的源码目录执行。示例项目位于 `/opt/workbuddy2api-panel`，服务名 `wb2api`。已有项目不用迁移目录，替换示例中的路径即可。先备份 `config.json`、账号目录和数据目录。

1. 核对现有 Compose 项目名和服务名，不能另起一个项目，否则会产生第二套容器/卷。将 `workbuddy2api` 换成你的容器名称：

   ```bash
   docker inspect workbuddy2api --format '{{ index .Config.Labels "com.docker.compose.project" }} / {{ index .Config.Labels "com.docker.compose.service" }}'
   docker compose version
   python3 --version
   ```

   以下两种模板的默认值不同，务必以运行中容器的标签为准；没有 Compose 标签时，不要继续照抄安装命令：

   | 项目类型 | 容器名示例 | `project_directory` | `project_name` | 主 Compose 文件 | `service` |
   | --- | --- | --- | --- | --- | --- |
   | 仓库根目录的 Compose | `workbuddy2api` | 如 `/opt/workbuddy2api-panel` | 默认由目录名推导；读取容器标签确认 | `docker-compose.yml` | `wb2api` |
   | [公网部署模板](../../deploy/public-gateway/README.md) | `wb2api-public-workbuddy-1` | `~/ai-gateway` 对应的绝对路径 | `wb2api-public` | `compose.yml` | `workbuddy` |

   `project_directory` 的 JSON 值必须写绝对路径，不写 `~`。例如公网模板的 `compose_files` 是 `["compose.yml", "docker-compose.web-update.yml"]`，补充文件里的服务名和后续命令末尾也都要改为 `workbuddy`。

2. 安装更新服务。再次安装时，保留已有 `/etc/workbuddy-updater.json`：

   ```bash
   sudo install -d -m 755 /usr/local/lib/workbuddy-updater
   sudo install -m 644 scripts/docker-updater/agent.py /usr/local/lib/workbuddy-updater/agent.py
   sudo install -m 644 scripts/docker-updater/workbuddy-updater.service /etc/systemd/system/workbuddy-updater.service
   # 仅首次安装执行下一行，不覆盖已有配置
   sudo install -m 600 scripts/docker-updater/config.example.json /etc/workbuddy-updater.json
   sudoedit /etc/workbuddy-updater.json
   ```

   按实际部署填写：

   | 字段 | 含义 |
   | --- | --- |
   | `project_directory` | 现有 Compose 项目的绝对路径，也是 `.env` 所在目录 |
   | `project_name` | 第 1 步输出的项目名，必须保持一致 |
   | `compose_files` | 按原顺序列出全部 Compose 文件，再加入 `docker-compose.web-update.yml`；路径相对项目目录 |
   | `service` | 第 1 步输出的 WorkBuddy 服务名（可能是 `wb2api` 或 `workbuddy`） |
   | `container_port` | 容器内部 HTTP 端口，默认 7863，与宿主机映射端口无关 |
   | `socket_gid` | 容器进程的 GID；官方镜像默认 10001；设置了 `PGID` / `user:` 时填写实际值 |
   | `ready_timeout` | 新容器启动检查期限，默认 90 秒，包含至少 8 秒持续稳定观察 |

   若原启动依赖 shell 中的 Compose 插值变量，把这些变量保存到项目的 `.env`，确保 systemd 下得到同样的配置。只支持本机默认 Docker Engine；rootless Docker、自定义 context、Swarm 不在此方案范围内。需要私有仓库凭证时，以服务运行用户 root 配置 Docker 登录。

3. 复制补充 Compose 文件到现有项目目录，并把其中 `wb2api` 改为实际服务名：

   ```bash
   cp scripts/docker-updater/docker-compose.web-update.yml /opt/workbuddy2api-panel/docker-compose.web-update.yml
   ```

   原有账号、配置和数据卷保持挂载。更新器只添加 socket 目录和环境变量，并切换到发布镜像；**不要把 Compose 文件、`.env`、更新器配置或状态目录挂到容器中**。这些宿主机文件仅由可信管理员维护。socket 的整个目录以只读方式挂载，更新服务重启后 socket 可重新连接。

4. 先启动宿主机更新服务，确保 socket 目录存在，再重建现有容器以启用入口：

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now workbuddy-updater
   sudo systemctl status workbuddy-updater --no-pager
   cd /opt/workbuddy2api-panel
   sudo docker compose -p workbuddy2api-panel -f docker-compose.yml -f docker-compose.web-update.yml up -d --no-deps --no-build --pull always wb2api
   ```

   命令中的项目名、文件列表和服务名须与更新器配置一致。首次启用需要**包含本功能的镜像已经发布**；旧镜像不会显示 Docker 网页安装能力。`.env` / `config.json` 中设置非空网关密钥，并用该密钥登录面板。

   这条首次启用命令会拉取并运行本仓 `latest`，不只是添加挂载；会短暂重建 WorkBuddy。若已有生产版本必须保持不变，应先固定当前镜像，再按实际部署调整命令。首次接线本身不属于网页更新事务，不能依赖网页更新器自动回滚这次手工操作。

5. 验收后再交付使用：

   ```bash
   sudo systemctl is-enabled workbuddy-updater
   sudo systemctl is-active workbuddy-updater
   sudo curl --fail --unix-socket /run/workbuddy-updater/agent.sock http://localhost/status
   ```

   前两项应分别输出 `enabled`、`active`。socket 返回中应有 `"deployment":"docker_agent"` 和 `"can_install":true`（JSON 空格可能不同）。**宿主机接口成功还不够**，继续确认：

   - 刷新 WorkBuddy 面板，用非空内部 API Key 登录；「配置 → 版本与更新」应提示 Docker 网页更新，不再提示“容器部署请拉取新镜像”。
   - 点击「检查更新」，等到检查完成。已有新版时，应显示新镜像已下载、可立即更新；没有新版时显示已是最新，这不算故障。检查会下载镜像，但不会安装。
   - 如需接口验收，使用管理员鉴权请求 `GET /panel/api/update`，应返回 `deployment: docker_agent`、`can_install: true` 且没有 `last_error`。不要把内部 API Key 分发给普通用户。
   - 真正点击「立即更新」后，等待面板重连，核对版本、账号和一次 API 调用。检查/下载成功不等于已经完成升级。

   宿主机服务正常但网页不可用时，先检查 `WB2A_DOCKER_UPDATER_SOCKET`、socket 目录挂载和实际 GID；不要反复升级镜像来代替接线。

## 网页使用及更新行为

- **检查更新**：后台下载 GHCR `latest`，使用镜像 ID 判断是否有更新。期间当前容器继续运行，网页显示下载状态。GitHub Release 与镜像构建独立，Docker 判断不借用桌面端版本号。
- **立即更新**：安装上次检查已下载的固定镜像，不会在点击时偷偷换成另一版。若下载后又发布了新版，重新点“检查更新”即可刷新候选。若运行中的容器被人工更换过，需要重新检查。
- **重建及验证**：只对指定服务执行 `compose up -d --no-deps --no-build --pull never --force-recreate`，保留配置中已有卷；切换时有短暂中断。网页自动重连，即使关闭面板自动刷新也会继续查询更新进度。
- **回滚**：检查容器镜像、运行状态、重启次数，并在容器内部请求 `/healthz`，验证网关身份和至少 8 秒稳定响应。账号池为空时的 503 不是启动失败。失败后尝试以旧镜像重建并再次检查。宿主机或更新服务中断后，重启更新服务会根据持久化记录尝试回滚未完成的更新。
- **备份清理**：新容器通过稳定性检查后，自动删除更早的 `workbuddy2api-managed:<完整镜像 ID>` 备份，保留当前镜像和紧邻上一版作为回滚版本。回滚失败或清理单个旧镜像失败时，不影响已验证的新版本；清理失败的镜像会保留，并显示清理未完成。更新或回滚期间不会运行备份清理。
- **镜像存储**：候选及回滚镜像由 Docker 管理，没有 DMG 或独立安装包。自动清理只针对更新器自己的 `workbuddy2api-managed:` 标签，不扫描或清理其他镜像。

回滚仅恢复镜像，不回滚配置、账号和数据库变化；启动检查不保证上游账号/API 可用。宿主机断电、磁盘故障或 Compose 配置错误仍可能需要人工恢复。更新期间不要同时运行手动 `compose up`、修改 Compose 文件或部署其他版本。

容器重建、卷保留和 `--no-deps` 等选项的行为见 [Docker Compose 官方说明](https://docs.docker.com/reference/cli/docker/compose/up/)。

## 固定版本、人工恢复与排错

更新器把当前安装选择写入 `/var/lib/workbuddy-updater/image.json`，并保存事务状态到同目录的 `state.json`（root 可读）。以后人工执行 Compose 时，把 `image.json` 放在文件列表最后，以保持已安装/已回滚的版本；否则原 Compose 文件的 `latest` 可能重新切换镜像：

**下面命令适用于 `image.json` 已存在的情况。** 标准安装流程首次启用、尚未执行过安装或回滚时，更新器不一定已生成这个文件。先用 `sudo test -f /var/lib/workbuddy-updater/image.json` 确认；不存在时不要照抄带该文件的命令。若必须在首次网页更新前手工重建，应显式固定当前运行镜像；「检查更新」已经可能把本地 `latest` 下载成新版。

```bash
cd /opt/workbuddy2api-panel
sudo docker compose -p workbuddy2api-panel -f docker-compose.yml -f docker-compose.web-update.yml -f /var/lib/workbuddy-updater/image.json up -d --no-deps --no-build --pull never wb2api
```

启用后，所有可能重建 WorkBuddy 的人工维护命令都必须包含原 Compose 文件和 `docker-compose.web-update.yml`，并保留已生成的镜像固定文件；只用原 Compose 文件重建会移除更新器连接。文件按 `-f` 顺序合并，详见 [Docker Compose 多文件说明](https://docs.docker.com/compose/how-tos/multiple-compose-files/merge/)。建议将实际项目名和完整文件列表保存成只由管理员维护的命令脚本。

若面板显示回滚失败，先查看日志和 `image.json`（回滚时写入旧镜像），修正导致失败的主机/Compose 问题，再使用上述命令恢复，最后 `sudo systemctl restart workbuddy-updater` 重试恢复检查。未完成的回滚会阻止新的网页更新。不要直接删除事务状态来跳过回滚。

```bash
sudo journalctl -u workbuddy-updater -n 100 --no-pager
sudo cat /var/lib/workbuddy-updater/state.json
sudo cat /var/lib/workbuddy-updater/image.json
sudo curl --unix-socket /run/workbuddy-updater/agent.sock http://localhost/status
docker logs --tail 100 workbuddy2api
```

网页无法连接更新服务时，检查 systemd 状态、挂载目录、容器的实际 GID 是否与 `socket_gid` 一致。更新器不在网页中返回 Docker 原始输出（可能包含 `.env` 插值的密钥），拉取失败时在宿主机手动执行 `sudo docker pull ghcr.io/haohaomin/workbuddy2api-panel:latest` 查看具体原因。

卸载时先停用服务 `sudo systemctl disable --now workbuddy-updater`，从补充 Compose 文件移除 socket 环境变量和挂载，并在原 Compose 文件设置希望继续运行的镜像版本，再重建服务。保留业务数据卷；删除更新器状态前先记录需要保留的镜像。

## 验证

```bash
python3 -m unittest discover -s scripts/docker-updater -p 'test_*.py' -v
go test ./internal/updater ./internal/panel
```

测试覆盖成功更新、拉取失败、容器启动失败回滚、回滚失败锁定、中断恢复、并发互斥、固定候选镜像、旧镜像自动清理和清理失败处理、HTTP 接口和鉴权。首次用于生产前，可在独立测试 Compose 项目验证容器切换及故障回滚。
