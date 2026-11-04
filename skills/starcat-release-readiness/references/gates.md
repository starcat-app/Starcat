# Starcat 发版门禁

## 1. 仓库与版本边界

- 读取 `BRANCH.md`，再用 Git 核对当前分支、HEAD、worktree 和远端跟踪关系。
- 检查主仓库及本次涉及的每个独立 `supports/*` 仓库，不能用主仓库状态代替子仓库状态。
- 列出 dirty 与 untracked 内容并判断归属。未知或无关内容只能报告，不能整理、暂存、删除或覆盖。
- 确认目标版本符合 SemVer，定位上一个已正式发布 tag，并比较 `<previous-tag>..HEAD`。
- 检查本地和远端目标 tag 是否已存在。没有 tag 不代表已获得创建或 push 权限。
- 准备和修复在 `dev` 完成；`dev` 尚未进入 `main` 时不能进行最终发布。全部门禁通过后按 [release-execution.md](release-execution.md) 进入分支过渡阶段，不能静默替用户合并。

## 2. 数据库迁移收口

以“上一个真正对外发布的版本”为 schema 边界，而不是以开发期 migration 数量为边界。

### 2.1 识别迁移集合

1. 从上一个正式 tag 读取 `DatabaseMigrationsV1.registerAll` 和所有 `registerMigration` 名称，得到已发布最高迁移 `vN`。
2. 从当前 HEAD 读取同一列表，得到本次版本新增的 migration 名称和代码。
3. 检查 App Store、TestFlight、公开 Direct DMG 或其他外部分发记录；如果某个迁移已经随外部构建落地，不能仅凭“没有正式 tag”判断可安全删除。
4. 已随正式版发出的 `v1...vN` 必须冻结并保持顺序，禁止回写 `v1-initial` 或修改历史 migration 语义。

### 2.2 同一版本压缩规则

- 同一个尚未发布版本开发期间可以连续增加多个临时 migration，方便本机迭代。
- 封版时，如果正式 tag 之后存在多个尚未发布 migration，默认标记为 `BLOCKED`，压缩为唯一的 `v(N+1)` 后才能通过。
- “一个迁移”指一个新的 GRDB migration 标识；实现可以调用多个按功能拆分的私有 helper，避免形成巨型函数。
- Starcat 当前 GRDB 支持 `registerMigration(_:merging:migrate:)`。收口开发期 migration 时优先使用该 API，不手工增删 `grdb_migrations`。
- 正式 migration 使用新的语义化 identifier，并把全部开发期 identifier 放入 `merging:`；不要把正式 identifier 命名成被合并集合的第一个 identifier。
- merged migration 根据闭包收到的 `appliedIdentifiers` 只执行尚未应用的 helper：正式版旧库执行全部，部分开发库补齐缺口，完整开发库只收敛 identifier。
- 合并后的 migration 必须直接描述从上一正式版本到当前最终 schema 的变化，不能要求正式用户依次经历开发期中间状态。
- 依赖未创建表的兼容步骤必须安全 no-op；不得因为某个旧版本没有开发期表而启动失败。
- 不要为了压缩编号而丢掉一次性数据搬迁、索引重建、触发器重建或兼容逻辑。

示例：若正式版最高为 `v18`，开发分支为同一待发布版本增加了 `v19...v26`，封版结果应原则上只新增一个 `v19`；内部可继续保留 Agent、RAG、通知和活动数据等 helper。

### 2.3 开发数据库收敛

- 本机或测试数据库可能已经记录被压缩掉的开发期 migration 名称。最终代码必须让这些数据库安全收敛到相同 schema，不能要求删库。
- 优先让新的正式 migration 通过 `appliedIdentifiers` 分派 helper，并在 helper 内使用 `tableExists`、列检查、`ifNotExists` 和有条件数据更新保持安全。
- 开发期可用 `repairPrelaunchDevelopmentSchema` / `ensurePrelaunch*` 修补草稿结构；正式收口时应把正式用户需要的升级逻辑放进唯一 `registerV(N+1)`，并移除不再需要的永久启动旁路。
- 区分用户数据与可重建缓存。任何收口都必须保留 tags、notes、状态、Agent 历史等用户数据。

### 2.4 必测矩阵

至少验证：

1. 空数据库运行全部 migration 后得到最终 schema。
2. 上一个正式版本数据库只运行新的唯一 migration 后得到最终 schema。
3. 上一个正式版本的代表性用户数据在升级后仍存在且可解码。
4. 已执行开发期临时 migrations 的数据库再次启动可以收敛，不重复建表、不重复搬迁、不丢数据。
5. `registerAll` 中已发布 migration 未被改写，当前版本只保留预期的新 migration 标识。

迁移测试未覆盖空库、正式版升级和数据保留时，状态至少为 `BLOCKED`；仅有“表能创建”的测试不够。

## 3. Changelog

