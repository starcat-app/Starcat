# CLAUDE.md

本文档为 Claude Code 在本代码库工作时提供指导。

---

## ⚠️ 临时技术债提醒（必读，2026-05-30 起生效）

当前 `KeychainManager.swift` 在 **DEBUG 编译下启用了"Keychain + 沙盒文件双写"绕过方案**，
用于解决 ad-hoc 签名 + App Sandbox 导致 token 跨构建无法持久化的问题。

**发布前必须执行完整切换流程**，详见 `docs/工程进度/2026-05-30-Keychain-临时绕过方案.md`。

切换的触发条件：用户完成 Xcode Apple ID Team 配置 → 重新启用 `keychain-access-groups` entitlement → 删除 `#if DEBUG` 块。

> 当本段提醒还在时，意味着这个技术债没还。任何 release 前的工程审查都必须检查这一项。

---

## 项目概述

**Starcat** 是一款面向 Apple 平台的 GitHub Star 管理工具，将扁平的 GitHub 收藏转化为可搜索、AI 驱动的知识库。

- **核心价值**: 整理、理解、找回、评估
- **目标用户**: 独立开发者、技术博主、技术媒体
- **项目状态**: 预开发规划阶段，尚无代码

---

## 文档结构

```
docs/
├── 概要设计.md          # 技术选型方案、阶段规划
├── 功能清单.md          # 功能优先级矩阵（P0/P1/P2）
├── 开发前问题清单.md     # 审查发现的问题及解决方案
├── 需求分析.md          # 竞品分析、需求详述
├── 调研报告.md          # 技术调研
├── CloudKit数据同步设计.md
├── AI代理API设计.md
├── GitHub OAuth 设计.md
└── 详细设计/
    ├── 01-数据库设计.md
    ├── 03-项目结构设计.md
    ├── 04-技术选型.md
    ├── 05-GitHub API设计.md
    └── 06-核心模块设计.md
```

> 详细内容请查阅对应文档。

---

## 技术栈

| 层级 | 技术 | 说明 |
|------|------|------|
| 客户端 | SwiftUI + macOS 15+ | 最低支持 macOS 15 Sequoia |
| 状态管理 | @Observable | Swift 5.9+ 可用 |
| 数据库 | GRDB.swift (SQLite) | 本地缓存、FTS5 全文搜索 |
| 云同步 | CloudKit | 仅同步用户数据（tags、notes、status） |
| 安全存储 | Keychain | GitHub token、AI API key |
| 网络 | URLSession | GitHub REST API |
| AI | BYOK / 自建代理 | Pro 订阅解锁 |

> 详细技术选型见 `docs/详细设计/04-技术选型.md`

---

## 架构决策

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

### MVP 不含

- 语义搜索（延后到 v1.2）
- watchOS（价值待评估）

> 完整功能清单见 `docs/功能清单.md`

---

## 开发规范

- 全新项目，无历史代码需要维护
- 用户面向的内容遵循中文文档风格
- 技术术语保留英文原文，可配中文解释
- 代码必须添加必要注释
- 详细开发规范见 `docs/` 各文档

---

## 已解决的问题

以下问题已在 `docs/开发前问题清单.md` 中确认解决方案：

- ✅ macOS 最低版本：15 Sequoia（兼容 Liquid Glass API）
- ✅ Swift 版本：编译器 6.0 + 语言模式 5 + @Observable
- ✅ README 渲染：WebView（100% GFM 兼容）
- ✅ OAuth scope：`["read:user", "public_repo"]`
- ✅ 后台任务：macOS 用 NSBackgroundActivityScheduler
- ✅ 语义搜索：服务端计算，客户端存缓存

---

*最后更新：2026-05-29*
