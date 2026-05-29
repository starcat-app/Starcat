# CLAUDE.md

本文档为 Claude Code (claude.ai/code) 在本代码库工作时提供指导。

## 项目概述

Starcat 是一款面向 Apple 平台（macOS、iPhone、iPad、watchOS）的 GitHub Star 管理工具，将扁平的 GitHub 收藏转化为可搜索、AI 驱动的知识库。项目处于**预开发规划阶段**——尚无任何代码。

**核心价值**: 整理、理解、找回、评估

## 关键文档

- `think.md` - 完整产品规格说明，包含竞品分析（OhMyStar、Starship、Starflare）、功能列表、MVP 范围和差异化策略
- `tech-selection.md` - 技术栈决策、同步/搜索/README 渲染/AI 功能的实现方案
- `AGENTS.md` - Agent 相关思考（可能演进为 AI Agent 架构）
- `think/` - 竞品 UI 截图与分析

## 技术栈（已确定）

### 客户端
- **SwiftUI** - 统一覆盖 macOS、iOS、iPadOS、watchOS
- **Swift Concurrency** - 处理同步、分页、缓存、AI 队列等异步操作
- **AppKit bridge** - 补充 macOS 特有能力（菜单栏、独立窗口、pin 窗口、快捷键）
- **WidgetKit / App Intents** - 支持 Spotlight、Shortcuts 和系统入口
- **StoreKit 2** - 订阅、买断、恢复购买

### 数据层
- **SQLite/GRDB** - 存储 repo 缓存、README 缓存、搜索索引、同步状态
- **FTS5** - 实现本地全文搜索（repo name、description、notes、README）
- **CloudKit** - 同步用户生成数据（tags、collections、notes、status、saved searches）
- **Keychain** - 保存 GitHub token 和用户自定义 AI provider key

### 网络层
- **GitHub REST API** - stars 同步、repo 元数据、README、releases、issues 概览
- **URLSession** - 配合 ETag/Last-Modified 做缓存
- 分页队列和限流 - 避免 GitHub API rate limit

### AI（未来）
- **BYOK 模式**: 用户自行提供 OpenAI/Anthropic/Gemini key
- **Starcat Pro**: 内置 AI 配额，通过自有服务转发
- Embedding 用于语义搜索，本地存储

## 架构决策

1. **本地优先**: 用户数据（tags、notes、status）与 repo 缓存分离。repo 缓存可重建，用户数据不能丢失
2. **AI 保守策略**: AI 只给建议，用户确认后才写入。标签不经确认绝不自动应用
3. **Apple 原生**: 不使用 Electron/Tauri/Flutter，原生体验是核心差异化之一
4. **冲突解决**: CloudKit 采用基于时间的合并策略，删除操作保留 tombstone

## MVP 范围

**必须包含**:
- GitHub OAuth 登录
- 拉取和增量同步 stars
- 本地 SQLite 缓存
- macOS 三栏布局（Sidebar / Repo List / Detail）
- Tags、Untagged、Languages 视图
- 搜索和基础过滤
- README Markdown 渲染
- 私有笔记、状态管理
- JSON 导入导出

**MVP AI 功能**:
- 单仓库 AI 摘要
- 单仓库 AI 标签推荐
- 批量整理未分类 repo
- 最小化自然语言语义搜索

## 开发注意事项

- 全新项目，无历史代码需要维护
- 用户面向的内容遵循中文文档风格
- 技术术语保留英文原文，可配中文解释
- 设计时考虑未来多平台代码共享
