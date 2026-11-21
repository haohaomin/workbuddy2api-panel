---
name: workbuddy-sync-release
description: "为 haohaomin/workbuddy2api-panel 同步上游功能与修复，排除 AutoBot，保留个人扩展，验证并按授权提交、推送和确认 GitHub 云端发布。用于此仓库的上游同步或同步后发布请求，不用于更新运行中的服务器。"
---

# WorkBuddy 上游同步与发布

本文件是仓库内同步与发布流程的维护入口，根目录 `AGENTS.md` 要求此类任务读取并遵守本技能。本机个人技能只负责定位这份文件；修改流程时在此更新并随仓库提交。

## 仓库与范围

- 工作区使用当前任务指定的 checkout；先核对 remote，不能依赖某台机器的绝对目录。
- `origin`：`https://github.com/haohaomin/workbuddy2api-panel.git`。
- `upstream`：`https://github.com/misakano7545/workbuddy2api-panel.git`，同步目标通常为 `upstream/main`。
- 此用户的「远程与云端」指推送个人 fork 并完成 GitHub Actions 构建发布，不包括更新阿里云 Docker 服务或本机 App。
- 依据当前请求和会话授权决定是否提交、推送、发布。明确要求「同步上游、提交到远程与云端」时包含上述步骤，无需再问同一权限；只问方案或仅要求本地同步时，不自动扩大到发布。

## 同步与冲突处理

1. 读取适用的 `AGENTS.md`，记录当前 HEAD、分支、暂存/未暂存改动和远程差异。保留已有用户改动；混杂时使用合适的隔离 checkout，不以 reset 或覆盖整个文件来清理用户工作。
2. fetch 两个远程，固定本次上游 SHA。用合并基点与逐提交 diff 看新增内容：`git diff main...upstream/main` 是上游新增范围；`git diff main..upstream/main` 还包含 fork 的长期差异，不能把它当待同步文件清单。
3. 留意历史 cherry-pick：`git cherry main upstream/main` 辅助查重复，但经冲突适配的补丁可能显示为未应用，需对照历史和实际代码。不要仅凭 `main..upstream/main` 再次移植已吸收的提交。
4. 优先正常三方合并，例如在干净工作树执行 `git merge --no-ff --no-commit <本次上游SHA>`，保留上游祖先关系，方便以后增量同步。需要选择性移植时记录原始 SHA 和跳过原因。
5. 排除 AutoBot 的新增和修改，保持这些路径同步前的状态（之前不存在的继续不存在）：`AutoBot.yml`、`scripts/autobot.py`、`.github/workflows/autobot.yml`、`.github/autobot-skills/**`，以及本次审查发现的其他 AutoBot 专用文件或混合文件中的相关片段。不要把正常业务的自动签到、任务排程、自动更新误判为 AutoBot；不要为了排除机器人而删除工作流全部内容。
6. 对每处冲突比较合并基点、fork、上游三方。仅在确认整个文件没有 fork 独有差异时才整文件采用上游版本。README 保留本仓安装与部署结构，补入新接口、开关和实际边界，避免恢复整份上游文档覆盖个人说明。

## 必须保留的 fork 行为

- 客户端更新源、Release 下载/API 回退和 GHCR 部署镜像使用 `haohaomin/workbuddy2api-panel`。Go module/import 与原作者版权归属保留，禁止批量替换作者仓库名。
- macOS App、官方 WorkBuddy 图标、桌面更新与回滚、Windows 配置目录、Docker 网页更新器、公网部署模板及用户已有配置。不能因上游没有这些文件就删除。
- 更新器按部署能力启用自动安装，保留 `CanInstall` 判断、启动就绪校验和本仓更新源。调度测试需显式设置可安装前提，不能为通过上游的 `dev` 测试而放开生产部署限制。
- 保留本仓 `.agents/skills/workbuddy-sync-release/`、根目录 `AGENTS.md` 的技能入口与对应 `.gitignore` 例外；这些是本仓维护规则，与 AutoBot 技能无关。
- 不跟随上游 `v1.x`，不手改 `appVersion`，不因为 fetch 看到新标签就向 origin 推送这些标签。
- 发布规则以当前 `AGENTS.md` 为准：推送 `main` 自动按上海时间打标签并在同次 workflow 中测试、构建、发 Release；标签形式如 `v2026.9.26.711`。不另外手工打标签或绕过工作流改 Latest。
- GitHub Release 发布入口共享 `binaries-release` 锁直至 Latest 复核；已发布资产不覆盖，重跑复用该提交的标签。GHCR 是独立工作流，必须单独确认成功。

## 验证、提交与云端验收

- 检查暂存 diff、未解决冲突与 `git diff --check`；核对 AutoBot 文件、发布配置及 fork 更新源未回退，测试不使用真实账号或触发收费探针。
- 默认运行 `go test ./...`；按本次改动和现有 CI 运行官方头 parity、发布脚本、Docker 更新器测试。涉及共享状态时按需要补 `-race`；改桌面更新代码才额外跑相关 macOS 测试。不要为纯文档改动增加无意义测试。
- 现有检查入口（以工作流当前内容为准）：
  ```bash
  WB2A_PARITY=1 go test ./internal/upstream -run TestOfficialParity -v
  python3 tests/test-release-version.py
  python3 tests/test-release-latest.py
  python3 -m unittest discover -s scripts/docker-updater -p 'test_*.py'
  ```
- 测试失败先定位：适配 fork 差异或修复同步造成的问题后重跑相关检查，不删除断言掩盖回归。不因检查过一次就宣称真实第三方接口也已验证。
- 提交信息说明同步目标和排除项，例如 `Merge upstream/main excluding AutoBot`，正文记录上游 SHA 与必要的冲突取舍。推送前确认 origin 没有新提交；若有，先合入与验证，禁止强推 main。
- 已授权远程发布时执行 `git push origin main`，用推送的完整 SHA 查找 `binaries`、`docker-ghcr` 运行，不能把旧任务成功当成本次成功。
- 持续检查本次构建到终态，使用紧凑的 `gh run view --json`，间隔约 30–60 秒并报告有意义的进展。勿每几秒输出整份相同日志。
- 失败先读失败日志；明确的临时 runner/网络故障可重跑失败任务一次，若同因再失败则报告具体阻碍，避免无限重跑。代码失败修复验证后提交推送新 SHA。发布后的 Latest 问题也走工作流恢复，不能手动改 Latest。
- 成功后读取该提交的时间标签、正式 Release、资产与 Latest，核对更新清单属于该版本；确认 GHCR 构建已成功推送镜像。Release 包和容器镜像分别描述，镜像不是 Release 附件。
- 若没有待同步改动且本次 HEAD 已成功发布，直接报告已最新，不制造空提交或重复发版。

## 交付

用中文简要说明：上游同步到哪个 SHA、主要新增能力、是否有冲突及如何处理、AutoBot 排除情况、提交 SHA、验证结果、Release 链接和两条云端工作流状态。有未完成项如实列出，不把「已触发」写成「发布成功」。
