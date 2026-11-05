# 每周 AI 大事：正式链路设计与验收

> 2026-11-06；正式链路实现与聚合部署已交付，待 dong4j 逐项人工验收。本文不代表人工验收通过

## 1. 范围与仓库

产品名固定为「每周 AI 大事」，分类 ID 保持 `ai-weekly-events`，周期 `weekly`。
本轮仅把 `dev@8be24cc8` 合入 `codex/weekly-ai-events-mvp`；未经 dong4j 验收不反向合回。

| 项目 | 职责 | 边界 |
|---|---|---|
| `starcat-app/starcat-ai-events` | 中文 Skill、原始线索、核查证据、原文图片归属、中英稿、审核、发布 CLI | Private；验收后另行授权 Public |
| `starcat-ai-events-api` | 持久化导入、整期双语发布、版本阅读、目录与缓存 | 独立 Go module、独立 SQLite |
| `starcat-api` | 鉴权后的业务分流、生产进程与卷 | 继续部署已有 Fly App；不建新 App |
| Starcat | 分类发现、筛选、阅读、关联项目与离线缓存 | 复用现有阅读组件；正式运行不依赖演示变量 |
| Weekly API | 原有日报与周刊 | 撤掉尚未上线的编辑周报写入分支；不重查日报发布适配器 |

代码沿用现有 MIT 约定；第三方文章、图片保留原有权利和出处，不纳入代码许可证。

## 2. 编辑与发布

1. 用户粘贴标题线索。Skill 保存原文及 SHA256，为每条线索记录真实检索词、来源、
   日期口径、确认/未证实/排除结论；AI 负责联网检索与写稿
2. `collect` 只采集来源页实际引用的图片，保存原图摘要与出处。正文不得使用生图
3. `render` 输出两版 Markdown、HTML 预览和核查记录；`check` 验证生成物一致性
4. 图片上传与审核是独立显式操作。审核绑定整个清单和两篇正文，编辑后自动失效
5. `payload` 从固定 Git SHA 读取审核和文稿，包含审核元数据，使用内容仓新身份
6. `publish` 使用独立管理 Key；持久化整期任务后返回批次。超时/断网重提相同
   idempotency key，内容不同则 409；新修订必须增加 sequence 并重新审核
7. worker 在事务外核验关联 GitHub 项目；发布事务同时保存两语不可变修订并切换指针
8. 发布端回读两语固定 revision、来源 SHA 与完整正文后才报告成功

审核只证明已授权编辑发布，不声称脚本自动完成事实核查。现有待审样稿不能自动成为生产内容。

## 3. 独立后端契约

网关头为 `X-SC-Svc: ai-events`，聚合环境前缀为 `AI_EVENTS_`。
正式数据库为 `/data/ai-events.db`；不读取 Weekly 数据库，不启动新闻采集 cron。

| 接口 | 用途 | 权限 |
|---|---|---|
| `GET /healthz` | 进程健康 | 无 |
| `GET /api/v1/ping` | 服务、构建版本 | 读取 Key |
| `GET /api/v1/daily-radar/catalog` | 此服务的目录版本、分类、计数 | 读取 Key |
| `GET /api/v1/daily-radar/dates` | 有报告的日期 | 读取 Key |
| `GET /api/v1/daily-radar/reports` | 摘要分页 | 读取 Key |
| `GET /api/v1/daily-radar/reports/{id}` | 固定修订双语阅读 | 读取 Key |
| `POST /internal/daily-radar/imports` | 持久化整期导入 | 独立管理 Key |
| `GET /internal/daily-radar/imports/{id}` | 可恢复发布状态 | 独立管理 Key |
| `GET /internal/stats` | 队列与缓存统计 | 独立管理 Key |

保留阅读 DTO，避免复制一套 UI；服务身份与数据库完全分离。
来源仓库只允许 `starcat-app/starcat-ai-events`，仅 `editorial` 来源和本分类。
每批恰好同一期 `zh-Hans/en` 两篇，固定同一提交与规范路径；拒绝空正文、
超大请求、重复语言、非法日期/图片地址和未知字段。读取 Key 与管理 Key 不得重用。

数据库使用 WAL、busy timeout、索引和事务。持久队列整期领取，进程重启恢复 running；
暂时失败最多三次退避重试，最终失败不改变线上指针。新 sequence 先发布时，
迟到的旧任务不能覆盖；同 sequence 不同内容冲突。历史 revision 永不覆写。

