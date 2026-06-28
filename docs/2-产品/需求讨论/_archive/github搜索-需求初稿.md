# Starcat GitHub 全站搜索接入方案

## 目标

在 Starcat 中接入 GitHub 全站 Repository 搜索能力，实现：

- GitHub 全站项目搜索
- 多维度筛选
- 分页加载
- 本地缓存
- AI 增强分析
- 与 Starcat 现有 Repo 体系融合

---

## 技术方案选择

### 推荐方案

优先采用 GitHub REST Search API：

```http
GET https://api.github.com/search/repositories
```

示例：

```http
GET /search/repositories?q=swiftui+language:swift+stars:>100&sort=stars&order=desc&page=1&per_page=30
```

优势：

- 官方支持
- 文档完善
- 实现简单
- 支持丰富筛选条件
- 支持分页
- 支持排序

---

## 产品设计

新增一级菜单：

```text
Search
├── GitHub Search
│   ├── Keyword
│   ├── Language
│   ├── Topic
│   ├── Stars
│   ├── Created Date
│   ├── Updated Date
│   └── Sort
```

---

## 搜索结果展示

每个 Repo 卡片显示：

```text
owner/repo

description

language
stars
forks
license
updatedAt

topics

[README]
[AI Analyze]
[Favorite]
[Open GitHub]
```

---

## 查询模型

```swift
struct GitHubRepoSearchQuery {
    var keyword: String
    var language: String?
    var topic: String?
    var minStars: Int?
    var pushedAfter: Date?
    var createdAfter: Date?
    var sort: Sort
    var order: Order
    var page: Int
    var perPage: Int
}
```

---

## Query 组装规则

示例：

```text
swiftui language:Swift stars:>100
```

```text
ai agent topic:agent stars:>500
```

```text
mcp pushed:>2026-01-01
```

```text
macos language:Swift stars:>100
```

---

## 后端架构

推荐采用服务端代理模式：

```text
Starcat App
      ↓
Starcat Backend
      ↓
GitHub REST API
```

职责：

- GitHub Token 管理
- Rate Limit 控制
- 搜索缓存
- 数据裁剪
- AI 分类增强
- 热门搜索统计

---

## Starcat Backend API

```http
GET /api/github/search/repositories
```

参数：

```text
q
language
topic
minStars
createdAfter
pushedAfter
sort
order
page
perPage
```

返回结构：

```json
{
  "total": 123456,
  "incomplete": false,
  "page": 1,
  "perPage": 30,
  "items": []
}
```

---

## 缓存策略

Cache Key：

```text
github:search:repos:{query}:{sort}:{page}
```

TTL：

```text
首页：10~30分钟
后续页：30~60分钟
```

建议：

- Redis
- 本地数据库二级缓存
- 热门搜索预热

---

## Swift 模块设计

```text
GitHubSearchAPI
GitHubSearchRepository
GitHubSearchViewModel
GitHubSearchView
```

调用链：

```text
View
 ↓
ViewModel
 ↓
Repository
 ↓
API
 ↓
Backend
```

---

## UI 细节

### 搜索框

支持：

- Enter 搜索
- 防抖搜索（500ms）
- 搜索历史

### 筛选器

支持：

- Language
- Topic
- Stars
- Sort
- Updated

### 分页

支持：

- Infinite Scroll
- Pull To Refresh

---

## MVP 阶段

### Phase 1

实现：

- Repository Search
- 分页
- 排序
- README 跳转
- 收藏

### Phase 2

实现：

- Topic Filter
- 时间筛选
- 搜索历史
- 热门搜索

### Phase 3

实现：

- AI 分类
- 相似项目推荐
- 与 Trending 联动
- 与 Show HN 联动
- AI Activity 联动

---

## Starcat 差异化能力

搜索结果增加：

```text
✓ AI Agent
✓ AI Coding
✓ AI MCP
✓ AI RAG
✓ AI Infra
✓ AI Model
✓ AI Skill
```

同时展示：

```text
是否已收藏
是否已缓存 README
是否支持 AI 分析
是否已被 CodeGraphContext 索引
是否已被 DeepWiki 索引
是否已被 CodeWiki 索引
是否已被 ZRead 索引
```

---

## 最终目标

构建：

```text
GitHub Search
        +
Starcat Local Index
        +
AI Analysis
        +
Trending
        +
Show HN
        +
AI Activity
```

形成统一的 AI Native 开发者项目发现平台。
