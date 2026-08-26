# GitHub Lists 仓库分组 2.0 正式方案

> 日期：2026-08-26
> 状态：方案确认，待实施
> 关联 Issue：[`starcat-app/starcat-pro#1`](https://github.com/starcat-app/starcat-pro/issues/1)
> 范围：GitHub Lists 多选 membership 交互、Starcat 私有 AI 分组规则、AI 建议审核与可选自动整理

## 1. 背景

Starcat 已支持同步、创建、编辑和删除 GitHub Lists，并使用 GitHub Lists 作为 Manage 中的“仓库分组”。现有本地数据模型与 GitHub GraphQL mutation 都允许一个仓库同时属于多个 Lists，但仓库右键菜单仍按“单选分组”设计：

- 在 All Stars、Tags、Languages 等页面，只显示“添加到分组”，不展示仓库已经属于哪些 Lists；
- 在某个 List 内，只提供“移出当前分组”和“移动到其他分组”，把多对多 membership 错误表达成互斥移动；
- 用户再次点击已经加入的 List 时，底层集合去重使操作成为幂等写入，计数自然不变，但 UI 没有提前展示该状态，容易被理解为操作失败；
- 分组名称和 GitHub 描述不足以稳定表达“什么项目才应该进入这个分组”，无法作为可靠的 AI 分类规则。

本方案把仓库分组升级为完整的多分组整理系统，并在不允许 AI 创建分组的前提下，增加由用户规则驱动的 AI 建议与自动整理能力。

## 2. 产品目标

1. 一个仓库可以同时属于多个 GitHub Lists，所有入口都准确展示当前 membership。
2. 用户可以在统一的多选菜单中独立添加或取消任意 membership，并看到 Sidebar 计数变化。
3. 用户只能手动创建、重命名、描述和删除分组；AI 不得执行任何分组 CRUD。
4. 用户可以为每个分组编写仅属于 Starcat 的“AI 分组规则”，明确该分组的收录条件。
5. AI 可以把一个仓库建议加入零个、一个或多个现有分组，但第一阶段只允许新增 membership。
6. 手动 AI 整理必须先生成可审核建议，用户确认后才写入 GitHub。
7. 后台自动分组默认关闭，只有全局与分组两级均显式启用时，才允许自动应用高置信度建议。

## 3. 核心原则

### 3.1 GitHub 与 Starcat 的数据所有权必须分离

GitHub List 的 ID、名称、GitHub 描述、公开性和 membership 由 GitHub 拥有。Starcat 的颜色和 AI 分组规则是本地增强元数据，不能在 GitHub 快照同步时被覆盖，也不能误传回 GitHub。

### 3.2 AI 使用封闭候选集

AI 只能选择请求中明确提供的现有 `list_id`。模型输出的未知 ID、分组名称或创建指令全部拒绝，不能把模型自由文本解释成新分组。

### 3.3 默认建议，自动写入必须显式授权

手动整理遵循“生成建议 → 用户审核 → 应用选中项”。后台自动整理是可选能力，默认关闭，并通过全局开关、分组开关和置信度阈值共同约束。

### 3.4 第一阶段只增不减

AI 只建议把仓库加入符合规则的 Lists，不自动移除已有 membership。已有分组可能包含用户的人工判断，模型不能因为当前上下文不足而覆盖该判断。

### 3.5 远端成功后再写本地

所有 GitHub Lists mutation 继续遵守现有约束：先请求 GitHub，远端成功后才更新本地 membership。失败时不做乐观落库，避免 Starcat 与 GitHub 状态分叉。

## 4. 多分组交互修复

### 4.1 统一右键菜单

无论用户位于 All Stars、Tags、Languages、未分组，还是某个 GitHub List，仓库右键菜单都展示相同的扁平 Lists 清单：

- 已加入的 List 使用 macOS 原生 checkmark；
- 未加入的 List 不显示 checkmark；
- 保留分组颜色、名称和当前仓库数量；
- 勾选调用 `addRepo`，取消勾选调用 `removeRepo`；
- 不再根据当前 Sidebar 位置展示“移出当前分组 / 移动到其他分组”。

优先使用 SwiftUI `Toggle` 在 `NSMenu` 中的原生状态语义，保证键盘、VoiceOver 和系统主题一致。若原生 checkmark 与彩色图标在实机菜单中发生布局冲突，状态 checkmark 的优先级高于颜色圆点。

### 4.2 Membership 状态来源

`HomeViewModel.refreshSidebar()` 在刷新 Lists 和计数时，同时读取现有 `fetchAllListAssignments()`，在内存中维护：

```text
repoID -> Set<listID>
```

右键菜单只读取该映射，不在 View 构建期间发起数据库或网络请求。账号切换时必须与其它 Sidebar 快照一起清空，避免跨账号显示旧 membership。

### 4.3 写入后反馈

一次 membership 操作成功后：

1. 刷新 repo membership 映射；
2. 刷新真实 List 计数和“未分组”计数；
3. 失效 GitHub List 相关查询快照；
4. 重载当前仓库列表；
5. 显示现有成功 Toast。

如果用户在当前 List 中取消该 List，成功后仓库从当前列表消失，对应计数减一；仓库在其它 Lists 中的 membership 保持不变。

### 4.4 单仓库“移动”语义收口

单仓库菜单改成多选后，现有 `moveRepo` 不再有合法调用方，应随本次改动删除。批量操作中的显式“移动一批仓库”仍保留原语义，不在本阶段扩大范围。

## 5. GitHub 描述与 AI 分组规则

### 5.1 两个字段必须明确区分

当前 Starcat 已支持 GitHub List `description`，保存时会同步到 GitHub。该字段不能复用为 AI 私有上下文。

分组编辑器改为两个独立区域：

1. **GitHub 描述**：现有字段，继续同步到 GitHub；
2. **AI 分组规则（仅 Starcat）**：新增字段，只保存在 Starcat，不写入 GitHub。

示例规则：

> 只收录 macOS 原生 Swift / SwiftUI 开发工具，不包含跨平台 UI 框架、教程或示例项目。

空规则表示该分组不参与 AI 整理。AI 不得仅根据分组名称猜测收录条件。

### 5.2 隐私说明

“仅 Starcat”表示规则不会同步给 GitHub。执行 AI 整理时，规则和任务所需的仓库元数据会发送给用户当前配置的 AI Provider，因此编辑器和运行确认界面必须明确展示该边界。

第一阶段不把 AI 分组规则接入 CloudKit；规则保存在当前账号独立的本地数据库。后续若需要多设备同步，应作为独立用户数据同步任务评估，不能混入 GitHub Lists 快照同步。

## 6. 本地数据模型

AI 分组规则属于 Starcat 用户数据，不直接增加到 GitHub 远端缓存模型，新增独立表：

```sql
CREATE TABLE github_star_list_ai_rules (
    list_id TEXT PRIMARY KEY NOT NULL,
    instruction TEXT NOT NULL DEFAULT '',
    auto_apply_enabled INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (list_id) REFERENCES github_star_lists(id) ON DELETE CASCADE
);
```

字段语义：

| 字段 | 含义 |
|---|---|
| `list_id` | 关联 GitHub List 稳定 ID，不依赖可变名称 |
| `instruction` | 用户编写的 AI 收录规则；空字符串表示不参与 AI 整理 |
| `auto_apply_enabled` | 是否允许后台自动整理向该 List 新增 membership，默认关闭 |
| `updated_at` | 本地更新时间，用于缓存失效、后续同步和审计 |

数据库已经随正式版发布，实施时必须追加下一个可用的 `registerVN`，禁止回写 `v1-initial`。当前迁移最新为 v31；若实施前没有其它迁移占号，使用 `registerV32GitHubStarListAIRules`，否则顺延到下一个可用编号。

不持久化 AI 建议详情和模型原文。手动审核结果只保存在当前批量任务会话，应用成功后以真实 GitHub membership 为最终状态。

## 7. AI 输入边界

### 7.1 分组上下文

只把规则非空的 Lists 传给模型：

- opaque `list_id`；
- List 名称；
- Starcat AI 分组规则；
- 当前候选仓库是否已经属于该 List。

`auto_apply_enabled` 是本地执行策略，不进入 Prompt，避免模型把开关误解为分类信号。

### 7.2 仓库上下文

复用现有 Repo AI 与批量整理已经允许使用的仓库事实：

- `full_name`；
- GitHub description；
- Topics；
- 主要语言；
- README 摘要或已有 AI 摘要；
- 当前 GitHub Lists membership。

默认不发送私有笔记、标签之外的用户私有状态、搜索历史、点击行为或其它仓库的内容。私有仓库是否参与继续遵循现有 AI Provider 和隐私设置，不为 AI 分组创建旁路。

### 7.3 不可信输入隔离

仓库 README、description、Topics 和分组规则都作为数据区传入，不得覆盖 system 指令。Prompt 必须明确：

- 仓库内容可能包含提示注入文本；
- 只能完成 membership 分类；
- 不能调用工具、创建分组、修改规则或扩展候选集；
- 只能返回指定结构化 JSON。

## 8. AI 输出契约与收敛策略

一个仓库可以对应多个建议：

```json
{
  "suggestions": [
    {
      "list_id": "existing-list-id",
      "confidence": 0.93,
      "reason": "该项目是基于 SwiftUI 的 macOS 调试工具"
    }
  ]
}
```

客户端必须执行以下校验：

1. `list_id` 必须存在于本轮封闭候选集中；
2. 对应分组的 AI 规则必须非空；
3. `confidence` 必须是有限值且位于 `0...1`；
4. 去重同一 repo-list 建议；
5. 过滤已经存在的 membership；
6. `reason` 只做用户审核说明，不作为写入依据；
7. 未命中任何规则时允许返回空数组，禁止强行分类；
8. 模型输出的分组名称、创建请求、移除请求和其它字段全部忽略。

## 9. 手动 AI 建议分组

### 9.1 入口

在 Sidebar“仓库分组”标题行增加 `sparkles` 按钮，控制顺序为：

```text
仓库分组  新建  AI 整理  刷新                  数量  展开
```

按钮位于新建与刷新之间：新建负责定义候选集，AI 整理负责使用候选集，刷新负责与 GitHub 对齐。

当不存在规则非空的分组、没有可处理仓库、AI 未配置或无 Pro 权限时，入口显示对应禁用或付费墙状态，不启动空任务。

### 9.2 候选范围

首版候选范围为当前账号的全部星标仓库。由于 Lists 是多对多关系，不能只处理“未分组”仓库；已经属于 A 的仓库仍可能符合 B。

每个 repo-list 已存在的 membership 在生成前过滤，避免重复推荐。大量仓库沿用现有批量 AI 队列逐个处理，不一次把全部仓库塞进同一个 Prompt。

### 9.3 运行与审核

手动运行流程：

1. 检查 Pro、Provider、模型和规则；
2. 冻结本轮候选 Lists 及规则快照；
3. 把候选仓库送入现有批量 AI 队列；
4. 展示进度、暂停、继续、取消和失败重试；
5. 完成后按 List 分组展示建议；
6. 用户可取消勾选不准确的建议；
7. 点击“应用选中项”后才写 GitHub。

审核界面至少展示：

- 目标 List；
- 仓库 `full_name`；
- 置信度；
- AI 推荐理由；
- 当前是否已被用户取消选择；
- 应用总数和预计 GitHub 写入仓库数。

同一仓库命中多个 Lists 时，可以在多个 List 分组下出现；执行层必须按仓库重新聚合，保证一次 mutation 应用该仓库的全部批准项。

## 10. 后台 AI 自动分组

### 10.1 启用条件

后台自动分组可以复用现有 `AutoTidyScheduler` 和批量队列的执行基础设施，但产品配置必须作为独立的“仓库分组”顶级 Section 展示，不能放进标签分类的执行操作或复用标签阈值。自动写入必须同时满足：

1. 用户开启全局“自动添加到仓库分组”；
2. 目标 List 的 `auto_apply_enabled` 为 true；
3. 目标 List 的 `instruction` 非空；
4. 建议置信度达到用户设置的阈值；
5. 当前具备 Pro 权限和有效 AI 配置；
6. 当前没有优先级更高的手动批量 AI 任务。

全局和分组开关默认都关闭。用户开启全局开关时必须明确提示：该能力会在后台向 GitHub Lists 写入 membership。

全局开关开启后，在 App 启动暖机完成和 Stars 同步完成时触发检查；标签分类的总开关、触发开关和置信度不参与仓库分组授权。

### 10.2 自动模式边界

自动模式只允许：

- 把仓库加入满足规则的现有 Lists；
- 跳过低置信度或无匹配结果；
- 汇总成功、忽略和失败数量；
- 对失败项沿用批量队列的重试与诊断机制。

自动模式禁止：

- 创建、重命名或删除 List；
- 修改 GitHub 描述或 Starcat AI 规则；
- 移除已有 membership；
- 因模型输出未知名称而扩张候选集；
- 绕过 GitHub OAuth、Pro 或 AI Provider 门控；
- 在后台自动打开强提示 Sheet。

自动批次保持 silent UI 语义：Sidebar 显示轻量进度，完成后复用现有批量 AI 通知与最近运行统计。

### 10.3 上线节奏

手动建议和审核必须先完成准确率、GitHub 写入与错误恢复验收。自动模式的结构可以同期实现，但发布开关应在手动模式稳定后再开放，且首版不得默认开启。

## 11. 复用现有批量 AI 基础设施

不创建第二套队列，扩展现有 `BatchAIQueueService`：

- 复用 jobs、串行 run loop、暂停、继续、取消和失败重试；
- 复用手动模式与 `silent` 自动模式；
- 复用前台任务抢占后台自动任务的优先级规则；
- 复用 Pro entitlement、AI Provider、模型选择和用量记录；
- 在现有摘要、标签建议之外增加 Lists 建议结果；
- 同一仓库需要多个 AI 产物时，尽量在一次模型请求中返回，避免重复消耗。

现有批量自动标签只允许复用已有标签，不静默扩张标签库。AI 分组采用更严格的同类策略：候选 Lists 完全由用户预先创建，模型没有任何创建路径。

手动建议未确认前不得复用 `autoApplyTags` 的直接落库行为；Lists 建议要保留在 job 结果中，等待审核页统一应用。

## 12. GitHub 写入策略

用户批准后，执行层按仓库聚合全部新增 Lists：

```text
targetListIDs = latestExistingListIDs ∪ approvedSuggestionListIDs
```

每个仓库只调用一次 `updateUserListsForRepository`，即使同时加入多个 Lists，也不能按 membership 连续覆盖写入。

写入步骤：

1. 应用前重新读取该仓库最新本地 membership；
2. 与用户批准的 Lists 求并集并排序；
3. 调用 GitHub GraphQL；
4. GitHub 成功后替换该仓库本地 membership；
5. 更新当前任务结果；
6. 整批退出时合并刷新 Sidebar、membership 映射和当前列表。

首版继续串行写入，避免 GitHub rate limit 和同仓库并发覆盖。部分失败时不回滚已经成功的仓库；结果页必须显示成功、失败和未执行项，并允许重试失败仓库。

## 13. 权限、用量与日志

- 手动和后台批量 AI 分组复用现有 `.batchAI` Pro 门控，不新增订阅层级；
- AI 用量增加稳定 feature/phase 归因，区分分组建议生成与 GitHub 应用；
- 诊断日志只记录 repo ID、List ID、数量、状态、耗时和脱敏错误；
- 日志不得保存 AI 分组规则、README、完整 Prompt、模型原始响应、API Key 或 GitHub Token；
- GitHub 写入不是 AI Provider 调用的一部分，必须单独记录远端 mutation 成功/失败；
- 无有效 AI 配置时不得预先读取或上传大段 README 内容。

## 14. 错误与恢复

| 失败位置 | 用户可见行为 | 恢复方式 |
|---|---|---|
| 没有有效 AI 规则 | 说明至少需要一个非空规则 | 打开分组编辑器补充规则 |
| AI 配置或 Pro 检查失败 | 显示设置或付费墙入口 | 完成配置后重试 |
| AI 生成失败 | 对应仓库标记失败，不影响其它 jobs | 单项或全部重试 |
| 模型输出未知 List | 丢弃该建议并记录诊断计数 | 无需用户修复 |
| GitHub OAuth 组织限制 | 显示现有组织 OAuth 限制说明 | 用户在 GitHub 处理授权后重试 |
| GitHub mutation 失败 | 本地 membership 不变 | 重试失败仓库 |
| 部分仓库写入成功 | 保留成功结果并汇总失败项 | 只重试失败项 |
| 账号切换 | 取消当前任务并清空规则缓存、建议和 membership 快照 | 新账号重新加载 |

## 15. 实施阶段

### Phase A：多分组交互修复

- 加载 repo → List membership 快照；
- 右键菜单改成原生多选 checkmark；
- 添加/取消后刷新 membership 和计数；
- 删除单仓库 `moveRepo` 错误路径；
- 补充 ViewModel、Repository 和实机菜单验收。

### Phase B：AI 分组规则基础

- 追加 `registerVN` 迁移；
- 新增 AI 规则 model、protocol 和 GRDB repository；
- 分组编辑器拆分“GitHub 描述”和“AI 分组规则”；
- 增加分组级自动整理开关；
- 完成账号隔离、删除级联和 GitHub 快照不覆盖测试。

### Phase C：手动 AI 建议与审核

- 新增封闭 Lists hints 和结构化输出模型；
- 扩展 Repo AI/批量 AI 生成链路；
- 新增 Sidebar `sparkles` 入口；
- 新增进度、结果审核和“应用选中项”；
- 按仓库聚合并串行写入 GitHub；
- 完成失败重试、部分成功和刷新测试。

### Phase D：Auto Tidy 自动分组

- 增加独立的仓库分组顶级设置、全局开关和专属置信度阈值；
- 复用现有 silent 调度和完成通知，但不复用标签分类的配置字段；
- 只处理规则非空且分组级开关开启的 Lists；
- 验证默认关闭、双重授权、add-only 和手动任务抢占。

建议 Phase A、B、C 作为 1.5.0 主范围。Phase D 等手动建议准确率与 GitHub 写入稳定性完成真实验收后再开放。

## 16. 测试策略

### 16.1 数据库与 Repository

- v31 数据库升级后正确创建 AI 规则表，已有数据不丢失；
- 同一 List 的规则可新增、更新和读取；
- GitHub List 快照刷新不覆盖规则；
- List 删除后规则级联删除；
- 账号切换后不读取上一账号规则；
- `fetchAllListAssignments()` 正确返回一个 repo 对应多个 Lists。

### 16.2 AI 策略

- 未知 List ID 被拒绝；
- 空规则 List 不进入候选集；
- 已有 membership 不重复建议；
- 一个仓库可保留多个合法建议；
- 低置信度结果不进入自动应用；
- 模型输出 create/remove/rename 意图时不产生执行动作；
- 仓库内容中的提示注入不能扩大操作范围。

### 16.3 GitHub 应用

- 多个批准 Lists 合并成一次仓库 mutation；
- 应用前读取最新 membership，保留并发期间新增的其它 Lists；
- 远端失败时本地不写；
- 部分成功只重试失败仓库；
- 成功后 Sidebar 真实计数、未分组计数和当前列表一致。

### 16.4 UI 与人工验收

- 右键菜单在浅色、深色、键盘和 VoiceOver 下正确显示 checkmark；
- 一个仓库属于两个 Lists 时，两项同时勾选；
- 在当前 List 取消勾选后仓库消失，其它 Lists 不受影响；
- 描述和 AI 分组规则的标签、帮助文字和保存边界清晰；
- 无规则、无 AI 配置、无 Pro 和 OAuth 限制都有明确反馈；
- 手动运行不会在确认前写 GitHub；
- 自动分组默认关闭，关闭任一级开关都不会写入；
- 大批量运行可暂停、取消、重试，UI 不持续卡顿。

实施后关闭 Xcode IDE，先运行相关 Suite，再执行 `make test`。菜单视觉、GitHub 远端回读和自动整理后台行为必须单独人工验收，自动化通过不能替代这些门禁。

## 17. 不做范围

- AI 创建、重命名、描述或删除 GitHub List；
- AI 自动移除已有 membership；
- 根据分组名称自动生成并保存 AI 规则；
- 把 AI 分组规则同步到 GitHub；
- 第一阶段接入 CloudKit 多设备同步；
- 持久化模型原始响应或完整建议历史；
- 为 AI 分组新建独立队列、独立 Provider 或独立订阅层级；
- 修改批量“移动仓库”的现有产品语义；
- 在手动审核模式中绕过用户确认直接写 GitHub。

## 18. 验收标准

1. 右键菜单准确显示一个仓库属于多个 GitHub Lists，并支持独立添加和取消。
2. Membership 成功写入后，checkmark、Sidebar 计数、未分组计数和当前列表一致。
3. GitHub 描述与 Starcat AI 分组规则独立保存，GitHub 同步不会覆盖本地规则。
4. 没有 AI 规则的 List 不参与 AI 整理。
5. AI 无法创建新 List，也无法返回候选集之外的有效目标。
6. 一个仓库可以被建议加入多个现有 Lists。
7. AI 不会自动移除任何已有 membership。
8. 手动模式在用户确认前不调用 GitHub mutation。
9. 自动模式默认关闭，只处理全局与分组两级均启用且达到阈值的建议。
10. 同一仓库的多个批准建议只触发一次 GitHub membership mutation。
11. GitHub 写入失败时本地状态不被污染，部分失败可以准确重试。
12. 账号切换会取消任务并清空规则、建议和 membership 内存状态。
13. AI 规则不会进入 GitHub 或诊断日志，发给 AI Provider 的边界在 UI 中清晰可见。