## 4. 缓存与性能

- 服务端使用有字节上限的响应缓存，缓存命中直接复用序列化 envelope 和 ETag
- 目录、日期和列表随发布版本失效；发布成功后下一次请求即可看到新版本
- 固定 revision 正文可长期私有缓存；动态目录短 TTL。响应 `Vary` 包含
  `Authorization` 与 `X-SC-Svc`，不让网关不同服务共用缓存
- 先检查目录/游标身份，再返回 304；旧游标遇新版本返回 `CATALOG_CHANGED`
- 列表限制 1–50 条，正文不混入列表。冷读扫描全部摘要后筛选；
  当前不是 SQL keyset 分页，不宣称任意数据规模下延迟恒定
- 关联项目仅在 worker 核验，读取路径不调用 GitHub。核验缓存有容量及过期约束
- 客户端继续使用有界磁盘缓存、请求合并、ETag 和完整首页原子快照
- 新服务的目录缓存用分类身份隔离；同一阅读窗口固定 revision，切换分类关闭旧详情
- 新栏目故障不阻断原有日报。缓存未命中显示真实空态/失败，不伪造报告

性能验收包含并发读、竞态检测、暖缓存延迟、冷列表与正文的分离、发布失效测试；
本机基准不等同生产网络延迟，交付时分别记录。

## 5. 聚合与部署

聚合通过 sibling `replace` 引用新后端 `server` 包，Docker 构建上下文保持 `supports/`。
增加 `AI_EVENTS_VERSION` 构建参数及数据库/读取/管理 Key 配置。生产部署使用固定
提交的干净构建上下文，其余七个依赖固定到已核对的 origin/main。旧镜像未保存各仓 SHA，
无法证明与旧镜像源码完全相同；本次开始保存完整依赖清单，避免夹带其他 worktree 脏文件。

只部署现有 `starcat-api`，不打新主线 tag、不合回 dev。部署前记录现有镜像和服务
端点，创建 Fly 平台整卷快照，不将卷快照描述为 SQLite 逻辑备份；本功能不覆盖旧数据库。失败可回退旧镜像，
新数据库保留。发布回退应使用更高 sequence 的已审核修订，不修改历史内容。

本轮授权部署服务不等同审核并发布现有新闻样稿。生产栏目在没有审核内容时允许为空，
但分类、鉴权和查询链路必须可用。

## 6. 功能完成清单

勾选表示代码及对应自动检查已交付，不表示 dong4j 已完成人工验收。
生产新闻尚未发布，所有人工验收保持待确认。

- [x] F01 最新 dev 合入当前功能分支，原 dev 保持不变
- [x] F02 内容仓改名、Private 远端及 Skill 链接一致
- [x] F03 独立 API、分库、双语事务发布与持久失败恢复
- [x] F04 读取/管理鉴权隔离、来源与审核约束
- [x] F05 ETag、缓存容量、失效、分页与固定修订
- [x] F06 内容 CLI 正式服务发布与双语回读
- [x] F07 Starcat 正式路由、分类发现、离线恢复
- [x] F08 聚合装配、固定依赖构建和生产部署
- [x] F09 按功能提交、分支推送与版本证据

## 7. 验证与人工验收清单

