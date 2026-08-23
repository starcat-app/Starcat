# Video Outline

> **主题**：`midnight-press`（暗色印刷）—— 暖暗底 + 热橙，开发者工具片气质（不变）
> **总时长**：约 3 分 38 秒（口播去空白 ~700 字 ÷ 4 字/秒；step 估时合计 ~218s）
> **章节数**：9 章 / 34 步
>
> **v2 重构要点**（合并节拍 + 截图为王）：
> - 口播从 60 拍合并为 34 拍，碎句并成完整句，每拍一个完整想法
> - v3：产品已完全开源，删除付费订阅叙事；find 章「Pro 的语义搜索」改为「语义搜索」
> - 每个功能步骤尽量以**真实产品截图为主角**（hero shot），排版退为辅助
> - 全片截图主角共 11 张官网实拍 + 4 张定价卡；coldopen 保持纯排版（产品出场前不露 UI 是刻意的）

---

## 1. coldopen — 收藏夹在吃灰（5 steps · ~26s）

**信息池**（chapter agent 按需挂角标 / 副标 / pull-quote / mono cue）：
- 痛点：上千个收藏找一个翻二十分钟 —— 来源 article §1
- 痛点：三个月后不记得为什么收藏 —— 来源 article §1
- 痛点：手动打标签太累、更新靠别人推文 —— 来源 article §1
- 比喻：Star 列表是一条无限往下滚的时间线 —— 来源 article §1
- 结论：收藏很多，能用的很少 —— 来源 article §1
- 本章刻意不用产品截图：痛点段保持排版叙事，产品在第 2 章才登场

**开发计划**：

- step 1 (~5s) — 大字「RAG」+ 空搜索框；副标「20 分钟」
- step 2 (~4s) — 全屏数字感「1000+ Stars」
- step 3 (~6s) — 一张发灰的仓库卡：描述在、收藏理由空
- step 4 (~5s) — 对照：空标签槽 | 「xxx released」推文卡
- step 5 (~6s) — 时间线铺满全屏 + 对仗标语「收藏很多 / 能用的很少」

口播节选：
> 上周想找一个 RAG 库，我在收藏夹里翻了二十分钟。收藏很多，能用的很少。

---

## 2. product — 这就是 Starcat（4 steps · ~24s）

**信息池**：
- 定位：macOS 原生应用，Stars → 可搜索 AI 知识库 —— 来源 article §2
- 界面：SwiftUI 三栏、Liquid Glass —— 来源 article §5
- 反面：不是 Electron / Tauri / Flutter 套壳 —— 来源 article §5
- 四词：整理、理解、找回、评估 —— 来源 article §2

**开发计划**：

- step 1 (~3s) — 舞台中央 Starcat 标志 + 名称
- step 2 (~8s) — **hero 截图 `sc-banner.webp`**：三栏主界面大卡居中；标语「macOS 原生 · SwiftUI 三栏 · Liquid Glass」；Electron / Tauri / Flutter 划掉小字挂角
- step 3 (~7s) — banner 列表区特写占满舞台；标语「你自己的本地知识库」
- step 4 (~6s) — 四词横排 lockup：整理 · 理解 · 找回 · 评估

口播节选：
> 所以有了 Starcat。GitHub Stars 进来，就变成你自己的本地知识库。

---

## 3. find — 找回（4 steps · ~28s）

**信息池**：
- 引擎：FTS5 对仓库名、描述、Topics、笔记建全文索引 —— 来源 article §3
- 查询：自然语言 + 语言/标签/状态组合过滤，可保存复杂查询 —— 来源 article §3
- 速度：本机毫秒级返回，不走云 —— 来源 article §3
- 混合搜索：BM25 + Embedding + RRF（口播不说术语，画面挂 mono 角标）—— 来源 article §3
- 回扣：开场的 RAG 库出现在结果第一页 —— 来源 script 找回段

**开发计划**：

- step 1 (~7s) — **hero 截图 `sc-全局搜索.webp`** 整卡居中；四个索引字段名并列其上
- step 2 (~9s) — 同图搜索框与过滤芯片区特写；角标「本机 · 毫秒级 · 不走云」
- step 3 (~5s) — 同图结果第一行特写，accent 高亮框套住开场那个 RAG 库
- step 4 (~6s) — 图缩小让位；「语义搜索」角标 + mono 小字「BM25 × Embedding × RRF」+ 大字「按意图找」

口播节选：
> 自然语言直接搜，也能按语言、标签、状态组合过滤。搜 RAG？三个月前那个库，就在第一页。

---

## 4. understand — 理解仓库（4 steps · ~30s）

**信息池**：
- 摘要：AI 读 README 给中文结构化摘要：做什么/解决什么/技术栈 —— 来源 article §3
- 笔记：每仓库独立私有笔记 —— 来源 article §3
- 缓存：摘要按仓库缓存；README 变更提示重新生成 —— 来源 article §3
- 翻译：保留 HTML 结构；命中缓存不扣配额 —— 来源 article §3
- 对话：详情页一键唤起，多轮记忆 —— 来源 article §3

