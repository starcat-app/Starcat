---
name: starcat-cli-release
description: Starcat CLI 与 Homebrew Formula 联动发版流程。用于用户要准备、执行或排查 starcat-cli 的稳定版/预发布版，更新 CHANGELOG、运行 Go 发布门禁、创建版本 tag、触发 GitHub Release、验证多平台产物与 attestations，或确认 homebrew-starcat-cli Formula 和 Audit Action 是否同步成功的场景。
---

# Starcat CLI 发版

使用这个 skill 发布 `supports/starcat-cli`，并把稳定版 GitHub Release 与
`supports/homebrew-starcat-cli` Formula 当作同一个交付闭环。详细脚本、产物和
失败恢复方式见 `references/release-map.md`。

## 硬性规则

- 始终使用中文说明，命令、版本号、路径、环境变量和日志保持原文。
- 遵守根 `AGENTS.md`：先给方案并获得 dong4j 明确确认，再提交、推送、创建 tag
  或触发 Release。
- `starcat-cli` 与 `homebrew-starcat-cli` 是两个独立 Git 仓库，分别检查
  worktree、remote、branch 和最终提交。
- 不要手改 `internal/mcp.Version`；Release 构建通过 tag 和 `-ldflags` 注入版本。
- 不复用、不删除、不移动已发布 tag。产物错误时发布新的 patch 版本。
- 不打印 `HOMEBREW_TAP_TOKEN`；只核对 secret 名称是否存在。
- 预发布 tag 含 `-`，不会更新 Homebrew Formula；不要把这个预期行为报告成失败。

## 入口判断

| 用户意图 | 处理方式 |
|---|---|
| 发布稳定版 `X.Y.Z` | 更新 Changelog、推送 `main`、创建 `vX.Y.Z`，验证 Release、Formula 与 Audit |
| 发布预发布版 `X.Y.Z-rc.N` | 创建 prerelease，验证产物；明确跳过 Homebrew Formula |
| 只检查发布准备度 | 只读检查 branch、diff、tag、CI、secret 名称和 workflow，不创建 tag |
| Release 已失败 | 读取同一个 Action 日志，定位失败阶段；不要先重建或覆盖 tag |
| Formula 未更新 | 检查 token、Release 的 Formula step、tap 的 `origin/main` 和 Audit Action |

## 标准工作流

1. 读取 `references/release-map.md`。
2. 只读检查两个仓库：

```bash
git -C supports/starcat-cli status --short --branch
git -C supports/starcat-cli fetch origin main --tags
git -C supports/homebrew-starcat-cli fetch origin main
gh secret list --repo starcat-app/starcat-cli
gh release list --repo starcat-app/starcat-cli
```

3. 明确目标版本、稳定版/预发布版、Changelog 范围、tag 副作用和验证标准。
4. 获得确认后更新 `supports/starcat-cli/CHANGELOG.md`，保留空的
   `## Unreleased`，新增 `## vX.Y.Z - YYYY-MM-DD`。
5. 运行本地门禁：

```bash
go mod verify
go test ./...
go test -race ./...
go vet ./...
go run golang.org/x/vuln/cmd/govulncheck@v1.6.0 ./...
bash -n scripts/*.sh
```

6. 提交并推送 `main`，等待该精确 commit 的 `CI` Action 成功。
7. 确认本地和远端目标 tag 都不存在，再创建并推送版本 tag。
8. 等待目标 tag 对应的 `Release` Action 到终态。
9. 下载 Release 资产，在新临时目录验证 checksums、attestations、压缩包内容和
   本机架构二进制的 `starcat version`。
10. 稳定版继续验证 `homebrew-starcat-cli` 的 `origin/main` 和 `Audit Formula`
    Action；全部成功后才报告发布完成。

## Tag 签名

`RELEASING.md` 默认使用 signed tag。执行前先检查签名能力：

```bash
git config --get user.signingkey
git config --get gpg.format
```

签名可用时：

```bash
git tag -s vX.Y.Z -m "Starcat CLI vX.Y.Z"
```

签名不可用时不要静默降级。展示当前仓库既有 annotated tag 的事实，获得明确确认后
才可使用：

```bash
git tag -a vX.Y.Z -m "Starcat CLI vX.Y.Z"
```

## 稳定版 Homebrew 闭环

Release workflow 会在发布前检查 `HOMEBREW_TAP_TOKEN`，并在 Release 成功后调用
`scripts/render-homebrew-formula.sh` 更新 `homebrew-starcat-cli`。

验证至少包括：

- `Formula/starcat.rb` 的 `version` 等于目标版本；
- macOS/Linux 的 arm64/amd64 URL 都指向目标 Release；
- 四个 SHA256 与 Release `checksums.txt` 一致；
- Formula 的 `test do` 仍校验 `starcat version`；
- `Audit Formula` Action 对自动提交成功；
- 验证内容来自 tap 的 `origin/main`，不是可能停留在 `dev` 的本地工作树。

Release 已发布但 Formula 更新失败时，整体仍是未完成。修复 token、脚本或 tap
权限后，避免覆盖 Release/tag；按 `references/release-map.md` 的恢复流程处理。

## 完成标准

- 目标 tag 指向已经通过 CI 的 `main` release commit；
- GitHub Release 是非 draft，稳定版为 Latest，预发布版标记正确；
- 五个平台归档、`install.sh`、`install.ps1`、`checksums.txt` 均存在；
- `shasum -a 256 -c checksums.txt` 直接通过，checksum 路径不带构建目录前缀；
- Release 资产的 GitHub artifact attestations 验证通过；
- 本机架构二进制输出 `Starcat CLI vX.Y.Z`；
- 稳定版 Formula 已同步且 `Audit Formula` 成功。

不要把“仍在构建”“Release 成功但 Formula 未更新”或“本地 Formula 已改”报告成完整
发布成功。
