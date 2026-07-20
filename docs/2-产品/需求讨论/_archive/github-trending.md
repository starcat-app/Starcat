下面是一份 Starcat - GitHub Trending REST API 实现方案，按你已经确认的方向来设计：

使用 https://github.com/starcat-app/starcat-trending-api 作为独立服务仓库，实现 GitHub Trending 的 REST API；该仓库后续由你自己维护，并作为 Starcat 的 Trending 数据源。

⸻

GitHub Trending REST API 实现方案

1. 背景与目标

Starcat 需要实现一个 “当日 / 本周 / 本月 GitHub 热门项目” 功能，用于展示：

* 今日热门项目
* 本周热门项目
* 本月热门项目
* 按语言筛选的热门项目
* 后续可扩展为 AI 项目摘要、每日推荐、技术情报流

GitHub 官方虽然提供了 Trending 页面：

https://github.com/trending
https://github.com/trending?since=daily
https://github.com/trending?since=weekly
https://github.com/trending?since=monthly

但 GitHub REST API 没有官方 Trending 接口。GitHub Trending 本身是页面功能，而不是公开 API。GitHub Trending 页面用于展示社区近期最关注的仓库，页面支持 daily / weekly / monthly 维度。 ￼

因此，Starcat 采用以下方式：

GitHub Trending 页面
        ↓
starcat-app/starcat-trending-api 服务端抓取
        ↓
解析为结构化数据
        ↓
提供 REST API
        ↓
Starcat App 调用

⸻

2. 项目定位

仓库

https://github.com/starcat-app/starcat-trending-api

项目职责

这个项目只做一件事：

将 GitHub Trending 页面数据转换为稳定、可缓存、可扩展的 REST API。

它不直接承担 Starcat 的业务逻辑，也不做 AI 分析。AI 摘要、用户个性化推荐、收藏入库等逻辑放在 Starcat 后端或 Starcat App 中处理。

⸻

3. 整体架构

┌────────────────────────────────────────────────────────────┐
│                    Starcat App                             │
│                                                            │
│  - 展示今日热门 / 本周热门 / 本月热门                       │
│  - 按语言过滤                                               │
│  - 点击收藏到 GitHub Stars                                  │
│  - 后续显示 AI 摘要 / 推荐理由                              │
└──────────────────────────────┬─────────────────────────────┘
                               │
                               │ REST API
                               ↓
┌────────────────────────────────────────────────────────────┐
│              starcat-app/starcat-trending-api                    │
│                                                            │
│  - 抓取 GitHub Trending 页面                                │
│  - 解析 HTML                                                │
│  - 标准化数据结构                                           │
│  - 缓存 daily / weekly / monthly 数据                       │
│  - 提供 REST API                                            │
│  - 支持语言筛选                                             │
└──────────────────────────────┬─────────────────────────────┘
                               │
                               │ HTTP Scraping
                               ↓
┌────────────────────────────────────────────────────────────┐
│                   GitHub Trending                          │
│                                                            │
│  https://github.com/trending                               │
│  https://github.com/trending/{language}?since=daily        │
└────────────────────────────────────────────────────────────┘

⸻

4. 数据来源设计

4.1 GitHub Trending 页面

基础页面：

https://github.com/trending

周期参数：

https://github.com/trending?since=daily
https://github.com/trending?since=weekly
https://github.com/trending?since=monthly

语言筛选：

https://github.com/trending/swift?since=daily
https://github.com/trending/java?since=weekly
https://github.com/trending/go?since=monthly

GitHub Trending 页面支持按时间周期和编程语言筛选；不少社区工具也是通过解析 Trending 页面实现对应能力，例如有工具说明其支持 language 和 since 参数，since 可选 daily / weekly / monthly。 ￼

⸻

5. REST API 设计

5.1 获取热门仓库

GET /api/v1/trending/repositories

Query 参数

参数	类型	默认值	说明
since	string	daily	daily / weekly / monthly
language	string	空	编程语言，如 Swift、Java、Go
spoken_language	string	空	自然语言筛选，如 zh、en，可后续支持
limit	int	25	返回数量
refresh	boolean	false	是否强制刷新，建议仅管理端使用

示例

