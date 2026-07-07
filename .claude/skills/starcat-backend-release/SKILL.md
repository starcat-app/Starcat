---
name: starcat-backend-release
description: Starcat supports 子项目后端 API 发布流程。用于用户要发布、打 tag、创建 PR、合并、部署或排查 supports/starcat-sharing-api、trending-api、weekly-api、wiki-api、recommend-api、discovery-api 等独立后端仓库的 release/deploy 脚本、GitHub Actions 和 Fly.io 发布链路。
---

# Starcat 后端 API 发布

使用这个 skill 处理 `supports/starcat-*-api` 独立后端仓库的发布流程。它不同于主 App 的 `starcat-release`，也不同于日常 Fly 运维的 `starcat-supports-ops`。

## 硬性规则

- 先只读检查，再说明发布计划；等 dong4j 明确确认后才能执行 `deploy.sh`、`git push`、`gh pr merge`、`git tag`。
- 发布脚本会影响 GitHub PR、tag、GitHub Actions 和 Fly deploy，不要在未确认时运行。
- 默认不要删除远端 tag 或强推。
- 工作区必须干净；发现无关 dirty files 时停止并说明。
- 不要把主 App 的 `scripts/release-direct.sh` 用到 supports 子项目。

## 入口选择

| 项目 | 发布入口 | 说明 |
|---|---|---|
| sharing/trending/weekly/wiki | `supports/<project>/scripts/deploy.sh vX.Y.Z` | 完整 PR -> merge -> tag -> Actions/Fly 流程 |
| recommend | `supports/starcat-recommend-api/scripts/deploy.sh vX.Y.Z` | 先跑 Go 测试/构建，再本地 tag + push tag |
| discovery | `supports/starcat-discovery-api/scripts/deploy.sh vX.Y.Z` | 直接 `fly deploy -a starcat-discovery-api --build-arg VERSION=...` |

如果用户没说明具体服务，先问服务名和目标版本号。版本必须是 `vX.Y.Z`。

## 标准工作流

1. 读取 `references/backend-release-map.md`。
2. 进入目标 supports 子项目目录。
3. 只读检查：
   - `git status --short`
   - `git branch --show-current`
   - `git tag --list 'v*' --sort=-v:refname | head`
   - `gh auth status`
4. 先跑 dry-run，适用于 sharing/trending/weekly/wiki：
   - `./scripts/deploy.sh --dry-run vX.Y.Z`
5. 说明脚本将创建 PR、合并、切 main、打 tag、push tag，并触发 CI/Fly。
6. 等确认后执行真实发布。
7. 发布后检查 GitHub Actions 和 Fly 状态。

## 关键约束

- sharing/trending/weekly/wiki 的 tag 必须在 PR merge 后创建，指向 main 的 merge commit。
- 不允许在 main/master 上运行共享 deploy 脚本。
- 不能用 squash merge，否则会丢失 dev 上多个 commit 信息。
- 推 tag 后必须等 Go workflow 成功，Fly deploy/release 才会继续。
- recommend/discovery 的脚本更简单，不等同于共享 deploy 流程，使用前必须先读脚本。

## 验证

- GitHub：PR 已合并，tag 存在且指向 main 期望 commit。
- Actions：Go workflow 通过，后续 Fly deploy/release 按预期触发。
- Fly：`fly status -a <app>` 和 `curl https://<app>.fly.dev/healthz` 正常。

## 参考

详细项目差异、命令和失败恢复见 `references/backend-release-map.md`。
