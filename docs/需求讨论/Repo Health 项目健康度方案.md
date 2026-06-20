# Repo Health 项目健康度方案

> 日期：2026-06-20  
> 状态：v1 方案确认，准备实施  
> 范围：复用现有 OpenSSF 评分基础，新增总健康度缓存与详情页入口

## 目标

Repo Health 用一个可解释的健康度分数帮助用户判断项目是否值得继续关注、采用或替换。

第一版只做确定性评分，不引入 AI 主观判断。AI 后续可以基于健康度快照生成解释或对比报告。

## 详情页入口

现有详情页 `full_name` 同行已有 OpenSSF 安全评分入口。第一版将它升级为健康度入口：

- 在 repo 名称右侧展示 Health badge。
- 有缓存时显示分数或等级。
- 无缓存时显示中性占位。
- 点击打开 `RepoHealthSheet`。

OpenSSF 不删除，作为 Health 面板里的 Security 维度继续展示。

## 评分维度

第一版总分 0-100，分为四个维度：

- Maintenance：最近 push、最近 release、archived 状态
- Popularity：stars、forks、watchers
- Quality：license、README、topics、homepage、open issues
- Security：OpenSSF Scorecard

总分采用确定性加权：

```text
overall = maintenance * 0.35
        + popularity  * 0.20
        + quality     * 0.20
        + security    * 0.25
```

如果某个维度缺少数据，按保守中性分处理，并在 payload 中记录缺失原因。

## 后台计算

健康度不在详情页同步打 GitHub API。

第一版新增缓存表 `repo_health_snapshots`：

- `repo_id`
- `overall_score`
- `grade`
- `maintenance_score`
- `popularity_score`
- `quality_score`
- `security_score`
- `payload_json`
- `computed_at`
- `stale_after`
- `fetch_status`

后台流程：

1. `RepoHealthService` 聚合本地 Repo、Release 缓存、OpenSSF 缓存。
2. `RepoHealthStore` 给 UI 同步读取 badge，缺缓存时非阻塞预拉。
3. `RepoHealthPoller` 每天刷新一批 stale starred repos。

## GitHub API 策略

第一版不为每个 repo 额外打多条 GitHub API。

优先使用现有数据：

- stars / forks / watchers / topics / license / pushed_at 来自 `repos`
- release 信息来自已有 `releases`
- security 信息来自已有 OpenSSF 缓存

后续如果需要更细的 issue 响应速度、PR 数、commit 频率，再新增专门端点与缓存表。

## 与 Smart Collections 的关系

Smart Collections 直接消费 Repo Health 快照：

- Needs Review：低健康度、归档或关键字段缺失
- Unmaintained：维护分低
- High Value：健康度高且 star 高
- Recently Active：维护分高且近期有活动

因此实施顺序是先落 Repo Health，再接 Smart Collections。

## 不做范围

- 不做 AI 生成健康度。
- 不实时抓每个 repo 的 issue / PR / commit 详情。
- 不把完整 Health 面板常驻塞进详情页，避免挤压 README 阅读区。
- 不对未 star 的 ephemeral repo 持久化健康度。
