---
name: starcat-release-readiness
description: 准备、修复并审计 Starcat macOS App 的 App Store 与 Direct 双渠道正式发版，固定 dev 整改、main 发布、数据库迁移收口、Changelog、测试、构建、签名、公证、GitHub Release、全工作区版本文档同步和人工验收门禁。用于“准备发版”“封版检查”“发布前审计”“发布后文档收口”或指定版本 readiness 检查；不用于普通 Debug 构建。
---

# Starcat 发版准备

以可验证证据把目标版本从 `dev` 整改到可发布的 `main`。默认只读审计；获得修复授权后只在 `dev` 改代码，最终发布只在 `main` 执行，不把测试通过等同于产物、人工或线上验收。

## 先确认权限边界

1. 区分“准备”“修复”“打包”“发布”四种授权：
   - 准备：只读检查、测试和普通构建。
   - 修复：先给方案，dong4j 明确说“开干 / 改吧 / 实施”等之后才能写文件。
   - 打包：只有当前消息明确要求时才能执行 `scripts/package-*` 或产生分发产物。
   - 发布：tag、push、上传、部署、公证提交、App Store 上传和 GitHub Release 各自需要当前任务明确授权。
2. Changelog、普通版本文档、官网部署与 `docs/功能实现总览.md` 使用各自独立授权；“准备发版”不自动授权写入或部署。
3. 不删除数据库、不要求用户删库重建，不覆盖工作区中的无关修改。

## 选择当前阶段

1. **`dev` 准备 / 修复阶段**：允许只读审计；获得修复授权后可修改代码、测试和发版文档。不得从 `dev` 打 tag、打正式包或发布。
2. **`dev → main` 过渡阶段**：全部自动门禁通过、工作区干净且获得分支操作授权后，才按现行分支规范合并并切换到 `main`。发现分叉、未知修改或未跟踪文件时停止。
3. **`main` 最终发布阶段**：重新验证 HEAD、版本和工作区；获得对应授权后再执行 App Store / Direct 发布。若发现代码问题，返回 `dev` 修复，禁止直接在 `main` 开展日常整改。
4. **发布后文档收口阶段**：公开版本事实确认后，区分已发布版本与下一待发布版本，审计整个 Starcat 目录下的独立仓库；获得文档授权后同步版本说明，官网部署仍需单独授权。
5. 分支过渡、最终发布、本地 GitHub Release 和发布后文档收口的详细步骤读取 [references/release-execution.md](references/release-execution.md)。

## 读取当前真值

在 Starcat 仓库根目录工作，并优先读取当前版本的下列文件，避免复制过时流程：

- `AGENTS.md`
- `BRANCH.md`
- `docs/功能实现总览.md`（只读）
- `docs/3-设计/详细设计/01-数据库设计.md`
- `docs/5-规范/Git-分支与Worktree规范.md`
- `docs/5-规范/Changelog-更新规范.md`
- `docs/5-规范/版本迭代规范.md` 与目标版本 Checklist（如已建立）
- `docs/6-发版与上架/SOP-双渠道签名与发布.md`
- `docs/6-发版与上架/SOP-手动发布命令清单.md`

`docs/6-发版与上架/SOP-发版流程.md` 可用于理解历史版本机制，但双渠道命令和授权边界以上述现行 SOP 为准。

## 执行门禁

读取 [references/gates.md](references/gates.md)，按顺序检查：

1. 仓库、分支、worktree、dirty 状态和独立 `supports/*` 仓库。
2. 目标版本、上一个正式 tag、提交范围和远端 tag 冲突。
3. 数据库迁移发布边界与同版本迁移收口。
4. 目标版本 Checklist 的未完成/未验收项、每轮依赖与二进制版本检查结果，以及四份 Changelog 的版本状态、双语和渠道差异；清单作为主要日志素材，相关仓库提交用于补漏，未经授权不写日志。
5. 单测、普通构建、脚本静态检查和必要的迁移测试矩阵。
6. 获得授权后才检查分发产物、签名、公证、Store archive / 本地 export pkg 或 Direct DMG。App Store 正式包必须显式使用 `/Applications/Xcode.app/Contents/Developer` 中的正式版 Xcode；Beta、RC 或 Preview 立即记为 `BLOCKED`。Automatic Signing 的 archive 是中间产物；App Store 最终签名门禁以 `destination=export` 生成并解包验证的 pkg 为准。
7. Direct 完整发布授权需包含 GitHub Release：先生成最终 DMG/SHA256 和本地 appcast，再由发布脚本通过本机 gh 上传、回读校验并公开附件，最后发布官网 appcast；不使用 GitHub Actions，也不再向阿里云上传 DMG/SHA256。
8. 公开版本事实确认后读取 [references/version-document-sync.md](references/version-document-sync.md)，审计并同步全工作区版本文档；不得把历史版本、兼容逻辑或下一待发布版本一起全局替换。
9. 单独记录人工 UI、真实账户、升级迁移和线上发布验收。

## 输出格式

每项只使用以下状态：

- `PASS`：已经用当前证据验证。
- `WARN`：不直接阻断，但需要确认或后续验收。
- `BLOCKED`：进入下一发版阶段前必须解决。
- `NOT RUN`：未执行，不能暗示已通过。

报告必须包含：目标版本、下一待发布版本、渠道、当前分支与基线、阻断项、证据、未执行项、下一步授权。分别说明代码/测试、构建、分发产物、版本文档、本地生成文件、官网部署、人工验收和线上状态。