GET /api/v1/trending/repositories?since=daily
GET /api/v1/trending/repositories?since=weekly&language=Swift
GET /api/v1/trending/repositories?since=monthly&language=Java&limit=50

⸻

5.2 响应结构

{
  "code": 0,
  "message": "success",
  "data": {
    "source": "github_trending",
    "since": "daily",
    "language": "Swift",
    "spokenLanguage": null,
    "fetchedAt": "2026-05-30T10:00:00Z",
    "cacheHit": true,
    "items": [
      {
        "rank": 1,
        "owner": "owner",
        "name": "repo",
        "fullName": "owner/repo",
        "url": "https://github.com/owner/repo",
        "description": "Repository description",
        "language": "Swift",
        "languageColor": "#F05138",
        "stars": 12345,
        "forks": 678,
        "starsInPeriod": 321,
        "periodText": "321 stars today",
        "builtBy": [
          {
            "username": "user1",
            "avatar": "https://avatars.githubusercontent.com/u/xxx",
            "url": "https://github.com/user1"
          }
        ]
      }
    ]
  }
}

⸻

6. 字段说明

字段	说明
rank	当前榜单排名
owner	仓库 owner
name	仓库名
fullName	owner/repo
url	GitHub 仓库地址
description	仓库描述
language	主要语言
languageColor	语言颜色，可从页面解析，也可服务端维护映射表
stars	当前总 stars
forks	当前 forks
starsInPeriod	当前周期新增 stars
periodText	页面原始文案，如 123 stars today
builtBy	Trending 页面展示的贡献者头像列表
fetchedAt	数据抓取时间
cacheHit	是否命中缓存

⸻

7. 缓存策略

GitHub Trending 不是强实时数据，建议服务端缓存。

7.1 缓存 Key

github:trending:repositories:{since}:{language}:{spoken_language}

示例：

github:trending:repositories:daily:swift:all
github:trending:repositories:weekly:java:all
github:trending:repositories:monthly:all:all

7.2 TTL 建议

since	TTL	说明
daily	30 分钟 ~ 1 小时	当日榜单变化相对频繁
weekly	2 ~ 6 小时	周榜变化较慢
monthly	6 ~ 12 小时	月榜变化更慢

7.3 缓存层级

建议两级缓存：

内存缓存 Caffeine / Go map + TTL
        ↓
Redis 缓存
        ↓
数据库历史快照，可选
        ↓
GitHub Trending 页面

第一版可以先做：

Redis / SQLite 缓存 + 定时刷新

⸻

8. 定时任务设计

8.1 基础刷新任务

定时抓取：

daily   每 30 分钟抓一次
weekly  每 2 小时抓一次
monthly 每 6 小时抓一次

8.2 默认语言列表

建议先配置一组 Starcat 关注的语言：

trending:
  languages:
    - all
    - Swift
    - Java
    - Go
    - Python
    - TypeScript
    - JavaScript
    - Rust
    - Kotlin
    - Dart

8.3 任务矩阵

since: daily, weekly, monthly
language: all, Swift, Java, Go, Python, TypeScript, JavaScript, Rust

组合数量：

3 * 8 = 24 个抓取任务

这个量很小，完全可控。

⸻

9. HTML 解析策略

9.1 推荐解析字段

从每个 Trending 仓库条目中解析：

repo full name
description
language
language color
stars
forks
stars in period
built by users
repo url

9.2 解析注意事项

GitHub Trending 是 HTML 页面，不是稳定 API，所以解析器需要做容错：

* 不强依赖过深的 CSS 选择器
* 尽量根据语义结构解析
* 对字段缺失做降级
* 保存原始 HTML 片段用于调试
* 添加单元测试覆盖典型页面结构
* 当解析结果为空时报警

⸻

10. 降级策略

当 GitHub 页面结构变化或抓取失败时，不能影响 Starcat App 使用。

建议降级顺序：

1. 返回 Redis / DB 中最近一次成功缓存
2. 如果缓存过期但仍存在，标记 stale=true 返回
3. 如果没有缓存，返回空列表 + 明确错误码
4. 后台记录报警日志

响应示例：