**开发计划**：

- step 1 (~9s) — **hero 截图 `sc-AI摘要.webp`**：摘要面板居中，三块标签「做什么 / 解决什么 / 技术栈」并列其上
- step 2 (~7s) — 排版：私有笔记空页卡 + 「README 变更」提示条；摘要截图缩小挂角
- step 3 (~8s) — **hero 截图 `sc-AI翻译.webp`**：左右对照英文原文 | 中文译文；角标「命中缓存不扣配额」
- step 4 (~6s) — **hero 截图 `sc-AI对话.webp`**：对话面板 + 当前仓库上下文锚点

口播节选：
> AI 先读完整个 README，给你一份中文摘要。有拿不准的，直接对着这个仓库问。

---

## 5. tags — 建议，不是替你写（3 steps · ~17s）

**信息池**：
- 数量：推荐 3-8 个标签，带置信度评分 —— 来源 article §3
- 体系：14 个预设分类；同义标签自动检测 —— 来源 article §3
- 硬规则：AI 只给建议，确认后才写入；不经确认绝不自动应用 —— 来源 article §3
- 无官方截图：本章用排版 + 置信度条表达，不造假数据 —— 来源 素材清单

**开发计划**：

- step 1 (~8s) — 候选标签 3~8 枚 + 置信度条；「14 套分类」mono 角标；同义标签间连线
- step 2 (~4s) — 大字「AI 只给建议」
- step 3 (~5s) — 标签已贴上仓库卡 + 「已确认」标记

口播节选：
> 硬规则只有一条：AI 只给建议。你点了确认才写入。

---

## 6. organize — 更新与集合（3 steps · ~21s）

**信息池**：
- Release：订阅仓库新版本第一时间通知 —— 来源 article §3
- 资产：按平台过滤安装包，一键复制下载链接 —— 来源 article §3
- 内置集合：Needs Review、Unmaintained、High Value、No Tags、Using、Recently Active —— 来源 article §4
- 自定义：元数据、状态、笔记、Health 信号组合规则 —— 来源 article §4

**开发计划**：

- step 1 (~8s) — Release 通知卡 + 平台过滤后的资产芯片 + 已复制链接行
- step 2 (~8s) — **hero 截图 `sc-智能集合.webp`**：集合页居中，Needs Review / Unmaintained 两枚集合处于高亮态
- step 3 (~5s) — 同图六枚集合芯片全部在场（High Value / No Tags / Using / Recently Active 为次级强调）

口播节选：
> 收藏夹还能按规则自己排队：没看过的进 Needs Review，停更两年的进 Unmaintained。

---

## 7. assess — 评估与探索（4 steps · ~23s）

**信息池**：
- Health：活跃度、维护状态、风险信号汇总评分 —— 来源 article §4
- OpenSSF：Scorecard 公开安全评分，雷达图，冷却期刷新 —— 来源 article §4
- CodeFlow：App 内依赖分析、模块调用链路 —— 来源 article §4
- 发现：发现、趋势、热门、新发布、周刊入口 —— 来源 article §4

**开发计划**：

- step 1 (~6s) — **hero 截图 `sc-Health评分.webp`**：评分卡居中，活跃度 / 维护 / 风险三项并列
- step 2 (~5s) — **hero 截图 `sc-OpenSSF评分.webp`**：完整雷达图展示
- step 3 (~7s) — **hero 截图 `sc-内置代码图谱.webp`**：依赖与调用链路图占满舞台
- step 4 (~5s) — 五枚探索入口芯片并排：发现 / 趋势 / 热门 / 新发布 / 周刊（或探索海报，开发时定）

口播节选：
> Health 把活跃度和维护风险汇总成分数。CodeFlow 把依赖和调用链路画出来。

---

## 8. local-native — 数据在你的 Mac 上（4 steps · ~26s）

**信息池**：
- 存储：GRDB.swift + SQLite，离线可用 —— 来源 article §5
- 分层：仓库缓存可重建；标签、笔记、状态不能丢 —— 来源 article §5
- 同步：CloudKit 仅同步用户数据；Token 与 Key 放 Keychain —— 来源 article §5
- BYOK：自建代理 / Gemini / DeepSeek / OpenAI 兼容 / Ollama —— 来源 article §5

**开发计划**：

- step 1 (~6s) — Mac 剪影 + 「GRDB + SQLite」；角标「离线也能打开」
- step 2 (~9s) — 分层对照：缓存可重建 | 用户数据不能丢；CloudKit 只同步用户数据 + Keychain 锁
- step 3 (~8s) — **hero 截图 `sc-AI服务配置.webp`**：BYOK 配置页居中；五家 provider 名单并列
- step 4 (~3s) — 大字收束：你的 Key / 你的配额

