# Starcat 集成 CodeFlow 方案

## 背景

Starcat 当前已经规划接入：

1. Repomix（AI 上下文打包）
2. CodeGraphContext（代码图谱分析）

为了支持这两项能力，Starcat 必须实现：

```text
GitHub Repo
    ↓
Clone 到本地
    ↓
本地缓存管理
```

既然仓库已经存在本地，那么可以顺带集成 CodeFlow。

CodeFlow 更适合作为：

> Starcat 的项目架构可视化引擎

而不是 AI 分析引擎。

---

## 定位

### Repomix

用于：

- AI 摘要
- AI 问答
- AI Agent 上下文

### CodeFlow

用于：

- 架构图
- 依赖图
- Blast Radius
- Health Score
- 风险文件分析

### CodeGraphContext

用于：

- 调用链
- 类关系
- 复杂度分析
- 死代码分析
- MCP 查询

---

## 总体架构

```text
Local Repo Cache
        │
        ├── Repomix
        │     └── AI Context
        │
        ├── CodeFlow
        │     └── Architecture Visualization
        │
        └── CodeGraphContext
              └── Deep Code Graph
```

---

## 本地目录规划

```text
~/Library/Application Support/Starcat/

repos/
  github.com_owner_repo/

analysis/
  github.com_owner_repo/
    repomix/
    codeflow/
    codegraphcontext/
```

---

## 集成方式

推荐直接内置 CodeFlow。

```text
Starcat.app
└── Resources
    └── codeflow
        └── index.html
```

通过 WKWebView 加载。

```swift
webView.loadFileURL(...)
```

---

## 数据流

```text
GitHub Repo
      ↓
Clone Repo
      ↓
Local Repo Cache
      ↓
CodeFlow
      ↓
Architecture Map
```

---

## 与 Starcat 的交互

### Phase 1

用户点击：

```text
Open Architecture Map
```

打开 CodeFlow 页面。

用户自行选择仓库目录。

### Phase 2

Starcat 自动：

```text
读取仓库
过滤无关目录
注入 CodeFlow
开始分析
```

无需用户选择目录。

### Phase 3

分析结果导出：

```text
report.json
report.md
graph.svg
```

存储到：

```text
analysis/codeflow/
```

---

## AI 联动

CodeFlow 输出：

- 文件统计
- 语言统计
- 风险文件
- 模块依赖
- Health Score

可拼接到：

```text
README
+ Repo Metadata
+ Repomix
+ CodeFlow Summary
```

用于生成：

- 项目架构摘要
- 模块说明
- 风险分析
- 重构建议

---

## UI 设计

新增：

```text
README
Activity
AI Summary
Architecture
```

Architecture 页面：

```text
Overview
Dependency Graph
Blast Radius
Health Score
Reports
```

---

## 与 CodeGraphContext 的分工

```text
CodeFlow
    ↓
快速架构可视化

CodeGraphContext
    ↓
深度代码图谱分析
```

最终：

```text
Quick Map  -> CodeFlow
Deep Graph -> CodeGraphContext
```

---

## 推荐实施顺序

### 第一阶段

- Clone Repo
- 内置 CodeFlow
- 打开架构图

### 第二阶段

- 自动分析
- 导出报告

### 第三阶段

- AI 摘要集成

### 第四阶段

- CodeGraphContext 联动

---

## 结论

CodeFlow 不应替代 Repomix 或 CodeGraphContext。

最佳定位：

> Starcat 的项目架构可视化组件

最终形成：

```text
Repomix
    ↓
AI Context

CodeFlow
    ↓
Architecture Visualization

CodeGraphContext
    ↓
Deep Code Analysis
```
