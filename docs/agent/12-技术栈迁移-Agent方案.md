# 技术栈迁移 Agent 方案

> **文档定位**: 用户说"我要从 A 库迁到 B 库",agent 生成迁移路径 + 参考 repo + 已知坑。
> **状态**: 方案稿(2026-06-27),等 dong4j 拍板。
> **关联文档**:
> - [`00-概览-Agent方向讨论与方案.md`](00-概览-Agent方向讨论与方案.md)
> - [`02-替代品推荐-Agent方案.md`](02-替代品推荐-Agent方案.md):共用 `AgentOrchestrator`
> - [`06-Starcat对接FM功能矩阵.md`](06-Starcat对接FM功能矩阵.md):FM 不适合本场景(深度推理 + 联网)

---

## 一、用户故事

> 作为 Starcat 用户,我在 `RepoAIWindowContentView` chat 框输入:
> > "我要把项目里的 Alamofire 迁到 URLSession,有哪些 repo/案例可参考?"

agent 给我一份**迁移指南**:
> 1. **目标库候选**: URLSession(原生) / SwiftNIO(底层) / GRDB-networking(自建)
> 2. **API 差异**: 5 处 breaking change(详细列出)
> 3. **参考 repo**: 5 个从 Alamofire 迁到 URLSession 的真实开源项目(每个 1 段话介绍做法)
> 4. **迁移路径**: 4 阶段(摸底 → 适配器层 → 逐步替换 → 移除)
> 5. **已知坑**: 7 条(每个都标"踩过的人 + 解决方式")
> 6. **PoC 步骤**: 5 步(2-3 天可完成)
> 7. **风险评估**: 中(3-5 人天工作量)

### 1.1 关键差异(与"普通问 AI")

| 维度 | 通用 AI Chat(GPT/Claude 直接问) | **本方案** |
|---|---|---|
| 参考 repo | 凭记忆,可能瞎编 | **真实 GitHub 搜过**,附 owner/repo + stars + last_push |
| API 差异 | 笼统 | 配 Starcat 已有 `RepoAIContextProvider` 拉到的真实 API 文档 |
| 已知坑 | 通用建议 | **从 issue / discussion / blog 真实摘录** |
| 用户上下文 | 不知道用户用什么版本 / 哪些 API | **能读到用户的 stars / notes(用户授权后)** |

---

## 二、核心价值

> **"把'我得问 5 个群 + 翻 10 篇博客'压缩成 1 次 agent run"**。

这是 dong4j 最早提的"技术选型 agent"的近亲,但更聚焦(已知 A → B,不需要选)。

---

## 三、工具集

### 3.1 工具清单

```
Tool 1: get_library_context
  输入:  owner, repo (或 libraryName)
  输出:  description / language / stars / last_release / readme / 主要 API 摘要
  复用:  Starcat 已有 RepoAIContextProvider

Tool 2: fetch_library_changelog
  输入:  owner, repo, sinceVersion?, toVersion?
  输出:  Changelog[](version / date / breaking_changes / new_features)
  复用:  GitHub API /releases + parse_release_notes(与 10 共用)

Tool 3: search_migration_guides
  输入:  fromLib, toLib, language
  输出:  BlogPost[] (title / url / author / date / summary / relevance_score)
  复用:  走 AnySearchWebProvider(已有)+ query "from {A} to {B} migration"

Tool 4: search_migrated_repos
  输入:  fromLib, toLib, language, minStars
  输出:  GitHubRepo[] (真实已经从 A 迁到 B 的项目,验证方法: git log 出现 B + 移除 A)
  复用:  GitHub Search API(query: "removed A, added B")+ 二次校验

Tool 5: fetch_repo_known_issues
  输入:  owner, repo, labelFilter?(如 "migration" / "breaking")
  输出:  Issue[] (title / url / state / comments_count / summary)
  复用:  GitHub Issues API

Tool 6: estimate_migration_effort
  输入:  fromLib, toLib, language, userCodebaseHints?(可选)
  输出:  { effort_days: Double, complexity: 'low' | 'medium' | 'high',
           main_blockers: [String], quick_wins: [String] }
  内部:  调 LLM,基于 API 差异 + 已知 issue 综合

Tool 7: generate_migration_plan
  输入:  fromLib, toLib, all above outputs
  输出:  结构化 markdown 报告(7 个 section)
  内部:  调 LLM 整合 + @Generable 强制结构
```

### 3.2 工具 schema 关键约束