{
  "code": 0,
  "message": "success",
  "data": {
    "source": "github_trending",
    "since": "daily",
    "language": "Swift",
    "fetchedAt": "2026-05-30T08:00:00Z",
    "cacheHit": true,
    "stale": true,
    "items": []
  }
}

⸻

11. 错误码设计

code	说明
0	成功
40001	参数错误
40401	不支持的语言或周期
50201	GitHub Trending 抓取失败
50202	GitHub Trending 页面解析失败
50301	缓存不可用
50000	服务内部错误

⸻

12. 服务端技术选型建议

你后续自己维护，建议选你维护成本最低的技术栈。

方案 A：Go

适合做轻量独立服务。

推荐组合：

Go
Gin / Fiber
goquery
Redis
SQLite / PostgreSQL
cron
Docker

优点：

* 单二进制部署简单
* 抓取和解析性能好
* 适合做小型工具服务
* 后续也方便提供 CLI

方案 B：Java / Spring Boot

适合并入你现有 Zeka Stack 体系。

推荐组合：

Spring Boot
Jsoup
Caffeine
Redis
PostgreSQL / SQLite
Spring Scheduler / Quartz
Docker

优点：

* 你最熟悉
* 工程规范、日志、监控、配置都好接入
* 方便后续纳入 Starcat 后端体系

我的建议

如果这个仓库定位为 独立 GitHub Trending REST API 工具，建议用：

Go + goquery + Redis + SQLite

如果这个仓库后续会并入你的 Java 工程体系，建议用：

Spring Boot + Jsoup + Caffeine + Redis

⸻

13. 数据表设计

第一版可以不强依赖数据库，只用缓存。

但为了后续做 Starcat 自己的趋势分析，建议保留历史快照。

13.1 trending_snapshot

CREATE TABLE trending_snapshot (
    id BIGINT PRIMARY KEY,
    source VARCHAR(64) NOT NULL,
    since_type VARCHAR(16) NOT NULL,
    language VARCHAR(64),
    spoken_language VARCHAR(32),
    fetched_at TIMESTAMP NOT NULL,
    raw_url VARCHAR(512) NOT NULL,
    raw_html_hash VARCHAR(64),
    item_count INT NOT NULL,
    success BOOLEAN NOT NULL,
    error_message TEXT
);

13.2 trending_repository_item

CREATE TABLE trending_repository_item (
    id BIGINT PRIMARY KEY,
    snapshot_id BIGINT NOT NULL,
    rank_no INT NOT NULL,
    owner VARCHAR(128) NOT NULL,
    name VARCHAR(128) NOT NULL,
    full_name VARCHAR(256) NOT NULL,
    url VARCHAR(512) NOT NULL,
    description TEXT,
    language VARCHAR(64),
    language_color VARCHAR(16),
    stars BIGINT,
    forks BIGINT,
    stars_in_period INT,
    period_text VARCHAR(128),
    built_by_json TEXT,
    created_at TIMESTAMP NOT NULL
);

13.3 唯一索引建议

CREATE UNIQUE INDEX uk_snapshot_key
ON trending_snapshot(source, since_type, language, spoken_language, fetched_at);
CREATE INDEX idx_trending_repo_full_name
ON trending_repository_item(full_name);
CREATE INDEX idx_trending_repo_snapshot
ON trending_repository_item(snapshot_id);

⸻

14. Starcat 侧集成方式

Starcat App 不直接请求 GitHub Trending 页面，而是请求你的 REST API：

Starcat App
    ↓
GET https://api.starcat.xxx/api/v1/trending/repositories?since=daily&language=Swift
    ↓
starcat-app/starcat-trending-api
    ↓
GitHub Trending Cache

App 页面建议

Explore / 发现
├── GitHub Trending
│   ├── Today
│   ├── This Week
│   └── This Month
├── Language Filter
│   ├── All
│   ├── Swift
│   ├── Java
│   ├── Go
│   └── Python
└── Repo Card
    ├── repo name
    ├── description
    ├── language
    ├── stars / forks
    ├── stars today / this week / this month
    └── Star / View / AI Summary

⸻

15. 后续扩展：Starcat Discovery

starcat-trending-api 第一阶段只负责复刻 GitHub Trending 数据。

后续 Starcat 可以基于这些数据继续做：