| 编号 | 场景 | 预期 | 自动证据 | 人工验收 |
|---|---|---|---|---|
| V01 | 普通启动 worktree 构建 | 无演示变量也展示新分类 | 21 项客户端测试、Direct/App Store 构建通过；未启动 GUI | 待 dong4j |
| V02 | 提供一段新闻标题 | 原文逐条可追溯，未证实内容不进正文 | 30 项离线用例含原文留档、12 线索历史回放、未证实隔离；未重新查新闻 | 待 dong4j |
| V03 | 原文图片 | 来源页引用、原图、归属与双语图注一致 | 原文引用、来源变更、原图字节回读用例通过；真实图片使用条件待人工 | 待 dong4j |
| V04 | 编辑审核后的任意内容 | 旧审核失效，不能发布 | 审核摘要变更与已提交未审核修改拒绝用例通过 | 待 dong4j |
| V05 | 同请求重试 / 同 key 改内容 | 前者同批次，后者 409 | Go 幂等用例与 Python→Go HTTP 重试/409 通过 | 待 dong4j |
| V06 | worker 失败 / 进程重启 | 可恢复，线上双语均保持旧版 | 事务回滚、网络失败、队列恢复及实际进程重启 HTTP 回归通过 | 待 dong4j |
| V07 | 修订 sequence 与迟到任务 | 新版不被覆盖；旧正文仍可读 | Go sequence 冲突与旧批次固定修订回读通过 | 待 dong4j |
| V08 | 新发布后旧游标 / 旧 ETag | 409 / 新内容，不能错误返回 304 | 旧 cursor 409、发布后 ETag 失效及 HTTP 304 通过 | 待 dong4j |
| V09 | 读取 Key 调用管理接口 | 401；缺少管理 Key 时保持关闭 | 装配鉴权、缺管理员配置关闭管理用例通过；生产检查见 §8 | 待 dong4j |
| V10 | 两语、历史筛选、分页、关联项目 | 日期真实、无重复、固定版本 | 日期/分页/两语/固定修订自动用例通过；真实项目内容待人工 | 待 dong4j |
| V11 | 打开后断网并重启 | 已缓存首屏与正文可读，提示缓存 | 离线重启/完整快照/正文缓存用例通过；GUI 待人工 | 待 dong4j |
| V12 | 分类切换与语言/服务切换 | 无旧详情、缓存和迟到响应串入 | 语言/分类切换与独立服务凭据、缓存隔离用例通过 | 待 dong4j |
| V13 | 并发读取与缓存容量 | 无竞态，容量受限，发布及时失效 | 新 API 与聚合 race 通过；500 期基准和缓存容量检查通过 | 待 dong4j |
| V14 | 生产聚合服务 | ai-events ping/目录成功，原业务健康 | release 39，8 服务 ping、两语目录/日期/列表、304/401 和 4 项原业务读取通过 | 待 dong4j |
| V15 | 内容远端与分支 | Private、固定提交可追溯、未合回 dev | 两 Private 仓已创建推送；dev 保持 8be24cc8，未反向合回 | 待 dong4j |

## 8. 交付证据

### 8.1 分功能提交

所有仓库均使用 `codex/weekly-ai-events-mvp`，没有合回任何 dev/main。

| 仓库/功能 | 提交 | 远端 |
|---|---|---|
| 主仓合入 dev | `09aa1e3a`，包含 `dev@8be24cc8` | 功能分支 |
| 客户端正式路由与缓存 | `a435f939` | 功能分支 |
| supports 拓扑与运维登记 | `1063bacf` | 功能分支 |
| 内容与 Skill 正式发布工具 | `12bf3159` | Private 内容仓功能分支 |
| 新独立 API | `ddf410b1` | Private 后端功能分支 |
| Weekly 撤除编辑周报 | `ed1402cb` | 功能分支 |
| 聚合装配及依赖锁 | `0c069881` | 功能分支 |

### 8.2 自动门禁

- 客户端 `DailyRadarClientTests`：21 项通过，含独立路由/凭据、缓存隔离、离线恢复和周期回退
- `make build-direct` / `make build-appstore`：最终修改后重跑均通过，未启动 App
- 两个新增设置 key 覆盖运行时 17 语，两渠道编译资源逐值相同；Catalog diff 为 212 新增/0 删除
- 内容 `make check`：30 项通过；跨仓 HTTP 用例默认跳过，另显式构建 Go 二进制后运行 `make integration` 通过
- 跨仓 HTTP：真实入队/worker、双语回读、幂等 409、ETag、二次修订、旧批次回读、进程重启通过
- 新后端：8 个顶层测试（含子场景）、`go test -race ./...`、vet、build、格式检查通过
- Weekly：迁出边界定向用例、build/vet 通过；未重查日报生产发布适配器
- 聚合：race/vet/build、固定 Git 导出回归通过；`govulncheck@v1.9.0` 返回 `No vulnerabilities found`
- Shell 入口 bash 语法检查、各仓 `git diff --check`、Skill 结构检查通过
- GitHub Actions：内容 `42080112022` 成功，新 API `42080110490` 成功
- 聚合 Actions `42080404113` 停于缺少 `AI_EVENTS_READ_TOKEN`，不是编译通过；配置限制见 §10