- `search_migrated_repos` 必须**校验** 真的迁移过(不能只搜"B"): 验证 commit history 同时含"B 引入"和"A 移除"
- `search_migration_guides` 优先权威源(官方文档 / 大厂 tech blog),过滤 SEO 农场
- `estimate_migration_effort` 范围 0.5-30 人天(超出给"建议分阶段")
- 单 run 处理 1 个 from-to 对(多对要分多次 run)

---

## 四、Agent 编排循环

```
[Step 1] system: "你是 Starcat 技术栈迁移助手,生成 A→B 迁移指南"
[Step 2] user: "从 Alamofire 迁到 URLSession"
[Step 3] tool_call: get_library_context("Alamofire", "Alamofire")
         → Swift 5.9+ / 41k stars / 最近 release 5.9
[Step 4] tool_call: get_library_context("apple", "swift-corelibs-foundation")  // URLSession 所属
[Step 5] tool_call: fetch_library_changelog(Alamofire, from=5.0)
         → 5.x→5.9 的 breaking 累积
[Step 6] tool_call: search_migration_guides("Alamofire", "URLSession", "Swift")
         → 4 篇优质博客
[Step 7] tool_call: search_migrated_repos("Alamofire", "URLSession", "Swift", minStars=100)
         → 6 个真实迁移过的 repo
[Step 8] 对前 3 个 migrated repo,tool_call: fetch_repo_known_issues
[Step 9] tool_call: estimate_migration_effort(Alamofire, URLSession, Swift)
         → "medium" / 5-7 人天
[Step 10] tool_call: generate_migration_plan(...)
[Step 11] final_answer → UI 渲染
```

最大 10 步,实际 6-8 步(取决于 known_issues 抓多少)。

---

## 五、UI 落地

### 5.1 入口

**复用 `RepoAIWindowContentView` 的 chat 容器**,加一个「🔀 迁移规划」快捷按钮:
- 点一下: chat 输入框自动填"从 [当前 repo] 迁到 ___"
- 用户改目标库名,回车触发

### 5.2 报告渲染(7 section markdown)

```markdown
# 🔀 迁移指南: Alamofire → URLSession

## 1. 目标库选择
- ✅ URLSession(原生,零依赖)
- ⚠️ SwiftNIO(更底层,工作量更大)
- ❌ GRDB-networking(社区小)

## 2. API 差异(5 处)
| Alamofire | URLSession | 差异 |
|---|---|---|
| AF.request | URLSession.dataTask | 异步回调改为 async/await |
| AF.upload | URLSession.uploadTask | 进度回调签名略不同 |
| ... |

## 3. 参考迁移(6 个真实 repo)
- **rs/NetworkingKit**(⭐ 480) — 已完整迁移,写了迁移笔记
- **sideeffect-io/URLSessionDemo**(⭐ 220) — 提供了 Alamofire 兼容层
- ... (每个 1 段话介绍做法)

## 4. 4 阶段迁移路径
1. **摸底**(1 天): 列所有 Alamofire 调用点
2. **适配器层**(1-2 天): 写 wrapper,旧代码不动
3. **逐步替换**(2-3 天): 按模块迁移
4. **移除**(0.5 天): 删除依赖

## 5. 已知坑(7 条)
1. ⚠️ "重试逻辑 Alamofire 默认有,URLSession 要自己实现" — 解决方法: ...
2. ⚠️ "证书 pinning API 完全不同" — 解决方法: ...
... (每条都有"踩过的人"和"解决方式")

## 6. PoC 步骤
- [ ] 准备一个测试项目
- [ ] 写 URLSession 适配器层
- [ ] 迁移 1 个最简单的 GET 请求
- [ ] 跑 e2e 测试
- [ ] 对比性能(可选)

## 7. 风险评估
- 工作量: 5-7 人天
- 复杂度: 中
- 主要 blocker: 团队熟悉度
- Quick wins: 先迁 1-2 个简单模块
```

### 5.3 关键交互

- **「💾 保存为 note」**: 整篇报告存到 notes,tag "migration"
- **「📌 加入迁移项目」**: 在 Starcat 里建一个"迁移项目",跟踪进度(关联参考 repo)
- **「🔄 重新生成」**: 重跑(同配额)
- **「📤 分享」**: 生成 URL,团队成员可看(本地链接)

### 5.4 错误处理

| 错误 | UI 表现 |
|---|---|
| 找不到迁移过的 repo(`search_migrated_repos` 返回空) | section 3 改"暂无真实迁移案例,以下是通用建议" |
| 目标库不存在 / 拼错 | 提示"未找到 B 库,请检查名称" |
| 已知 issue 抓不到(repo 无 issues 权限) | 降级,只显示搜索到的博客和 migrated repo |
| 工作量估算失败 | 降级显示"无法估算,建议小项目先 PoC" |

---

## 六、数据闭环

