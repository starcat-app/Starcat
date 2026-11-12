# LESSONS

> 创建日期：2026-11-12 · Reviewed through：2026-11-12 · 性质：高置信经验规则索引，不是对 3707 个提交的全量自动结论。
> 详细证据保留在对应规范、复盘、审查报告和踩坑记录中；本文件只维护可复用的规则。

## 维护规则

1. 每条 lesson 必须有 **Rule / Reason / Evidence / Seen / Status**。
2. dong4j 的硬性要求可以直接写成规范，不需要等待三次重复踩坑。
3. 同类问题在 3 个不同日期复现后，应晋升到 `AGENTS.md` 或 `docs/5-规范/`。
4. 晋升或失效后在原条目保留 `Promoted to` / `Superseded by`，不直接删除历史。
5. 冲突时以 `AGENTS.md` 和对应强制规范为准；本文件帮助理解原因和边界，不取代授权规则。
6. 详细复盘只写证据文件；不要把长日志、临时诊断和未确认猜测复制进本文件。

## 执行与授权

### L-EXEC-001 反馈不是动手许可

- Rule: dong4j 的反馈、补充信息、纠错和方案讨论都不等于实施授权；必须等到“开干 / 改吧 / GO / 动手 / 实施”等明确授权。
- Reason: 讨论阶段继续写入会扩大范围、覆盖未确认设计，或把方案草稿变成事实改动。
- Evidence: `AGENTS.md:16`
- Seen: 2026-09-13, 2026-11-12
- Status: active
### L-STATE-001 方案、实现、验证、验收和发布必须分开

- Rule: 方案认可、代码实现、自动化验证、人工验收、生产部署和公开发布不能互相替代；未完成状态必须显式保留。
- Reason: 构建通过只证明编译或测试通过，不证明真实环境、GUI、旧用户数据、远端服务或发布链路已验收。
- Evidence: `docs/0-总览/文档添加规范.md:123`、`docs/4-工程进度/第三方依赖升级专项/依赖审计与验证记录.md:9`
- Seen: 2026-09-16, 2026-11-12
- Status: active

### L-AUTO-001 自动化执行必须有边界和工作区清单

- Rule: AI 自动开发前必须确认任务授权、执行范围、验证命令、允许写入的仓库和文件；提交前盘点工作区并保留无关脏改动。
- Reason: 自动化容易把并行任务、本地实验、配套仓库或发布动作一起带走，导致不可回滚或错误归因。
- Evidence: `AGENTS.md:16`、`docs/4-工程进度/第三方依赖升级专项/依赖审计与验证记录.md:13`
- Seen: 2026-11-09, 2026-11-12
- Status: active

## 文档与状态

### L-DOC-001 现行事实以源码和已确认决策为准

- Rule: 说明当前行为前核对源码、工程配置、迁移账本和已确认决策；旧方案、旧总览或旧报告只是历史证据。
- Reason: 项目迭代很快，文档可能落后于代码；直接复制旧结论会把过期设计重新写入当前说明。
- Evidence: `docs/0-总览/文档添加规范.md:122`、`docs/9-复盘/功能复盘.md:8`
- Seen: 2026-09-16, 2026-11-12
- Status: active

### L-DOC-002 契约变化必须同批同步文档

- Rule: API、数据库、构建、渠道门控、本地化、任务流或 Skill 行为变化时，同一批改动必须更新依赖该契约的文档、索引和 Skill。
- Reason: 契约分散更新会产生断链、旧路径和互相矛盾的状态；事后补写容易丢失当时的验证边界。
- Evidence: commit `fe03c1565635547fef23ed6703f76c2b6a17a1ef`
- Seen: 2026-11-12
- Status: active

### L-DOC-003 历史记录不回写为当前状态

- Rule: 被替代、取消、暂停或当时未验收的记录保留原状态；后续变化通过补记、当前入口或失效范围说明。
- Reason: 把历史报告改成“当前正确”会掩盖当时的证据边界，也让取消范围和待验收项被误恢复。
- Evidence: `docs/0-总览/文档添加规范.md:124`、`docs/9-复盘/功能复盘.md:3`
- Seen: 2026-09-16, 2026-11-12
- Status: active

## 数据与运行时

### L-DB-001 已发布 schema 只追加迁移

- Rule: 已随正式版发布的数据库 schema 变更必须追加 `registerVN` 迁移；禁止修改 `v1-initial`、要求删库重建或长期双写废弃字段。
- Reason: 线上用户已有本地数据；修改历史迁移不能让旧库前进，兼容堆叠则会扩大后续维护面。
- Evidence: `AGENTS.md:9`
- Seen: 2026-07-14, 2026-11-12
- Status: active