构建和测试日志位于本机 `/tmp/starcat-ai-events-final-{tests,direct,appstore}.log`；
聚合漏洞扫描为 `/tmp/starcat-ai-events-govulncheck.log`。日志不作为长期归档依赖，关键结果已记录于此。

### 8.3 性能证据

Apple M2 Ultra，本机 500 期/1,000 篇双语摘要，`make bench` 三次：

| 项目 | 三次结果 | 内存/分配 |
|---|---|---|
| 目录暖缓存 | 5.527 / 5.483 / 5.482 微秒每次 | 约 7.18 kB、27 allocs/op |
| 目录冷读 | 8.059 / 7.887 / 8.041 毫秒每次 | 约 3.52 MB、29,658 allocs/op |

这是本机 handler 耗时，不含 TLS/网关/跨区域网络，不是生产 SLA。
冷读包含全部摘要解码；正文不参与目录读取。响应缓存预算包含 key/body 与固定头部开销。

### 8.4 生产部署

2026-11-06 02:10–02:13（Asia/Shanghai）完成 release 39 滚动部署与只读业务核验。
现有单台 Machine 保持不变，没有新建独立 Fly App、备用 Machine 或新 volume。

| 线上验收 | 结果 |
|---|---|
| 聚合 healthz | 200，列出八个服务，Fly health check passing |
| 八服务鉴权 ping | 全部 200，版本逐一等于依赖锁短 SHA |
| ai-events 两语 catalog/dates/reports | 全部 200，周刊分类存在、当前 0 期，无测试稿 |
| 两语条件读取 | 同 ETag 返回 304 |
| 无读取凭据 | 401 |
| 读取 Key 调用 stats/POST imports | 401，管理 Key 读取 stats 返回 200 |
| 新服务缓存统计 | 预算 16,777,216 字节，6 条缓存，4,554 字节，已记录命中 |
| 导入队列 | complete/failed/pending/running 全部 0，本轮未发布新闻 |
| 原业务只读抽样 | discovery summary、trending languages、sharing stats、weekly repos 全部 200 |
| 线上构建清单 | 经 SSH 只读回读 `/app/build-manifest.json`，与固定源码上下文一致 |

本机跨网请求的八服务 ping 约 1.39–2.45 秒（包含网络/代理/TLS）；这不是服务端处理耗时，
不应与本机 5.5 微秒暖缓存基准混用。没有进行生产写入压测。

部署前平台卷快照 `vs_Dg5AAnkLQym1U3Pj5B4v7xy` 已为 `created`，
创建时间 `2026-11-06 02:01:42 +08:00`，增量快照大小 334,044,440 字节，保留 5 天；
digest `2d840a8b25ad6221ad83ccd5b0fc9a2b3ab174a3d83697e8be41626d23951c3c`。
这是 Fly 平台整卷快照，不是逐库逻辑备份；本轮没有执行恢复演练。

- 部署前镜像：`registry.fly.io/starcat-api:deployment-01M6FF1Q697V71E8YX6ABV3PPV`
- 原镜像 digest：`sha256:ccd7d56ca663e4e1f36e1fb95446706be01426811202c45b69a50b9ee260b756`
- 固定源码镜像：`registry.fly.io/starcat-api:ai-events-0c06988143b6-20261106`
- 新镜像 digest：`sha256:79ba48b4fb7da966d5938b3561ab441f835c60f0d4b29cebe4441669a6ed02b9`
- Machine `185de96f791908`，nrt / 1 CPU / 1 GiB；卷 `vol_458j3e5ky32ln1q4`，30 GiB
- 新库 `/data/ai-events.db`，未覆盖或迁移旧业务库；只新增本服务读取/管理/可选 GitHub 凭据
- 完整源码清单随镜像保存于 `/app/build-manifest.json`，源自聚合提交的 `dependencies.json`

回退旧镜像的受控命令（发生问题且获准时执行，不在本轮主动回退）：

```bash
fly deploy --app starcat-api --config supports/starcat-api/fly.toml \
  --image registry.fly.io/starcat-api:deployment-01M6FF1Q697V71E8YX6ABV3PPV \
  --ha=false --update-only --yes
```

构建日志 `/tmp/starcat-ai-events-production-build.log`，部署日志
`/tmp/starcat-ai-events-production-deploy.log`，脱敏核验结果
`/tmp/starcat-ai-events-production-verification.json`。