### 6.1 复用 Starcat 已有

| 表 / 数据 | 用途 |
|---|---|
| `auth_session` | GitHub 鉴权 |
| `AnySearchWebProvider` | 搜博客 |
| `RepoAIContextProvider` | 拉 lib context |
| `note` | 保存迁移报告 |
| `tag` + `repo_tag` | migration tag |
| `EntitlementGate` + `quota` | Pro 拦截 |
| `AIClient` | 调 LLM |

### 6.2 新增 `migration_project` 表(可选,跟踪迁移进度)

```sql
CREATE TABLE migration_project (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    from_lib TEXT NOT NULL,
    to_lib TEXT NOT NULL,
    status TEXT NOT NULL,           -- 'planning' | 'in_progress' | 'completed' | 'abandoned'
    note_id INTEGER,
    created_at INTEGER NOT NULL,
    completed_at INTEGER
);
```

**为什么需要这张表**:
- 用户可以建多个"迁移项目",跟踪进度(2-3 个同时进行很常见)
- "你正在做哪些迁移"视图(Starcat 主窗口加个 section)
- 完成后可触发"复盘笔记"自动生成

### 6.3 不引入新表的设计取舍

- 不存"每次迁移报告的完整内容"——`note` 表已够
- 不存"参考 repo 列表"——重跑 agent 即可

---

## 七、付费与配额

| 用户档 | 体验 |
|---|---|
| **Free** | 每月 3 次迁移指南(单 from-to 对);只看报告,不能建"迁移项目" |
| **Pro** | 不限次数;可建"迁移项目"跟踪;保存为 note;分享链接 |

- 单次 run 配额: **2 quota**(多 tool 聚合)
- 配额回滚:1-2 tool 失败不回滚(已有部分价值),≥ 4 tool 失败回滚

---

## 八、工作量估算

| 模块 | 类型 | 估算 |
|---|---|---|
| 7 个 Tool 实现 | 新增 | 中(与替代品推荐共用 30%) |
| `migration_project` 表 + DAO | 新增 | 小 |
| 「🔀 迁移规划」快捷按钮 | 新增 | 极小 |
| 7 section markdown 渲染 | 新增(扩展 markdown 组件) | 中 |
| 「📌 加入迁移项目」按钮 + 项目管理 UI | 新增 | 中 |
| 团队分享链接(本地) | 新增 | 小 |
| 单测(migrated repo 校验 / 估算) | 新增 | 中 |
| i18n 词条(`agent.migration.*`) | 新增 | 小 |
| `docs/工程进度/功能实现总览.md` 进度登记 | 强制 | 极小 |

**总估时**: 中等。**最大难点是 `search_migrated_repos` 的"真迁移过"校验逻辑**——需要扫 commit log 验证"引入 B + 移除 A"。

---

## 九、关键风险 & 缓解

| 风险 | 等级 | 缓解 |
|---|---|---|
| `search_migrated_repos` 误判(repo 引入了 B 但没用 A) | **高** | 严格 commit log 校验:"removed A" + "added B" 双条件;且 A 在 lib 列表里 B 也在 |
| LLM 编造 API 差异 | 中 | 必须基于实际 lib context(已有 readme 摘要)生成,不靠记忆 |
| 工作量估算偏个人/主观 | 中 | 强制给"范围"(最好/典型/最坏),不是单点 |
| 已知坑陈旧(项目早已修) | 中 | 优先近 12 个月的 issue,过滤已 closed |
| 团队分享链接被外网访问(本地链接) | 低 | 默认只在同 LAN 内可访问(需用户显式开外网) |
| 用户对"AI 建议"过度依赖 | 中 | 报告末尾固定一段"⚠️ 实际工作量取决于团队规模 / 项目复杂度,建议先 PoC 1-2 天" |

---

## 十、后续可拓展方向

1. **多库迁移**: "从 A + B + C 迁到 D + E"(组合迁移)
2. **跨语言迁移**: "从 Python 的 requests 迁到 Swift 的 URLSession"(语义映射)
3. **迁移模板库**: 社区共享"已经走通的迁移路径"模板
4. **迁移进度跟踪**: 在"迁移项目"里 tick 阶段,自动复盘
5. **回滚建议**: "如果迁移中途发现坑太大,怎么回退"
6. **绩效对比**: 迁移前后的性能 / 包大小 / 可维护性指标对比
7. **AI 写迁移代码**: 在 PoC 阶段,直接给"这段 Alamofire 代码的 URLSession 改写"(代码生成)

---

## 十一、变更记录

| 日期 | 变更 | 作者 |
|---|---|---|
| 2026-06-27 | 初稿 | Claude |
