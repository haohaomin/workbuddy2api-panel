# 版本发布

不跟上游 `1.x`。推送到 `main` 后，`binaries` 工作流自动给本次提交打上海时间标签，构建、测试通过后创建 Release；不再需要手动打标签。本地仅 `git commit` 不会触发，必须 `git push origin main`。

工作流在同一次运行内完成打标签、构建和发布，不依赖机器人推送标签再次触发 Actions。失败可直接重跑：复用该提交的时间标签，继续上传草稿；已发布的 Release 不覆盖。多个发布串行，密集推送时 GitHub 会保留最新的待运行任务。同一分钟标签已被其他提交占用时，等待下一分钟，不覆盖旧标签。

所有发布入口共用 `binaries-release` 并发组，锁持续到 Latest 校验完成。先发布但不提升为 Latest，再重新读取已发布稳定版本、提升最大的时间版本并复核。失败重跑时，已发布版本只重试 Latest 校准，不重新上传资产。新增发布工作流也必须使用同一并发组；不要绕过工作流手动修改 Latest。

仍支持以下手动时间标签发布方式，通常无需使用。在 `main` 手动运行工作流也会发布，其他分支手动运行仅生成构建产物。仅改动 AutoBot 专用文件仍按工作流的 `paths-ignore` 跳过。

版本号是上海时间，形如 `v2026.9.26.711`：

- `2026.9.26` 是日期，月和日不补零
- `711` 是 7:11，时不补零、分两位、不带秒
- 标签、Release、二进制用同一个号；二进制里不带 `v`，面板会自己加
- 不要打 `v1.x` 标签，也不要手改 `appVersion`

```bash
# 注意：本机（Windows / git-bash）没有 tzdata，`TZ=Asia/Shanghai date` 会**静默回落 UTC**，
# 打出来的标签整整早 8 小时。用显式加 8 小时，兼容有无 tzdata 两种环境：
VERSION=$(TZ=Asia/Shanghai date +%Y.%-m.%-d.%-H%M)
[ "$(TZ=UTC date +%H)" = "$(TZ=Asia/Shanghai date +%H)" ] && VERSION=$(date -u -d '+8 hours' +%Y.%-m.%-d.%-H%M)
git tag "v$VERSION"
git push origin "v$VERSION"
```

本地构建不注入，面板显示 `dev`。手动同一分钟再次打标签会撞号；自动发布会等待下一分钟。
