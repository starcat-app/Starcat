# 每周 AI 大事 MVP 实现说明

> 状态：独立工作树内实现与验证，待真实内容样板和人工界面验收
>
> 需求依据：[需求规格说明书](../../2-产品/需求讨论/正式方案/每周AI大事需求规格说明书.md)

## 工作区与交付边界

主仓分支 `codex/weekly-ai-events-mvp`，worktree 为
`../Starcat-weekly-ai-events-mvp`，基于 `dev@34b4554c`。
该基线提交已保存独立需求说明书、版本规划链接和已确认决策。

| 仓库 | 本地位置 | 分支与基线 |
|---|---|---|
| Starcat | worktree 根目录 | `codex/weekly-ai-events-mvp`，`34b4554c` |
| Weekly API | `supports/starcat-weekly-api` | 独立仓库同名分支，`dev@622a708` |
| 周报内容与 Skill | `supports/ai-weekly-events` | 本地初始化，同名分支，无远端 |

独立仓库交付提交：内容与 Skill 为 `a307f90`，Weekly API 为 `08c4e02`。

预期内容远端固定为 `starcat-app/ai-weekly-events`，本轮不执行远端创建、
推送、图片上传、生产发布或分支合并。三个仓库分别提交，不能只合并主仓就宣称上线。
主仓 `supports/` 文档和脚本已预登记，远端创建前不启用自动 clone。

## 固定契约

| 项 | 值或规则 |
|---|---|
| 名称 | 每周 AI 大事 |
| 分类 | `ai-weekly-events`，`period=weekly` |
| 来源 | `source=ai-weekly-events`，`source_kind=editorial` |
| 内容仓库 | `source_repository=starcat-app/ai-weekly-events`，须服务允许清单 |
| 报告身份 | `ai-weekly-events:<edition_date>:ai-weekly-events` |
| 语言 | `zh-Hans` 与 `en` 同一期、同内容提交，成对入队 |
| 固定源路径 | `digests/<edition_date>/zh-Hans.md`、`en.md` |
| 修订序列 | 本期正整数 `sequence`；修订时递增，重试时保持 |
| 封面 | 客户端已有程序化构图，新分类独立配色 |
| 正文图片 | 原文章来源 HTML 实际引用的图片，保留出处与归属 |

历史 `ai-weekly` 归档继续保留。新来源不能写旧日报分类，已有来源也不能写新栏目。
复用现有日报表和持久队列，不新增或回写数据库 schema，不写周刊项目来源事件。

独立 Weekly 服务配置 `DAILY_RADAR_SOURCE_REPOSITORIES`；
聚合部署使用对应的 `WEEKLY_DAILY_RADAR_SOURCE_REPOSITORIES` 装配配置。
配置时保留既有允许项，追加 `starcat-app/ai-weekly-events`。

## 编辑与发布链路

入口为内容仓库的 `skills/starcat-weekly-events/SKILL.md`。
Skill 安装到宿主 Agent 的 Skill 位置后，使用指定内容仓库路径工作。
事实检索、双语写作、图片相关性和使用条件判断由宿主 Agent 与人工完成；
工具负责可重复的结构、图片、版本和服务回读校验。

1. `init --date` 初始化明确期次，运营粘贴事件清单，Agent 查证后写入 `edition.json`
2. `collect` 检查图片出现在对应文章 HTML 中，下载原图并留存哈希、尺寸和来源记录
3. `render` 由同一事件结构生成两篇 Markdown 和静态 HTML 图片预览
4. 图片上传获准后执行 `upload --apply`，通过本机 PicList 上传内容哈希文件名
5. 回读 CDN 比对原图字节，展示最终双语稿、图注、证据和问题清单
6. 人工审核通过后 `approve --reviewer NAME --apply`，批准绑定完整清单和双语正文
7. 将本期清单、批准记录、两篇 Markdown 一起提交到内容仓库
8. `payload --commit SHA` 从固定 Git 对象构建请求；`publish` 默认也仅输出请求
9. 服务发布获准后提供明确 `--api-base` 并执行 `publish --apply`
10. 轮询批次，回读两版正文、固定来源提交、修订与分类后报告整期成功

凭据只从 `WEEKLY_ADMIN_KEY`、`WEEKLY_API_KEY` 进程环境读取，
发送 `X-SC-Svc: weekly`，不提供默认生产地址。
远程目标限 HTTPS，本地开发可使用 loopback HTTP。带凭据请求禁止重定向。

