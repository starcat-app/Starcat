# Starcat

![20260618205538_4cHWbTNy](./banner.png)

> 面向重度 GitHub 用户的 Apple 平台 Star 管理与 AI 知识整理工具

[![Platform](https://img.shields.io/badge/platform-macOS%2015+-blue)](https://developer.apple.com)
[![Swift](https://img.shields.io/badge/Swift-5.0-orange)](https://swift.org)
[![Design](https://img.shields.io/badge/Design-Liquid%20Glass-ff69b4)](https://www.apple.com/macos)

[English](./README.md)

## 核心价值

「**整理，理解、找回、评估**」—— 将 GitHub Stars 从扁平收藏夹升级为可复用知识库。

## 功能特性

### 基础功能
- GitHub OAuth 登录与增量同步
- macOS 15+ 原生三栏布局（macOS 26 Liquid Glass 优先适配）
- 标签分类与语言筛选
- FTS5 全文搜索
- README Markdown 渲染
- 私有笔记与状态管理（未读 / 阅读中 / 已采用 / 已废弃）
- JSON 导入/导出（OhMyStar/Astral 兼容）

### AI 功能
- AI 智能摘要（中文/英文）
- AI 标签推荐（含确认流程）
- 混合语义搜索（BM25 + Embedding + RRF）
- AI 每日推荐（个性化 GitHub Trending）
- AI 项目健康度评估
- 14 预设分类体系

### 差异化功能
- Release 订阅追踪
- 时间线统一展示
- 智能资产过滤（macOS/Windows/Linux）
- 一键订阅，一键下载

## 技术栈

| 层级 | 技术选型 |
|------|---------|
| 客户端 | SwiftUI + macOS 26 |
| 本地数据库 | GRDB.swift (SQLite) |
| 云同步 | CloudKit |
| 安全存储 | Keychain |
| AI 代理 | 自建服务（Gemini/OpenAI/DeepSeek）|

## 系统要求

- macOS 15 (Sequoia) 或更高版本
- Apple Developer Program ($99/年)

## 开发指南

### 环境准备

1. 安装 Xcode 26+
2. 克隆仓库
3. 打开 `Starcat.xcodeproj`
4. 配置 Signing & Capabilities
5. 运行项目

### 项目结构

```
Starcat/
├── App/
│   ├── StarcatApp.swift          # 应用入口
│   ├── ContentView.swift          # 根视图
│   └── AppDependencies.swift      # 依赖组装
├── Features/
│   ├── Auth/                      # GitHub OAuth
│   ├── Home/                      # 三栏主界面
│   ├── Tags/                      # 标签管理
│   ├── Notes/                     # 私有笔记与状态
│   └── Settings/                  # 设置面板
├── Core/
│   ├── Database/                   # GRDB 数据库封装
│   ├── Network/                   # GitHub API
│   ├── Sync/                      # 同步与 Repository
│   ├── Keychain/                  # 安全存储
│   ├── Settings/                  # 本地设置
│   ├── Cache/                     # 缓存清理
│   └── Models/                    # 领域模型
├── Shared/
│   ├── Components/               # 共享组件
│   └── Utilities/                # 工具与日志
└── Resources/
    └── Assets.xcassets
```

### 全量测试

```bash
cd /Users/dong4j/Developer/1.AI/ai-Incubator/Starcat && \
  xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' test
```

### AI 服务配置

支持多种 AI 服务模式：

1. **Starcat Pro**（内置配额）
2. **自建服务**（使用你的云服务器）
3. **BYOK**（使用你自己的 API Key）

支持的 Provider：
- Google Gemini
- OpenAI
- Anthropic Claude
- DeepSeek
- Ollama（本地模型）

## 竞品参考

| 应用 | 特点 |
|------|------|
| [Starship](https://apps.apple.com/us/app/starship-your-stars-on-github/id1530665887) | 嵌套标签、iCloud 同步 |
| [OhMyStar](https://apps.apple.com/cn/app/ohmystar/id1218642292) | 功能完整、搜索强大 |
| [GithubStarsManager](https://github.com/AmintaCCCP/GithubStarsManager) | AI 摘要、语义搜索、Release 追踪 |

## 定价

| 方案 | 价格 | 说明 |
|------|------|------|
| 免费版 | $0 | GitHub OAuth 与 Stars 同步、本地 SQLite 离线缓存、未分类 / 标签 / 语言视图、过滤、README 预览、Clone URL 与 GitHub 快捷入口、私有笔记、状态管理、本地全文搜索、HTML / Markdown 导出、分享卡片；免费额度为 20 标签 / 4 智能集合 / 5 Release |
| Pro Monthly | $3.99/月 | 不限标签 / 集合 / Release，Release 轮询与通知，AI 摘要、AI 标签推荐、AI Chat、README 翻译、自动 AI 整理、Embedding 语义搜索、LLM 友好的网页上下文、RepoContextPacker、CodeFlow、Trending AI 推荐、BYOK Provider 配置 |
| Pro Yearly | $29.99/年 | 包含 Pro Monthly 全部功能；相比月付节省约 37%，适合长期持续使用 |
| Pro Lifetime | $39.99 买断 | 包含 Pro Monthly 全部功能；一次性付款，终身解锁当前 Pro 功能，无需每月续费 |
| 自建服务 | 免费 | 使用自己的服务器 |

## 文档

- [功能清单](docs/1-立项/功能清单.md) - 完整功能规格
- [功能实现总览](docs/功能实现总览.md) - 主进度索引与工程债
- [详细设计索引](docs/3-设计/详细设计/README.md) - 技术设计文档入口
- [Open Design UI 技能](docs/原型设计/Starcat-UI-SKILL.md) - UI 设计规范

## License

MIT License
