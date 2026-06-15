---
title: "Starcat 上线了：把 GitHub Stars 从收藏夹变成知识库"
date: 2026-06-15
author: dong4j
tags: [Starcat, GitHub, macOS, 效率工具, AI]
description: "介绍一款面向 Apple 平台的 GitHub Star 管理与 AI 知识整理工具——Starcat。"
---

# Starcat 上线了：把 GitHub Stars 从收藏夹变成知识库

## 背景：GitHub Stars 的困境

每个开发者都有这样的经历：在 GitHub 上看到一个好项目，随手点了 Star，心想"以后再看"。几个月后，你积攒了几百上千个 Star，但当你真正需要找到"上次那个做动画的库"时，翻遍列表也找不到。

GitHub 原生的 Star 管理只有两个功能：列表展示和按语言筛选。没有标签，没有搜索（在 Star 列表内），没有笔记。Star 变成了一个"数字收藏癖"——点了就忘，忘了再点。

作为一个重度 GitHub 用户，我在 2024 年底开始了 Starcat 的开发。目标很简单：**把 GitHub Stars 从一个扁平的书签列表，变成可搜索、可分类、可回顾的个人知识库**。

## Starcat 是什么

Starcat 是一款 macOS 原生应用，核心围绕四个动词：

- **整理**：自定义标签、阅读状态、私有笔记，让你按自己的方式组织项目
- **理解**：AI 自动生成项目摘要，帮你快速判断一个项目值不值得深入
- **找回**：全文搜索 + 语义搜索，说人话就能找到你 Star 过的任何项目
- **评估**：AI 项目健康度评估，帮你判断一个开源项目的活跃度和可靠性

## 为什么是 macOS 原生

Starcat 选择 SwiftUI + macOS 15 原生开发，而不是 Electron 或跨平台方案。理由很明确：

1. **体验优先**：原生三栏布局、Liquid Glass 设计语言、系统级 Keychain 加密——这些是跨平台框架做不到的
2. **数据安全**：GitHub Token 和 AI API Key 存储在 Secure Enclave 中，用户数据优先本地存储
3. **性能**：GRDB.swift (SQLite) 的 FTS5 全文搜索，对于上万条记录的搜索依然毫秒级响应

## 免费版 vs Pro 版

Starcat 分两个版本：

**免费版**包含完整的 Star 管理功能：OAuth 登录、增量同步、标签分类、全文搜索、README 渲染、私有笔记、JSON 导入导出——覆盖日常使用绰绰有余。

**Pro 版**解锁 AI 增强功能：智能摘要、标签推荐、语义搜索、每日推荐、项目健康度评估，以及 Release 订阅追踪。

AI 功能支持多种服务模式：使用内置配额、自建服务器、或自带 API Key（支持 OpenAI、Claude、Gemini、DeepSeek、Ollama 等）。

## 数据属于你

Starcat 坚持 **"本地优先"**原则。你的标签、笔记、状态存储在本地 SQLite 中，可随时导出为 JSON 格式（兼容 OhMyStar、Astral）。没有平台锁定，数据永远在你手里。

## 接下来

Starcat 即将上架 Apple App Store。如果你也是一个"Star 收藏家"，欢迎试试看。

- **GitHub 仓库**：[github.com/dong4j/Starcat](https://github.com/dong4j/Starcat)
- **官方网站**：[starcat.app](https://starcat.app)

> 整理、理解、找回、评估——让每一个 Star 都值得被记住。