### L-LIFETIME-001 长生命周期回调必须显式保活

- Rule: 注册到 server、handler、通知中心或长期回调表中的对象，必须由拥有相同生命周期的字段持有；协议状态机的重连边界要明确。
- Reason: 局部对象在异步启动闭包结束后可能被 ARC 释放，回调进入 fallback 路径，表现为空列表、不可用或重连失败。
- Evidence: `docs/4-工程进度/踩坑与故障记录/2026-06-21-MCP-三个真根因排查.md:16`
- Seen: 2026-06-21
- Status: active

## 构建与验证

### L-BUILD-001 使用标准入口并处理工程生成

- Rule: 构建和启动使用 Makefile 标准入口；跑测前关闭 Xcode IDE；新增或删除 Swift 文件后先执行 `xcodegen generate`；启动期 Keychain 或系统授权路径用 `TestEnvironment` 门控。
- Reason: 裸 `xcodebuild` 会污染固定 DerivedData，IDE 会抢占 `testmanagerd`，未生成工程会让新文件不可见，测试 host 还可能被授权对话框挂住。
- Evidence: `AGENTS.md:109`、`AGENTS.md:130`、`AGENTS.md:177`、`AGENTS.md:181`
- Seen: 2026-05-31, 2026-11-12
- Status: active

### L-SEC-001 临时安全绕过必须有移除门禁

- Rule: DEBUG fallback、明文落盘、临时 token 文件或授权绕过必须标记影响范围、移除步骤、负责人和发布阻断条件；发布前核对 Release 不包含该路径。
- Reason: 临时方案常在功能收口时被遗忘；一旦进入发布产物，会把开发期便利变成用户数据风险。
- Evidence: `docs/4-工程进度/踩坑与故障记录/2026-05-30-Keychain-临时绕过方案.md:4`
- Seen: 2026-05-30
- Status: active

### L-ENV-001 Agent 宿主机先检查隐式环境

- Rule: 外部 Mac 或 Agent daemon 访问私有仓库前，先核对 Git credential helper、Keychain、token scope 和非交互 clone；不得用改公开仓库绕过。
- Reason: “另一台机器可用”通常依赖不可见的本机凭证状态；临时放宽仓库可见性会泄露代码且不能修复认证根因。
- Evidence: `docs/4-工程进度/踩坑与故障记录/2026-06-08-Multica-外部服务器-Git-认证踩坑.md:38`
- Seen: 2026-06-08
- Status: active

## 发布、协作与提交

### L-RELEASE-001 发布动作需要当前显式授权

- Rule: 打包、签名、公证、上传、App Store 提交、服务器发布、tag、push 和产物覆盖必须在当前消息中明确授权；Agent 平时只修改脚本、写文档或给出命令。
- Reason: 发布动作会创建外部可见产物、覆盖远端状态或消耗一次性审核窗口；构建成功不代表允许发布。
- Evidence: `AGENTS.md:20`
- Seen: 2026-09-13, 2026-11-12
- Status: active

### L-I18N-001 本地化按全语言集合交付

- Rule: 新增或修改国际化文案后覆盖当前全部支持语言，核对占位符、编译资源、长文案布局和审核状态；语言集合以 `AppLocale` 与 `supports/starcat-localization/locales.json` 为准。
- Reason: 只补中英文或复制英语会让未翻译内容伪装成已完成；AI 初稿和 `needs_review` 不能当作人工审核完成。
- Evidence: `AGENTS.md:437`
- Seen: 2026-10-21, 2026-11-12
- Status: active

### L-TASK-001 双端任务状态必须回读

- Rule: Multica 与 GitHub 的关闭、取消、父子任务和 Project 状态需要分别完成并回读；任一端失败时记录“同步待补”，不能宣称双端完成。
- Reason: 当前没有自动关闭同步；只改一端会让执行入口和交付证据漂移。
- Evidence: `AGENTS.md:350`
- Seen: 2026-10-07, 2026-11-12
- Status: active

### L-GIT-001 提交只表达一个主题

- Rule: commit type、scope 与实际语义一致；互不相关的能力、修复、重构和文档拆分提交；功能、测试和文档只有服务同一结果时才同提交。
- Reason: 混合提交无法稳定生成更新日志，也难以独立回滚、审查和归因。
- Evidence: `docs/5-规范/Git-提交规范.md:44`、`docs/5-规范/Git-提交规范.md:54`、`docs/5-规范/Git-提交规范.md:81`、`docs/5-规范/Git-提交规范.md:124`
- Seen: 2026-11-12
- Status: active

