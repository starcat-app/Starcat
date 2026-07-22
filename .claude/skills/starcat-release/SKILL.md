---
name: starcat-release
description: Starcat macOS App 专用发版流程。用于用户要发布或排查 Starcat 发版、Direct 分发、DMG 打包、Sparkle appcast 生成或上传、starcat.ink 官网与 changelog 部署、notarization、公版 tag 处理，或询问 scripts/release-direct.sh、scripts/release.sh、package-direct.sh、build-dmg.sh 应该如何选择和运行的场景。
---

# Starcat 发版

使用这个 skill 选择并执行正确的 Starcat 发版路径。Starcat 当前有两个含义不同的发版入口；不要把通用 macOS 发版流程当成本仓库的权威流程。

## 硬性规则

- 始终用中文回复，并遵守仓库 `AGENTS.md`：先给方案并征求 dong4j 明确确认，再修改文件或运行有副作用的发版命令。
- 除非用户在当前对话中明确说“开干 / 执行 / 发布 / GO / 动手”，否则不要运行真实发布、部署、上传、`git tag`、`git push`、`rsync`、`ssh`、notarization 或 appcast 写入命令。
- 排查时先使用只读命令：`git status`、`git tag`、`git ls-remote`、`--help`、读取文件，以及脚本 dry-run 模式。
- 不要为了发版手动修改 `project.yml` 里的版本号字段。Starcat 的版本来自 git tag 和构建脚本。
- 修改发版代码时不要写“兼容旧版本 / 数据迁移 / 保留旧路径”逻辑；本项目未上线，`AGENTS.md` 明确禁止兼容路径。
- 保留无关未提交文件。工作区不干净时，先判断这些改动是否与发版任务相关，再提出下一步。

## 入口选择

先判断用户要走哪条路径：

| 用户意图 | 使用入口 | 原因 |
|---|---|---|
| Direct 公开发布、Sparkle 更新、starcat.ink 部署、上传 DMG/appcast | `scripts/release-direct.sh <X.Y.Z>` | Direct 渠道完整编排入口 |
| 本地/基础/内测发版、tag + 内测 DMG + 可选 push tag | `scripts/release.sh vX.Y.Z` | 基础发版入口，底层调用 `build-dmg.sh` |
| 只在本地构建 Direct 包 | `scripts/package-direct.sh <X.Y.Z>` | 构建 `StarcatDirect` DMG，可选 notarization/appcast |
| 只在本地构建内测 DMG | `scripts/build-dmg.sh <X.Y.Z>` | 构建 ad-hoc/内部 DMG，输出到 `build/dmg/` |

如果用户只说“发版”但没有说明渠道，先问是 Direct 公开发布还是基础/内测 DMG 发布。如果用户提到 `starcat.ink`、Sparkle、appcast、notarization、上传或公开用户，可以推断为 Direct，但仍需先给方案并确认再执行。

## 标准工作流

1. 需要细节时先读 `references/release-map.md`。
2. 用只读命令检查当前状态：
   - `git status --short`
   - `git branch --show-current`
   - `git tag --sort=-creatordate | head`
   - Direct 发版可补充：`scripts/release-direct.sh --help`
3. 说明选择的入口、前提假设、副作用和验证标准。
4. 除非用户当前轮已经明确授权执行，否则先等确认。
5. 真实发布前优先 dry-run：
   - Direct：`STARCAT_RELEASE_DRY_RUN=1 ./scripts/release-direct.sh <X.Y.Z>`
   - 基础发版：`./scripts/release.sh v<X.Y.Z> --dry-run`
6. 执行已确认的命令后，验证产物和 URL，并报告精确路径。

## Direct 公开发布

Direct 分发使用 `scripts/release-direct.sh <X.Y.Z>`。它会执行：

1. 分支和干净工作区检查；
2. 创建并推送 tag；
3. 部署 nginx 配置；
4. 生成官网 changelog 并部署静态页面；
5. 带 `STARCAT_GENERATE_APPCAST=1` 调用 `package-direct.sh`；
6. 上传 DMG/SHA；
7. 合并并上传 appcast；
8. 校验线上 URL。

正式公开发布命令：

```bash
STARCAT_NOTARIZE=1 ./scripts/release-direct.sh 1.1.0
```

演练命令：

```bash
STARCAT_RELEASE_DRY_RUN=1 ./scripts/release-direct.sh 1.1.0
```

tag 已存在时重跑：

```bash
STARCAT_RELEASE_SKIP_TAG=1 ./scripts/release-direct.sh 1.1.0
```

只重跑 Direct 更新文件发布：

```bash
STARCAT_RELEASE_SKIP_TAG=1 \
STARCAT_RELEASE_SKIP_NGINX=1 \
STARCAT_RELEASE_SKIP_SITE=1 \
./scripts/release-direct.sh 1.1.0
```

## 基础/内测发版

仅当用户需要基础 tag + DMG + push 流程时使用 `scripts/release.sh vX.Y.Z`。它的关键安全属性是“先本地 tag，再构建 DMG，最后 push tag”，因此构建失败不会污染远端 tag。

```bash
./scripts/release.sh v1.1.0 --dry-run
./scripts/release.sh v1.1.0
```

本地试跑用 `--skip-push`。只有用户明确要 tag-only 行为时才使用 `--skip-dmg`。

## 验证标准

Direct 发布后验证：

- 本地 DMG 存在：`dist/direct/downloads/Starcat-<version>-arm64.dmg`；
- SHA 文件存在于 DMG 同目录；
- 当前版本 appcast 存在：`dist/direct/downloads/appcast-current.xml`；
- 合并后的 appcast 存在：`supports/starcat-site/direct/appcast.xml`，且引用新 DMG 和新版本号；
- 线上 URL 可访问：
  - `https://starcat.ink/appcast.xml`
  - `https://starcat.ink/downloads/Starcat-<version>-arm64.dmg`
  - `https://starcat.ink/changelog.html`

基础发版后验证：

- DMG 存在：`build/dmg/Starcat-<version>-arm64.dmg`；
- SHA 文件存在于 DMG 同目录；
- 本地或远端 tag 状态符合用户确认的参数。

## 修改发版文档或脚本时

- 先检查 `docs/功能实现总览.md`、`docs/6-发版与上架/SOP-发版流程.md` 和相关脚本。
- 保持修改范围窄；只有行为契约变化时才同步更新文档。
- 如需更新进度文档，遵守 `AGENTS.md` 的 checkbox 和 `> 实现:` 规则。
- 修改 shell 脚本后用 `bash -n <script>` 验证语法。
- 修改 Python 脚本后用 `python3 -m py_compile <script>` 验证语法。

## 参考资料

读取 `references/release-map.md` 可查看脚本职责、环境变量、失败恢复方式和已知文档漂移点。