- 检查以下四份 Markdown（2026-11 起随 starcat-site 同仓维护，见 Starcat#202）：
  - `supports/starcat-site/appstore/CHANGELOG.md`
  - `supports/starcat-site/appstore/CHANGELOG-ZH.md`
  - `supports/starcat-site/direct/CHANGELOG.md`
  - `supports/starcat-site/direct/CHANGELOG-ZH.md`
- 主仓库根 `CHANGELOG.md` / `CHANGELOG-ZH.md` 只是指针文件；若发现被写入条目或拷入构建产物，直接判 FAIL
- 准备阶段目标版本保持 `X.Y.Z-待发布`；改成正式标题、生成网站 HTML 或部署必须单独授权。
- 公共功能四份语义对齐；App Store 和 Direct 专属能力只出现在对应渠道。
- 检查目标版本以来的提交、用户可感知结果和 `Release-Note:`，列出缺漏但不自动补写。

## 4. 测试与普通构建

- 跑测前确认 Xcode IDE 已退出，避免抢占 `testmanagerd`。
- 新增或删除 Swift 文件后先执行 `xcodegen generate`，并检查生成结果是否产生意外 diff。
- 至少运行数据库迁移 suite 和全量测试。失败时保留原始失败信息，区分环境、已知问题与产品回归。
- 对 App Store 与 Direct 分别执行不产生分发包的 Release 构建或等价 scheme 检查，验证渠道编译隔离。
- 发版整改要求清理 Starcat 源码中的 Swift 6 actor isolation、Sendable 和 capture 警告；不要用 `@unchecked Sendable`、`@preconcurrency` 或关闭严格并发检查来掩盖问题。
- 需要确认警告是否真正归零时，使用新的临时 DerivedData 进行完整 Release 编译，不能只依赖增量缓存。
- 对本次涉及的 shell / Python 发布脚本只做静态或 dry-run 检查；不要把 dry-run 表述成真实签名、公证或上传成功。

## 5. 分发产物与人工验收

- 未获得当前消息中的打包授权时，App Store archive、Direct DMG、notary 提交和上传全部记为 `NOT RUN`。
- App Store archive / export 前必须显式设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，记录 `xcodebuild -version` 的 version 与 build；任何 Beta、RC、Preview 或非标准路径 Xcode 都记为 `BLOCKED`。脚本必须在删除旧产物前执行该门禁。
- 获得授权后分别检查 Bundle ID、`STARCAT_DISTRIBUTION`、entitlements、嵌套签名、Sparkle 隔离、StoreKit / Creem 隔离、版本号和 build 号。
- 测试和构建不能证明真实 OAuth、GitHub App、Keychain、通知、RAG 外部 CLI、Sparkle 更新、StoreKit、Creem 或数据库升级体验已经通过。
- 人工验收必须记录测试设备、来源版本、目标版本、渠道和结果；没有证据时记为 `NOT RUN`。
- tag、push、GitHub Release、App Store 上传、官网部署和 Direct 上传分别报告，不用一个“已发布”覆盖所有状态。
- Direct 由 `release-direct.sh` 集成本机 GitHub 发布：先生成本地 appcast，上传草稿 DMG/SHA256 并回读校验后公开，最后发布官网 appcast。草稿可补缺失附件；已有附件内容冲突时停止，禁止 `--clobber`。不使用 GitHub Actions，不再向阿里云上传 DMG/SHA256。

## 6. 发布后版本文档收口

- 公开 tag、appcast、Direct DMG、GitHub Release 和 Homebrew 中的版本事实确认后，读取 [version-document-sync.md](version-document-sync.md)。
- 分别记录 `PUBLISHED_VERSION` 与 `NEXT_PENDING_VERSION`。前者用于“当前版本 / 最新版 / 下载地址”，后者只用于四份 Changelog 的待发布区；禁止用一次全局替换混淆二者。
- 审计 Starcat 根目录下每个独立 Git 仓库，不能只检查主仓库和本次代码涉及的 supports 仓库。任何 dirty、untracked、不同分支或未推送状态都要逐仓库报告。
- 先修改生成源，再运行现有同步工具，最后检查派生文件。不能只手改生成结果，也不能运行同步工具后无差别暂存所有仓库。
- 历史 Changelog、迁移 identifier、兼容逻辑、旧版升级说明、测试夹具和命令示例中的版本号默认保留；只有语义明确表示“当前 / 最新 / 下载 / 默认填入值”的旧版本才是 stale candidate。
- 文档写入、Changelog、`docs/功能实现总览.md` 和官网部署仍按各自授权执行。缺少授权时标记 `BLOCKED` 或 `NOT RUN`，不能用“发布成功”掩盖文档未收口。
- 最终至少分别报告：版本文档源文件、批量 README 派生文件、正式 Changelog HTML、官网当前版本页、用户文档、Issue 模板和远端页面状态。
