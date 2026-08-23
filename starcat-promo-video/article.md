# Starcat：把 GitHub Stars 变成能用的知识库

> 来源：starcat.ink 中文落地页、产品定位「整理、理解、找回、评估」。数字与功能名均取自官网，未编造用户量。

## §1 收藏夹的真实状态

GitHub 的 Star 列表是一条无限往下滚的时间线。每个开发者都遇到过这些问题：

- 收藏了上千个仓库，想找一个却翻半天
- 三个月后点开一个 Star，不记得为什么收藏它
- 一个个手动打标签太累，不打又找不到
- Star 的库更新了，你永远是从别人的推文里知道的

收藏很多，能用的很少。

## §2 产品是什么

Starcat 是一款 macOS 原生应用，将 GitHub Stars 转化为可搜索的 AI 知识库。它帮助你整理、理解、找回和评估每一个收藏的 GitHub 仓库——本地优先，AI 驱动。

当前版本仅支持 macOS 15+，提供 Apple Silicon Direct 下载包。暂不提供 iOS、iPadOS、watchOS、Windows 或 Android 版本。

官网徽章：macOS 15+ 原生体验；本地优先，数据完全自己掌控；BYOK AI，多模型自由选择。

## §3 四个解法

### 找回：FTS5 全文搜索

对仓库名、描述、Topics、笔记建立全文索引。支持自然语言查询和结构化组合过滤，毫秒级返回结果。支持按语言、标签、状态组合过滤，字段级精准匹配，可保存复杂查询条件。

混合搜索：BM25 关键词 + Embedding 语义搜索 + RRF 融合排序。用意图而非精确关键词查找。

### 理解：AI 结构化摘要与 README 翻译

AI 阅读 README 后给出中文摘要：项目做什么、解决什么问题、技术栈是什么。摘要按仓库缓存，适合快速判断项目价值。源 README 变更后提示重新生成。

README 可按需翻译并保留原始 HTML 结构。目标语言跟随设置。缓存命中时不消耗额外 AI 配额。

仓库详情页可一键唤起 AI 对话，针对当前仓库提问。多轮对话记忆，代码与文档联动。

### 分类：AI 标签推荐，确认后才写入

AI 分析仓库内容后推荐 3-8 个标签，带置信度评分。支持 14 个预设分类体系，同义标签自动检测。你只需点确认。

产品硬规则：AI 只给建议，用户确认后才写入。标签不经确认绝不自动应用。

自定义颜色与图标，支持批量打标签、合并标签。每个仓库可写独立私有笔记。标签、笔记和状态写入本地 SQLite。

### 跟上更新：Release 订阅

订阅你关心的仓库，新版本发布时第一时间推送通知。时间线视图统一展示，已读/未读一目了然。按平台/文件类型智能过滤资产，一键复制下载链接。

## §4 评估与探索

智能集合：浏览 Needs Review、Unmaintained、High Value、No Tags、Using、Recently Active 等内置集合，也可用元数据、状态、笔记和 Health 信号组合自定义规则。

Repo Health 评分：汇总仓库活跃度、维护状态和风险信号，帮助判断是否值得继续关注。

OpenSSF 安全评分：集成 OpenSSF Scorecard，为已 Star 的仓库拉取公开安全评分。雷达图展示多维度安全检查结果。冷却期智能刷新。

内置代码图谱 CodeFlow：不离开 App 即可探索仓库代码架构。自动分析依赖关系，可视化模块调用链路，执行步骤透明展示。

发现与趋势：内置发现、趋势、热门、新发布和周刊入口。

用户分享卡片：多主题个人名片，展示 GitHub 统计，一键导出高清 PNG（@3x）或分享到 X。

## §5 技术立场

Apple 原生，不是 Electron / Tauri / Flutter 套壳。SwiftUI 三栏布局，Liquid Glass 材质，围绕菜单栏、快捷键和桌面阅读体验打磨。

本地优先：GRDB.swift + SQLite 本地存储，数据完全掌控，离线也能用。仓库缓存可重建；标签、笔记、状态等用户数据不能丢失。CloudKit 仅同步用户数据。GitHub token 与 AI API Key 放 Keychain。

BYOK AI：支持自建代理、Gemini、DeepSeek、OpenAI 兼容、Ollama 本地模型。API Key 与调用配额由你自行掌控。

## §6 定价与下载

免费开始，按月或按年订阅，也可一次买断。

- Free：同步与本地缓存；标签、笔记、仓库状态；README 与本地搜索；发现 / 趋势 / 热门 / 新发布 / 周刊；活动时间线 / Undo Star；额度 20 标签 / 4 智能集合 / 5 Release；HTML / Markdown 导出
- Pro Monthly：$3.99/月，最多 2 台 Mac
- Pro Yearly：$29.99/年，相比月付节省约 37%，最多 2 台 Mac
- Pro Lifetime：$39.99 一次性买断，终身解锁当前 Pro 功能，最多 2 台 Mac

Pro 解锁：AI 摘要与 AI 标签、AI Chat 与 README 翻译、Embedding 语义搜索、LLM 友好的网页上下文、CodeFlow 与仓库上下文、Trending AI 推荐。不限基础额度。

下载：https://starcat.ink
支持：dong4j@gmail.com
