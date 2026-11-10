# 每日热点 API 契约

> 2026-10-30：客户端与服务端共同实施基线。沿用已确认的专题 UI；本轮实现与本地验证，不部署、生产导入或启用生成任务。

## 服务与身份

复用 `starcat-weekly-api`，聚合入口携带 `X-SC-Svc: weekly`。
公开读取使用现有 Weekly `Authorization: Bearer`，写入及批次状态仅使用独立 `ADMIN_API_KEYS`。
所有响应使用 `{"schema_version":1,"data":...}`；失败使用现有 `{"schema_version":1,"error":{"code":"...","message":"..."}}`。
下面示例中的省略字段不允许作为生产响应；可空字段输出 `null`，集合为空输出 `[]`。

逻辑报告 ID 为 `agents-radar:2026-10-28:ai-cli`，跨语言稳定。`revision` 为发布内容的 SHA-256 十六进制值，`catalog_revision` 为十进制版本字符串。日期为上海业务日期 `YYYY-MM-DD`，时间为 RFC 3339 UTC。日报与周刊来源事件完全隔离，任何导入不得自动 Star、加入知识库或增加周刊计数。

## 读取接口

| 路由 | 参数 | data |
|---|---|---|
| `GET /api/v1/daily-radar/catalog` | `language=zh-Hans\|en`、`fallback=true\|false`（默认 true） | `catalog_revision, categories, available_languages, latest_available_date` |
| `GET /api/v1/daily-radar/dates` | 同列表筛选；可选 `month=YYYY-MM`；不接受 cursor | `catalog_revision, dates:[{date,count}], latest_available_date` |
| `GET /api/v1/daily-radar/reports` | 下述筛选，`limit` 默认 20、1–50，`cursor` 可选 | `catalog_revision, requested_language, items, total, next_cursor, featured_id` |
| `GET /api/v1/daily-radar/reports/{id}` | `language`、`fallback`；`revision` 可选，客户端打开文章时必须传选中修订 | 完整详情 |

筛选：`category` 为报告类型（省略表示全部）；`period=daily|weekly|monthly`，默认 daily；`date_from/date_to` 含边界；`language` 默认 en；`fallback` 默认 true；`catalog_revision` 可选但客户端跨目录、日期、分页请求时应携带。空语言参数按默认值，非法值返回 400 `INVALID_REQUEST`。语言规范仅 `zh-Hans` / `en`，上游 `zh` 导入时统一成 `zh-Hans`。

主题目录为 `{id,title,period}`；id 是 `ai-cli/ai-agents/ai-infra/ai-web/ai-trending/ai-hn/ai-ph/ai-arxiv/ai-hf/ai-community/ai-weekly/ai-monthly`。title 是来源展示名称，不能当国际化 key。客户端可将主题归入已确认的 UI 主题组，但请求必须使用真实 category，不能用 UI 分组值充当服务端类型。

目录与日期索引按相同语言策略选取逻辑报告；计数按逻辑报告计数，每份报告仅一次。回退时优先请求语言，其次 en，再 zh-Hans。`latest_available_date` 没有内容时为 null。列表按日期倒序、category 升序、ID 升序排列；`featured_id` 只在第一页返回，且必须属于本页 items，客户端提升为主卡片后不重复展示。

游标绑定目录版本、全部筛选条件、limit 和排序位置；不提供目录快照。版本变化或预期目录版本过期返回 409 `CATALOG_CHANGED`，其他身份不符返回 400 `INVALID_CURSOR`。先检查版本再比较 ETag，禁止旧 304 绕过版本检查。客户端保持旧页面至新首屏准备好，不能拼接两个版本的分页结果。

### 摘要

```json
{
  "id": "agents-radar:2026-10-28:ai-cli",
  "revision": "64-character-sha256",
  "edition_date": "2026-10-28",
  "category": "ai-cli",
  "period": "daily",
  "title": "AI CLI 日报",
  "summary": "报告摘要",
  "reading_minutes": 8,
  "cover": {
    "kind": "category",
    "card_url": null,
    "hero_url": null,
    "fallback": "orbit",
    "alt": "AI CLI"
  },
  "related_project_count": 1,
  "content_language": "zh-Hans",
  "available_languages": ["en", "zh-Hans"]
}
```

封面 URL 可空：首版缺少已配置 CDN 时采用内置分类图，不能用无效 URL 或线上样例图冒充已生成封面。`fallback` 仅 `orbit|studio`，远程下载失败使用同一备用图。受控发布时只接受 HTTPS 封面，且校验允许域名；服务不抓取发布请求提供的 URL。封面变更形成新修订。

### 详情

详情为摘要的全部字段，另加：

```json
{
  "source": {
    "name": "agents-radar",
    "url": "https://github.com/duanyytop/agents-radar/blob/COMMIT/digests/2026-10-28/ai-cli.md",
    "commit": "COMMIT",
    "path": "digests/2026-10-28/ai-cli.md"
  },
  "markdown": "# AI CLI 日报\n\n正文",
  "related_projects": [
    {
      "repo": {
        "gh_repo_id": 123,
        "full_name": "owner/repo",
        "owner": "owner",
        "repo": "repo",
        "owner_avatar": null,
        "description": "项目简介",
        "language": "Swift",
        "stars": 10,
        "forks": 1,
        "watchers": 10,
        "subscribers": 1,
        "topics": [],
        "homepage": null,
        "license_spdx": "MIT",
        "is_archived": false,
        "is_fork": false,
        "is_private": false,
        "default_branch": "main",
        "open_issues": 0,
        "pushed_at": null,
        "updated_at": null,
        "created_at": null,
        "html_url": "https://github.com/owner/repo"
      },
      "evidence_url": "https://github.com/owner/repo",
      "section_anchor": null
    }
  ],
  "related_projects_status": "complete",
  "generated_at": "2026-10-28T01:00:00Z",
  "updated_at": "2026-10-28T02:00:00Z"
}
```

