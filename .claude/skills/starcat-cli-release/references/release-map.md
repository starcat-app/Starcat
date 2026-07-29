# Starcat CLI 发版地图

## 目录与职责

| 路径 | 职责 |
|---|---|
| `supports/starcat-cli/CHANGELOG.md` | 稳定版和预发布版的公开变更记录 |
| `supports/starcat-cli/RELEASING.md` | 仓库级发布约定与 tag 规则 |
| `supports/starcat-cli/.github/workflows/ci.yml` | Go 质量门禁和五平台交叉编译 |
| `supports/starcat-cli/.github/workflows/release.yml` | tag 驱动的 Release、attestation 与 Formula 更新 |
| `supports/starcat-cli/scripts/build-all.sh` | 构建五个平台归档并注入版本 |
| `supports/starcat-cli/scripts/render-homebrew-formula.sh` | 从 Release checksums 生成 Formula |
| `supports/homebrew-starcat-cli/Formula/starcat.rb` | Homebrew 稳定版安装入口 |
| `supports/homebrew-starcat-cli/.github/workflows/audit.yml` | Formula style 与 strict audit |

## Release 触发与产物

Release workflow 只响应 `v*` tag，没有 `workflow_dispatch`。稳定版 tag 不包含 `-`，
预发布 tag 包含 `-`。

正式产物：

```text
starcat_vX.Y.Z_darwin_arm64.tar.gz
starcat_vX.Y.Z_darwin_amd64.tar.gz
starcat_vX.Y.Z_linux_arm64.tar.gz
starcat_vX.Y.Z_linux_amd64.tar.gz
starcat_vX.Y.Z_windows_amd64.zip
install.sh
install.ps1
checksums.txt
```

每个归档必须包含 `starcat`/`starcat.exe`、`LICENSE` 和
`THIRD_PARTY_NOTICES.md`。

## 版本来源

源码中的 `internal/mcp.Version` 保持 `dev`。`scripts/build-all.sh` 从
`GITHUB_REF_NAME` 获取版本，并用 Go `-ldflags` 注入。发版前不新增手工版本常量。

## 稳定版 Formula 自动更新

稳定版 Release 在发布前：

1. 验证 `HOMEBREW_TAP_TOKEN` 非空且不含空白；
2. checkout `starcat-app/homebrew-starcat-cli`；
3. 完成测试和产物构建；
4. 发布 GitHub Release；
5. 使用 checksums 渲染 `Formula/starcat.rb`；
6. 以 `github-actions[bot]` 提交并推送 tap 的 `main`。

Formula push 会触发 `Audit Formula`。因此完整成功链路为：

```text
CLI main CI
  -> CLI Release
  -> Formula 自动提交
  -> homebrew-starcat-cli Audit Formula
```

## 下载验证

在新临时目录执行：

```bash
gh release download vX.Y.Z --repo starcat-app/starcat-cli --dir <tmp>
cd <tmp>
shasum -a 256 -c checksums.txt
gh attestation verify starcat_vX.Y.Z_darwin_arm64.tar.gz \
  --repo starcat-app/starcat-cli
```

在 Apple Silicon Mac 解压 arm64 包并执行：

```bash
./starcat version
```

输出必须包含 `Starcat CLI vX.Y.Z`。

## 失败恢复

| 失败点 | 处理 |
|---|---|
| `main` CI 失败 | 修复并推送新 commit；旧 commit 不得打 tag |
| 目标 tag 已存在 | 不移动、不覆盖；选择新的 patch/预发布版本 |
| Release 构建失败 | 读取失败 run 日志；保留 tag，修复策略需由 dong4j 确认 |
| checksum 路径含 `dist/` | 修复生成逻辑并发布 patch，不能替换旧 Release 资产 |
| `HOMEBREW_TAP_TOKEN` 缺失 | 在 GitHub 配置只含 tap Contents 写权限的 token 后重试 |
| Release 成功、Formula step 失败 | 保留 Release/tag；修复 tap 权限或渲染脚本，不伪报完成 |
| Formula 已推送、Audit 失败 | 修复 Formula 并单独推送 tap，直到 Audit 成功 |
| 本地 tap 显示旧版 | fetch 并读取 `origin/main:Formula/starcat.rb`，不要只看当前 `dev` |
