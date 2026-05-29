# AGENTS.md

本文档为跨 Agent 协作提供指导，确保多个 Agent 在本代码库工作时保持一致。

---

## 项目概述

**Starcat** 是一款面向 Apple 平台的 GitHub Star 管理工具，将扁平的 GitHub 收藏转化为可搜索、AI 驱动的知识库。

- **核心价值**: 整理、理解、找回、评估
- **目标用户**: 独立开发者、技术博主、技术媒体
- **项目状态**: 预开发规划阶段，尚无代码

---

## 文档导航

| 文档 | 用途 |
|------|------|
| `CLAUDE.md` | 单次会话指导，快速了解项目 |
| `docs/概要设计.md` | 技术选型、阶段规划 |
| `docs/功能清单.md` | 功能优先级矩阵（P0/P1/P2） |
| `docs/开发前问题清单.md` | 已解决的问题及解决方案 |
| `docs/详细设计/*.md` | 模块详细设计 |

> **阅读顺序建议**：先读 `CLAUDE.md` 了解概览，再根据任务需要查阅对应文档。

---

## 技术栈（保持一致）

| 层级 | 技术 | 说明 |
|------|------|------|
| 客户端 | SwiftUI + macOS 15+ | 最低 macOS 15 Sequoia |
| 状态管理 | @Observable | Swift 5.9+ 可用 |
| 数据库 | GRDB.swift (SQLite) | FTS5 全文搜索 |
| 云同步 | CloudKit | 仅同步用户数据 |
| 安全存储 | Keychain | Token 存储 |
| AI | BYOK / 自建代理 | Pro 订阅解锁 |

---

## 架构决策（关键约束）

1. **本地优先**: 用户数据（tags、notes、status）与 repo 缓存分离。repo 缓存可重建，用户数据不能丢失
2. **AI 保守策略**: AI 只给建议，用户确认后才写入。标签不经确认绝不自动应用
3. **Apple 原生**: 不使用 Electron/Tauri/Flutter，原生体验是核心差异化之一
4. **冲突解决**: CloudKit 采用基于时间的合并策略，删除操作保留 tombstone

---

## MVP 范围

### P0 必须功能

- GitHub OAuth 登录（scope: `read:user`, `public_repo`）
- 拉取和增量同步 stars（含手动刷新)
- 本地 SQLite 缓存
- macOS 三栏布局
- Tags、Untagged、Languages 视图
- 搜索和基础过滤（FTS5）
- README WebView 渲染
- 私有笔记、状态管理
- 取消 Star（调用 GitHub API）
- JSON 导入导出

### P1 第一版 AI 功能

- Release 订阅追踪 + 通知
- 单仓库 AI 摘要（Pro 订阅）
- AI 标签推荐（Pro 订阅）

---

## 已解决的问题

以下问题已在 `docs/开发前问题清单.md` 中确认解决方案，开发时必须遵循：

- ✅ macOS 最低版本：15 Sequoia
- ✅ Swift：编译器 6.0 + 语言模式 5 + @Observable
- ✅ README 渲染：WebView（100% GFM 兼容）
- ✅ OAuth scope：`["read:user", "public_repo"]`
- ✅ 后台任务：macOS 用 NSBackgroundActivityScheduler
- ✅ 语义搜索：服务端计算，客户端存缓存
- ✅ Release 订阅通知：使用轮询方案

---

## 跨 Agent 协作规范

### 文档修改

- 修改任何文档前，先检查 `docs/开发前问题清单.md` 确认是否有相关决策
- 跨文档的一致性修改（如技术栈变更），需要同步更新所有相关文档
- 新增设计决策时，在 `开发前问题清单.md` 中记录

### 代码规范

- 代码必须添加必要注释，解释"为什么这样做"
- 遵循现有代码风格
- 详细规范见各设计文档

### 问题处理

- 发现文档间不一致时，以 `开发前问题清单.md` 中的决策为准
- 新发现的问题先记录到 `开发前问题清单.md`，再实施修改

---

*最后更新：2026-05-29*