GitHub Trending 原始榜单
        ↓
补充 GitHub API repo details
        ↓
补充 README
        ↓
AI 摘要
        ↓
AI 标签
        ↓
项目质量评分
        ↓
个性化推荐

也就是分成两层：

层级	项目	职责
数据层	starcat-app/starcat-trending-api	抓取 GitHub Trending，提供结构化 API
智能层	Starcat	AI 分析、推荐、收藏、知识库

⸻

16. 维护策略

因为这个项目后续由你自己维护，所以建议一开始就做好这些事情。

16.1 单元测试

至少覆盖：

* daily all language 页面解析
* weekly all language 页面解析
* monthly all language 页面解析
* 指定语言页面解析
* 无语言字段项目解析
* 无 stars in period 项目解析
* GitHub 页面结构变化时的空结果检测

16.2 Fixture 测试

建议把 GitHub Trending HTML 保存成测试资源：

testdata/
├── trending-daily.html
├── trending-weekly.html
├── trending-monthly.html
├── trending-swift-daily.html
└── trending-java-weekly.html

解析器测试不直接访问 GitHub，而是基于 fixture 测。

16.3 线上监控

关键指标：

trending_fetch_success_total
trending_fetch_failure_total
trending_parse_success_total
trending_parse_empty_total
trending_cache_hit_total
trending_cache_miss_total
trending_fetch_duration_seconds

16.4 告警条件

连续 3 次抓取失败
连续 3 次解析结果为空
daily all 榜单 item_count < 5
GitHub 返回 403 / 429

⸻

17. MVP 开发优先级

P0：必须完成

1. GET /api/v1/trending/repositories
2. 支持 since=daily/weekly/monthly
3. 支持 language 参数
4. HTML 抓取
5. HTML 解析
6. 统一响应结构
7. 缓存
8. Docker 部署

P1：建议紧跟

1. 定时刷新
2. SQLite / PostgreSQL 历史快照
3. 管理接口手动刷新
4. 解析失败降级
5. 单元测试 + fixture 测试
6. GitHub Actions 自动测试

P2：后续增强

1. Trending Developers API
2. spoken language 支持
3. RSS 输出
4. OpenAPI 文档
5. SDK / CLI
6. Starcat Discovery Score
7. AI 摘要预处理

⸻

18. 推荐 API 列表

仓库 Trending

GET /api/v1/trending/repositories?since=daily
GET /api/v1/trending/repositories?since=weekly
GET /api/v1/trending/repositories?since=monthly
GET /api/v1/trending/repositories?since=daily&language=Swift

开发者 Trending，后续可选

GET /api/v1/trending/developers?since=daily
GET /api/v1/trending/developers?since=weekly&language=Go

语言列表

GET /api/v1/trending/languages

手动刷新，管理端

POST /api/v1/admin/trending/refresh

请求：

{
  "since": "daily",
  "language": "Swift"
}

⸻

19. 推荐项目 README 描述

可以把 starcat-app/starcat-trending-api 定位成：

GitHub Trending REST API service.
This project scrapes GitHub Trending pages, normalizes repository and developer data, caches results, and exposes a stable REST API for applications such as Starcat.

中文描述：

GitHub Trending REST API 服务。
本项目通过抓取 GitHub Trending 页面，将 daily / weekly / monthly 热门仓库和开发者数据解析为结构化 JSON，并提供稳定的 REST API，主要作为 Starcat 的开源项目发现数据源。

⸻

20. 最终结论

Starcat 的 GitHub Trending 功能建议按下面方式落地：

1. 使用 https://github.com/starcat-app/starcat-trending-api 作为独立服务仓库
2. 服务端抓取 GitHub Trending 页面，而不是客户端直接抓
3. 对外提供稳定 REST API
4. 支持 daily / weekly / monthly
5. 支持 language 过滤
6. 使用缓存减少对 GitHub 页面请求
7. 保存历史快照，为后续 Starcat Discovery 和 AI 推荐做准备
8. Starcat App 只消费该服务的 JSON API

一句话概括：

starcat-app/starcat-trending-api 负责把 GitHub Trending 页面变成稳定 API；Starcat 负责基于这个 API 做展示、收藏、AI 摘要和个性化发现。