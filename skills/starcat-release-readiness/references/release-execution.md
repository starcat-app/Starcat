# Starcat 发版执行阶段

只在需要分支过渡、打包或发布时读取。准备审计本身不授权执行本文件中的写操作。

## 1. `dev` 准备与修复

- 日常发版整改只在 `dev` 进行，包括数据库迁移收口、并发警告、测试和发版文档。
- 每次写入前确认当前分支仍是 `dev`，并保留未知 dirty / untracked 内容。
- 进入下一阶段前至少满足：迁移矩阵、全量测试、App Store / Direct 全新 Release 构建、脚本静态检查均通过；四份 Changelog 已审计；人工验收缺口已明确列出。
- 整改完成后使用聚焦提交，不把无关文件带入提交。没有 push 授权时只保留本地提交。

## 2. 从 `dev` 过渡到 `main`

执行前重新读取 `BRANCH.md` 和 `docs/5-规范/Git-分支与Worktree规范.md`，并核对：

```bash
git status --short --branch
git branch --show-current
git worktree list --porcelain
git fetch --prune
git rev-list --left-right --count main...dev
git log --oneline --left-right main...dev
```

只有当前工作区干净、`dev` 已提交、远端状态明确且 dong4j 已授权分支操作时才能继续：

```bash
git switch main
git merge --ff-only dev
```

- 如果 `main` 与 `dev` 分叉，停止并报告，不能擅自 rebase、强制合并或改写历史。
- 切换或合并长期分支时按项目规范同步 `BRANCH.md`，并报告当前分支、用途、基线、worktree、状态和后续归宿。
- `git push origin main` 是独立远端写操作；只有最终发布授权明确包含 push 时才能执行。
- 到达 `main` 后重新核对 HEAD、目标版本、tag 冲突和工作区。发现代码问题必须返回 `dev` 修复。

## 3. `main` 最终发布

App Store 与 Direct 是独立门禁：

- App Store：在 `main` 显式设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 后运行 `scripts/package-appstore.sh`。脚本默认只生成 archive，且必须在删除旧产物前拒绝 Beta、RC、Preview 或非标准路径 Xcode。Automatic Signing 的 archive 可以使用 Apple Development 签名；不要把 archive 中间态误判为最终分发签名失败。
- App Store 本地打包但不上传：在 `main` 使用 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer STARCAT_APPSTORE_EXPORT=1 STARCAT_APPSTORE_ALLOW_PROVISIONING_UPDATES=1 STARCAT_APPSTORE_SKIP_OPEN=1` 运行 `scripts/package-appstore.sh`。脚本固定 `destination=export`，生成 `dist/appstore/export/Starcat.pkg`，并解包验证主 App、Widget、`codebase.bin`、Store profile、Installer 与深度签名。
- App Store 线上门禁：Validate、Upload 和 App Store Connect processing 分别验收；本地 export 成功不授权也不等于已经上传。
- Direct：`STARCAT_NOTARIZE=1 ./scripts/release-direct.sh <X.Y.Z>` 负责 tag、官网、notarized DMG、Sparkle appcast、上传和线上校验。
- 运行任何真实命令前再次确认当前消息授权了对应的 push、tag、打包、公证、部署和上传动作。
- 一个渠道成功不能代替另一个渠道，也不能代替人工升级、OAuth、支付或线上更新验收。

## 4. Direct GitHub Release 与 appcast 顺序

获得完整发布授权后，统一运行 `release-direct.sh`；GitHub 发布已经集成进脚本，
不再在 Direct 完成后另行运行 `gh release create`。

1. 公证并 staple 最终 DMG，计算 SHA256，生成当前版本 appcast 并合并本地历史。
2. 通过本机 `gh` 创建 `starcat-app/Starcat` 同版本草稿，上传 DMG/SHA256。
3. 下载真实附件并验证 SHA256，全部一致才公开 Release；不使用 GitHub Actions。
4. 部署官网页面，确认 GitHub 下载可用后上传 appcast，最后验证各公开地址。

DMG/SHA256 只上传 GitHub。appcast 仍由 `https://starcat.ink/appcast.xml` 提供，
避免已发布客户端失去更新入口。appcast 可以先在本地生成，不能在附件就绪前对外公布。

上传中断后保留最终产物，按已有发布授权续跑：

```bash
STARCAT_NOTARIZE=1 STARCAT_RELEASE_SKIP_TAG=1 STARCAT_RELEASE_REUSE_ARTIFACTS=1 \
./scripts/release-direct.sh X.Y.Z
```

- 复用路径不重新打包或 staple；DMG/SHA256/appcast-current 必须完整。
- 草稿仅补缺失附件；已有附件下载核验一致后复用，禁止 `--clobber`。
- 已公开且一致的版本只回读；同名内容冲突或已公开版本缺失附件时停止，不继续发布 appcast。
- Release、官网、Sparkle、Homebrew 和 App Store 状态仍分别报告。

## 5. 发布后版本文档收口

只有公开版本事实已经由 tag、appcast、DMG、GitHub Release 和 Homebrew 等实际发布面验证后，才把它写成“当前版本”或“最新版”。完整范围、源文件和派生文件读取 [version-document-sync.md](version-document-sync.md)。

1. 确定 `PUBLISHED_VERSION`、`PREVIOUS_VERSION` 和 `NEXT_PENDING_VERSION`，先报告三者，不从 `project.yml` 的兜底值推断公开版本。
2. 在任何写入前记录主仓库与全部嵌套 Git 仓库的分支、HEAD、dirty 和 untracked 状态；未知修改只能保留和报告。
3. 使用 skill 内只读脚本扫描旧版“当前 / 最新 / 下载”语义落点：

   ```bash
   <skill-dir>/scripts/audit-version-docs.sh \
     /Users/dong4j/Developer/1.AI/ai-incubator/Starcat \
     <PUBLISHED_VERSION> \
     <PREVIOUS_VERSION>
   ```

4. 获得普通版本文档授权后先更新生成源 `supports/scripts/sync-starcat-readme-promo.py`，再运行该项目脚本同步 marker 管理的 README；运行前后逐仓库比较状态，禁止覆盖 marker 外内容。
5. 单独同步不由推广脚本生成的根 README、Issue 模板、starcat-site 双渠道 Changelog、组织 profile、用户文档发布摘要和官网正式 / 测试页 fallback。Changelog 和 `docs/功能实现总览.md` 仍要求各自授权。
6. 对每个改变的独立仓库执行 `git diff --check`，检查中英文语义、版本、下载 URL、build、size 与 appcast 一致；重新运行只读审计脚本，旧版 stale candidate 必须归零。
7. 只有获得官网部署授权后才部署生成页面。文件已更新、仓库已提交、远端已 push、官网已部署和公网已验证是五个独立状态。

版本文档尚未收口时，发版产物可以报告已发布，但整个发版任务必须明确标记文档阶段为 `BLOCKED` 或 `NOT RUN`，不能报告“全部完成”。
