# Starcat 推广文案 · 长文版

> 适用平台：微信公众号 / 知乎 / 少数派 / Product Hunt（中文区）/ 掘金

---

## 标题备选

1. Starcat 上线：我花了 18 个月，把 GitHub Stars 做成了一个知识管理工具
2. 别再让 GitHub Stars 吃灰了——Starcat 使用指南
3. 一个 macOS 独立开发者的自白：为什么我要重新发明 GitHub Star 管理

---

## 正文

### 一千个 Star 的烦恼

如果你是一个经常逛 GitHub 的开发者，你的 Star 列表大概率是这样的：翻到第三页就开始卡顿，想找一个"之前 Star 过的动画库"，在搜索框里打了几个关键词，发现 GitHub 原生的搜索只能搜仓库名和描述——而那个库的描述写的是"A lightweight animation framework"，你搜的是"动画"。

这就是 GitHub Stars 的现状：**收藏即遗忘**。

GitHub 给了我们一个很好的收藏机制，但没有给我们一个很好的找回机制。Starship、OhMyStar 这些第三方工具解决了部分问题——标签、搜索、同步——但它们止步于"管理"。在 AI 时代，"理解"和"评估"应该是标配。

所以我做了 Starcat。

### Starcat 的核心设计哲学

Starcat 的名字来自 Star + Cat（目录/编目），核心理念是四个动词：

**整理**：不只是标签。你可以像整理书架一样整理你的 Star 列表——自定义标签、阅读状态（未读/阅读中/已采用/已废弃）、私有笔记。每个项目都可以留下你的思考痕迹。

**理解**：AI 自动为每个项目生成摘要——中文或英文，你说了算。不是那种"这是一个开源项目"的废话摘要，而是真正提取技术栈、核心功能、适用场景的结构化信息。

**找回**：FTS5 全文搜索搜名字、搜描述、搜 README。Pro 版的语义搜索更进一步——你搜"动画库"，它能找到描述里写"animation framework"的项目。混合 BM25 + Embedding + RRF 算法，准确率和召回率都不妥协。

**评估**：一个 5 年前的库还在维护吗？Issue 响应速度如何？社区活跃度怎么样？AI 项目健康度评估帮你判断是否值得投入时间。

### 不止是管理工具

Starcat 还有一个独特功能：**Release 订阅追踪**。

你可以订阅任意项目的 Release 更新。Starcat 会轮询检查，在新版本发布时通知你。时间线统一展示所有订阅项目的版本历史。更贴心的是，它会根据你的平台智能过滤——如果你在用 macOS，它优先展示 `.dmg` 和 `.app` 文件；Windows 用户看到 `.exe` 和 `.msi`。

一键跳转下载，不用再翻 GitHub Release 页面找对应版本了。

### 为什么是 macOS 原生

选择 macOS 原生（SwiftUI）而不是 Electron，不是一个技术选择，而是一个产品选择。

- **数据安全**：GitHub OAuth Token 和 AI API Key 存在 Keychain 里，受 Secure Enclave 硬件加密。Electron 应用做不到这一点。
- **本地优先**：用户内容存在本地 SQLite，可随时导出 JSON。你可以不用我们的任何云服务。
- **体验**：Liquid Glass 设计语言、原生三栏布局、系统级快捷键——这些是"像 Mac 应用"和"是 Mac 应用"的区别。

### 定价与开源

Starcat 是一款 **MIT 开源**软件，代码在 [github.com/dong4j/Starcat](https://github.com/dong4j/Starcat) 完全公开。

免费版覆盖完整的 Star 管理功能，日常使用绰绰有余。Pro 版解锁 AI 功能和 Release 追踪，提供年度订阅和一次性买断两种方式。

AI 服务支持多种模式：你可以用我们提供的内置配额，可以用自己的服务器，也可以用自己的 API Key——OpenAI、Claude、Gemini、DeepSeek，甚至本地 Ollama 都支持。

### 最后

Starcat 是我作为一个 GitHub 重度用户，为自己（也为有同样困扰的人）做的一款工具。它不试图取代 GitHub，也不试图成为一个全能的开发者平台。它只想做好一件事：**让每一个你 Star 过的项目，在你需要的时候能被找到、被理解、被评估**。

如果你也在为"Star 太多找不到"而烦恼，欢迎试试 Starcat。

即将上架 Apple App Store。
官方网站：[starcat.app](https://starcat.app)
GitHub：[github.com/dong4j/Starcat](https://github.com/dong4j/Starcat)

---

## SEO 关键词

`GitHub Star管理` `macOS应用` `AI摘要` `开源项目` `SwiftUI` `效率工具` `知识管理` `开发者工具`

---

## 推广渠道建议

| 渠道 | 内容形式 | 优先级 |
|------|---------|--------|
| V2EX / 创意分享 | 短文版 A 或 B | 高 |
| 少数派 | 长文版（可配应用截图） | 高 |
| 知乎 | 长文版 + "独立开发者"话题 | 中 |
| 掘金 | 长文版 + 技术栈详解 | 中 |
| Product Hunt | 英文版（后续翻译） | 中 |
| 即刻 | 短文版 B | 低 |
| 微博 | 短文版 A + 截图 | 低 |