回退镜像保留新分库和新服务凭据，不删除卷、不覆盖 SQLite。回退后旧客户端读取仍可用，
新栏目暂不可用；恢复使用本轮固定镜像，不能临时用未提交工作区重建。

## 9. 人工验收顺序

### 9.1 运行与配置

在本 worktree 执行 `make run-direct` 或 `make run-appstore`。不需要演示环境变量，
旧 `STARCAT_DAILY_RADAR_DEMO_URL` 入口已经删除。进入「每日热点 → 每周 AI 大事」。
正式读取地址为现有聚合 URL，设置页有独立的服务地址、读取 Key 和连接测试。
默认读取 Key 已编入双渠道产物，管理 Key 不进入 App。

本次只部署服务，未替现有新闻样稿审核、上传图片或正式发布；首次生产栏目应为空。
不要把空栏目解释为分类未集成，也不要将合成测试稿发布到生产以填充空态。

### 9.2 生成和审核一期

1. 调用 `$starcat-weekly-events`，粘贴标题原文，检查原文台账逐条对应、真实检索词和时间口径
2. 逐项查看来源与原文配图；未证实消息应保留在核查记录，不能混入确认事件
3. 打开中英 HTML 预览，核对事实、翻译、日期、图注、归属、关联项目和来源
4. 另行授权原图上传后执行 `upload --apply`，确认 CDN 回读字节与原图一致
5. 审核人明确批准后执行 `approve --reviewer NAME --apply`，提交本期文稿、清单和批准文件
6. 推送固定提交，核对远端包含该对象，再生成 `payload --commit SHA`
7. 获得发布授权后，使用管理凭据向聚合执行 `publish --apply --api-base https://starcat-api.fly.dev`
8. CLI 返回整期成功后，在 App 刷新，逐项验收两语、历史修订、正文图片和相关项目

上述命令均在内容仓执行，使用 `python3 scripts/weekly_events.py COMMAND --date DATE`；
发布还须显式指定 `--commit SHA`。完整参数与授权边界以仓内 Skill 为准。

本机凭据保存在两仓忽略的 `.env`，权限 600。内容仓字段为
`AI_EVENTS_API_KEY` / `AI_EVENTS_ADMIN_KEY`，命令执行前在当前进程环境加载；
后端本地运行字段为 `API_KEYS` / `ADMIN_API_KEYS`。不要提交、截图或复制到文档。

### 9.3 离线、修订和恢复

- 在线打开一期和两种语言后断网、退出再启动，应读取该服务自己的完整首页及已打开正文缓存
- 没有打开过的正文不承诺离线可读；缓存按服务地址、凭据、语言和修订隔离
- 未审核编辑必须被拒绝；修订提高 sequence 后重新生成、批准和提交，配图变化须重新采集上传
- 网络中断重提相同 SHA 返回同一批次；终态失败保存脱敏原因，新修订使用新的 sequence
- Worker 有限重试失败时，当前两语都保持旧版；任务不能只切换一种语言
- 日报和新栏目互相切换，不应残留上一篇详情或影响另一服务的凭据

## 10. 已知边界与待配置项

- 人工事实核查、图片使用条件、17 语长文案布局、明暗主题和真实生产文稿发布尚待 dong4j 验收
- 内容和新后端远端保持 Private；GitHub 来源链接需要访问权限，未经另行授权不改 Public
- GitHub 禁止本仓 deploy key，API 返回 `Deploy keys are disabled for this repository`。
  聚合 Actions 需要 `AI_EVENTS_READ_TOKEN`，只授予 `starcat-ai-events-api` 的 Contents:read。
  当前未配置，不能宣称聚合 Hosted CI 通过；本地检查和固定源码部署独立完成
- 两语事务是一致性边界，不是跨服务事务；目录计数分别保留最近成功响应，新栏目计数进入后更新
- 默认 16 MiB 响应 LRU、512 条/24 小时项目核验缓存、100 个待执行批次、最多 3 次整期尝试。
  阅读请求不访问 GitHub，同条件 cold miss 合并，发布完成后目录版本立即失效
- 固定修订长期保留；正文每语最多 1 MiB，图片在 CDN，不写入 SQLite。
  容量随期数和修订增长；规模明显超过本次 500 期验收数据时应重新测量冷扫描和备份时长
- 本文是功能分支交付材料，人工验收未完成；没有修改主进度总览或 Changelog