口播节选：
> 这些数据都存在你自己的 Mac 上。AI 的 Key 走 BYOK。你的 Key，你的配额。

---

## 9. cta — 边界、开源、下载（3 steps · ~24s）

> v3：产品已完全开源、基础功能免费，付费订阅叙事整体移除。

**信息池**：
- 系统：仅 macOS 15+，Apple Silicon Direct；无 iOS / Windows / Android —— 来源 article §2 / §6 FAQ
- 开源：仓库公开，可本地编译 —— 来源 dong4j 2026-08-22 口述
- 获取：App Store / 官网 Direct 包 / 本地编译，基础功能免费 —— 来源 dong4j 2026-08-22 口述
- CTA：https://starcat.ink —— 来源 article §6

**开发计划**：

- step 1 (~7s) — 「macOS 15+ · Apple Silicon」；iOS / Windows / Android 处于划掉态
- step 2 (~12s) — 大字「Open Source」+「基础功能免费」标签；三枚获取路径卡：本地编译 / App Store / Direct 下载
- step 3 (~5s) — logo + starcat.ink + 「把吃灰的 Stars 翻出来用」

口播节选：
> Starcat 现在完全开源了。基础功能免费使用。去 starcat.ink 下载，把吃灰的 Stars 翻出来用。

---

## 素材清单

### 1. coldopen
- ⚠️ 刻意无产品截图：时间线用排版模拟，不造假 GitHub UI
- ✓ 产品主界面静帧参考 `public/product/banner.webp`（仅备参考）

### 2. product
- ✓ 应用图标 `public/product/logo.png`
- ✓ **hero 主界面 `sc-banner.webp` → 已就位 `public/product/banner.webp`**

### 3. find
- ✓ **hero 全局搜索 `sc-全局搜索.webp` → 已就位 `public/find/search.webp`**（本章 4 步连续讲解同一张图：入场 → 推近搜索区 → 高亮结果行 → 缩小让位）

### 4. understand
- ✓ **hero AI 摘要 `sc-AI摘要.webp` → 已就位 `public/understand/summary.webp`**
- ✓ **hero AI 翻译 `sc-AI翻译.webp` → 已就位 `public/understand/translate.webp`**
- ✓ **hero AI 对话 `sc-AI对话.webp` → 已就位 `public/understand/chat.webp`**
- ✓ 理解海报 `public/understand/poster.webp`（备用）

### 5. tags
- ⚠️ 标签推荐无官方截图：排版 + 置信度条，不造假数据

### 6. organize
- ✓ **hero 智能集合 `sc-智能集合.webp` → 已就位 `public/organize/collections.webp`**（两步连续使用）

### 7. assess
- ✓ **hero Health `sc-Health评分.webp` → 已就位 `public/assess/health.webp`**
- ✓ **hero OpenSSF `sc-OpenSSF评分.webp` → 已就位 `public/assess/openssf.webp`**
- ✓ **hero 代码图谱 `sc-内置代码图谱.webp` → 已就位 `public/assess/codeflow.webp`**
- ⚠️ 探索入口无独立 UI 截图：排版芯片或 `public/assess/explore.webp` 海报，开发时定

### 8. local-native
- ✓ **hero AI 服务配置 `sc-AI服务配置.webp` → 已就位 `public/local/byok.webp`**

### 9. cta
- ✓ logo `public/cta/logo.png`
- ⚠️ v3 开源版不再使用定价卡（`public/cta/free|monthly|yearly|lifetime.webp` 留存不引用）；开源徽标如需可后续补官网图
- ⚠️ 本片口播未提分享卡片；`sc-分享卡片.webp` 不进画面

---

## 自检（写完 outline **强制**执行，不可跳过）

- [x] 每个 step 都是单一句屏幕内容描述，没有入场动词 / CSS 手段
- [x] 没有任何 step 写了具体毫秒（除 `(~Ts)` 口播估时）
- [x] 每章首段都有信息池，至少 3 条，且带来源标注
- [x] 所有 step `(~Ts)` 累加 ≈ 218s ≈ 顶部 3 分 38 秒（误差 <10%，v3 删订阅叙事后重算）
- [x] 章节切分 3~8 步 / 每章一聚焦主题；`tags` ~17s 为硬规则锚点短章，可接受
- [x] 末尾素材清单分章节，✓ / ⚠️ 已标
- [x] script.md 不含标题序号，只含口播
- [x] v2 合并节拍：60 拍 → 34 拍，无 5~10 字孤立碎拍；BM25/RRF 等术语移出口播、降级为画面 mono 角标
- [x] v3 全开源：全片无付费/价格/Pro 门控表述（find 章「Pro 的语义搜索」已改）
- [x] step 均为终态屏幕内容描述（reviewer 复核：动画手段全部留给章节开发阶段）