原文图片抓取只接受公网 HTTPS，逐重定向检查地址，单次最多 12 MiB。
当前支持 PNG、JPEG、扩展头 WebP。静态 HTML 的 img/srcset、
常见懒加载和 OG 图片可留证；动态站点和其他格式明确报错。
HTML 引用证明图片出现在来源页面，不能证明图片相关性或使用权，人工审核仍是必需环节。

## 存储与失败恢复

| 位置 | 内容 | 是否提交 |
|---|---|---|
| `digests/<date>/edition.json` | 双语事件、事实证据、原图来源、资产记录和 CDN 引用 | 是 |
| `digests/<date>/{zh-Hans,en}.md` | 确定性编排稿 | 是 |
| `digests/<date>/approval.json` | 审核人、时间和完整内容摘要 | 是 |
| `.cache/` | 按内容哈希命名的原图 | 否 |
| `*.preview.html` | 本地预览 | 否 |
| `.state/` | 导入批次状态与失败进度 | 否 |

下载或上传中断时保留已成功资产；重试复用缓存，已上传图回读成功后不重复上传。
确认后正文、图片、事实证据或元数据改变都会使审核摘要失效。
手改生成的 Markdown 不能绕过审核；应修改清单、重新生成和审核。
上传后修改原图或文章来源要求重新采集，不能沿用旧来源证明。

服务仍逐语言处理，MVP **不保证双语原子可见**。
部分失败不会被报告为整期成功；网络中断可用同一固定提交重试幂等请求。
服务终态失败需诊断后提高本期序列，重新审核、提交并导入，不能假装重复请求会重排失败任务。
迟到旧序列不能覆盖新稿，已经固定的旧修订仍可读取。

## 客户端与本地化

复用每日热点现有侧栏、设置分类、阅读器、历史期次、图片展示与相关项目窗口。
新增分类回退项、业务图标和封面映射，不另建阅读架构。
目录中的 `weekly` 周期驱动请求，避免用默认 `daily` 查新栏目。

新增 `dailyRadar.category.ai-weekly-events`，覆盖当前运行时 17 种语言。
Catalog 仅插入新 key，没有全文件重排。中英文采用已确定名称，
其余 15 种翻译保持 `needs_review`，未宣称人工或界面审核完成。

## 验证与剩余验收

2026-11-05 本地结果：Direct / App Store 构建及产物校验通过；
客户端 14 项 Swift Testing 用例与 6 项封面 XCTest 用例通过；
后端 `go build ./...`、`go vet ./...`、`go test ./...` 通过，
新增每周 AI 大事 HTTP 导入用例单独补跑通过；
内容工具 11 项测试分别在 Python 3.9 与 3.12 通过，Skill 结构校验通过。
新 key 与 `AppLocale`、`locales.json` 语言集合一致，
两渠道编译产物中的 17 种译文均与 Catalog 匹配。未执行 GUI 自动化或生产写入。

后端以临时 SQLite、模拟 GitHub 和 HTTP 测试覆盖来源隔离、
双语同提交成对校验、导入与回读、幂等、修订固定以及迟到序列。
内容工具使用合成夹具验证来源图片检查、上传后字节比对、失败续办、
审核失效、固定 Git 提交以及双语发布回读。测试资料不能用于正式周报。

本地检查入口：

```bash
# 主仓
make build-direct
make build-appstore
make test TEST_ARGS="-only-testing:StarcatTests/DailyRadarClientTests -only-testing:StarcatTests/DailyRadarCoverCompositionTests"

# Weekly 独立仓库
go build ./...
go vet ./...
go test ./...

# 内容独立仓库
make check
```

本机测试宿主若被默认临时签名阻断，仍使用 `make test`，在 `TEST_ARGS`
中传入 `CODE_SIGN_IDENTITY="Apple Development"` 和当前开发团队；
不要修改产品签名配置或绕过 entitlements 来迁就测试。

仍需人工完成：选定真实一期事件、核对原文配图与使用条件、
审阅中英文稿、验收明暗主题和长文案布局。后续获准后再创建内容远端、
推送固定提交、配置发布允许清单并完成实际发布验收。
本说明不将测试通过等同于生产上线，也不修改主进度总览。