repo 复用既有 StarcatRepoCardDTO 的核心字段，无 weekly 扩展；仅已核验的公开仓库可出现。关联状态为 `pending|partial|complete`，零项目合法。原始证据链接保持 Issue / PR / Release 语义，项目按仓库 ID 去重。详情不存在返回 404 `REPORT_NOT_FOUND`；指定修订不存在返回 404 `REVISION_NOT_FOUND`；没有指定语言且禁止回退返回 404 `LANGUAGE_UNAVAILABLE`。

## 缓存与客户端约束

读取返回 ETag，支持 `If-None-Match` / 304；目录与列表 `Cache-Control: private, max-age=600`，指定修订详情 `private, max-age=86400`。服务内允许跨同权限公共内容复用缓存，鉴权必须先执行。聚合网关保持状态与缓存头透传。

客户端缓存命名空间含服务地址、契约版本及凭据的不可逆作用域摘要，不保存明文 Key；目录/日期/列表缓存包含完整查询，详情包含 report ID、内容语言、revision。TTL 到期先显示磁盘内容再重验证；错误保留成功内容和原成功时间，304 只更新验证时间。缓存有空间上限，不删除用户数据。阅读固定 revision，后台刷新不替换已打开的正文、封面和项目集合；服务/账号变更取消旧请求并拒绝晚到结果。

完整首屏另按分类、语言和用户选择期次保存原子快照，不以目录修订或尚未恢复的分类周期作为查找前提。三段读取全部成功且目录版本一致才替换快照；中途失败不得覆盖上一份完整结果。冷启动优先恢复快照，网络刷新失败时继续展示并提示缓存状态；已有逐接口缓存仍可用于首次升级恢复。未缓存的筛选或正文显示真实失败状态，不借用其它分类、语言或凭据的数据。

真实内容不得回退到 Debug 示例；无内容与请求失败分别展示。现有项目面板的宽度、高度、动画保持不变。正文使用安全 Markdown 渲染，支持表格和允许的折叠结构，不执行上游脚本；保持单一纵向阅读滚动。

## 管理导入

`POST /internal/daily-radar/imports`，请求：

```json
{
  "idempotency_key": "history-COMMIT-batch-001",
  "source": "agents-radar",
  "source_kind": "upstream",
  "source_repository": "duanyytop/agents-radar",
  "source_sequence": 1,
  "reports": [
    {
      "edition_date": "2026-10-28",
      "category": "ai-cli",
      "language": "zh-Hans",
      "title": "AI CLI 日报",
      "summary": "报告摘要",
      "markdown": "# AI CLI 日报\n\n正文",
      "source_commit": "40-character-git-sha",
      "source_path": "digests/2026-10-28/ai-cli.md",
      "generated_at": "2026-10-28T01:00:00Z",
      "cover": {"kind":"category","card_url":null,"hero_url":null,"fallback":"orbit","alt":"AI CLI"}
    }
  ]
}
```

`source_kind=upstream|starcat`，同语言自生成版本优先；同来源以 source_sequence 排序，旧任务不得覆盖新版本，相同 sequence 内容不同应冲突而不是按到达时间覆盖。`source_repository` 是来源 Git 仓库 `owner/repo`：upstream 缺省为 `duanyytop/agents-radar`，且只接受该仓库；starcat 必须显式指定，并匹配服务配置 `DAILY_RADAR_SOURCE_REPOSITORIES` 的受控生成仓库列表。生成来源 URL 时使用真实仓库、commit 与 path，不能把自生成内容链接到上游不存在的 commit；来源仓库参与候选身份校验和内容修订摘要。相同幂等键及相同请求返回同批次，内容不同返回 409 `IDEMPOTENCY_CONFLICT`。每批 1–50 份，单份 Markdown ≤1MiB，总请求 ≤8MiB。服务端提取链接并经现有 GitHub TokenPool 核验，不信任上传者随意注入项目卡片。

持久化入队后返回 202，data 为 `{id,status,total,published,failed,items}`；`GET /internal/daily-radar/imports/{id}` 同结构，items 为 `{id,status,report_id,revision,error}`（未处理值可空）。后台启动恢复、有限重试；失败保留旧公开内容。发布原子写修订、项目快照、语言指针和目录版本，不在 SQLite 事务内做网络请求。

### 生成器来源修复

`POST /internal/daily-radar/repairs/source-repositories` 无请求体，仅管理员可用，返回 `200 data:{changed:N}`。

固定排除 `duanyytop/agents-radar`、`starcat-app/agents-radar` 与当前 `source_repository` 作为相关项目；正文 Markdown 中的署名链接仍保留。该端点只处理已发布修订中的误收项：生成新的不可变修订、更新摘要计数与当前发布指针，并让 `catalog_revision` 前进一次。旧修订必须仍可按原 revision 读取，`daily_radar_sources` 的候选序列与原修订指针不变，未来更高 sequence 的导入可正常覆盖。端点幂等，第二次调用在没有新污染数据时返回 `changed:0`。

2026-10-30 生产验收：首轮修复 `changed:3905`，重复调用 `changed:0`；目录版本 `3921`、语言版本总数 `3920`，分页计数一致且无重复，抽样报告不再包含两个生成器仓库。

本地历史导入命令只读指定的 agents-radar Git checkout 与固定 commit，扫描标准报告及旧类型，记录跳过原因，受控提交到管理接口；默认 dry-run。日常自生成产物使用同一管理接口。本轮提供代码和测试，不启动真实生成、付费生图、生产历史导入或定时任务。
