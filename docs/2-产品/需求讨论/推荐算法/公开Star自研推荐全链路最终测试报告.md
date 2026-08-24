# 公开 Star 自研推荐全链路最终测试报告

> 测试时间：2026-08-24（Asia/Shanghai）  
> 测试范围：Starcat Direct → Collection API → Trainer → ServingBundle → Recommend API v2 → Starcat Direct  
> 结论状态：通过。真实数据、自动化、进程恢复和 Starcat Direct UI 均已完成本机验收。

## 1. 测试目标

本次测试不使用 toy Star 行为数据，而是复用 Starcat 主账户数据库中的真实公开 Star，验证以下链路是否能连续工作：

1. 用户在 Starcat 设置页主动开启公开 Star 数据贡献。
2. Starcat Direct 完整同步成功后，静默生成匿名完整快照并上传到独立 Collection 服务。
3. Trainer 从 Collection 内部导出主动 Pull 行为数据，转换为 canonical/dataset，训练并生成 ServingBundle。
4. Trainer 使用独立 Publish Key 把 Bundle 发布并激活到 `starcat-recommend-api`。
5. Recommend API `/api/v2` 查询自研产物，`/api/v1` SimRepo 契约保持不变。
6. Starcat Direct 使用产品 `RecommendAPI(.trainedV2)` 解码真实 v2 响应。

## 2. 测试环境与版本

| 项目 | 分支 | 测试基线/关键提交 | 作用 |
|---|---|---|---|
| Starcat | `codex/collection-pipeline` | `1124e94` 及后续文档提交 | Direct 客户端、隐私开关、上报、v2 消费 |
| `starcat-collection-api` | `codex/collection-pipeline` | `afb8321` | 快照接收、匿名化、active 存储和训练导出 |
| `starcat-recsys-trainer` | `codex/collection-api-source` | `08131a0` | 数据处理、训练、Bundle 和发布 |
| `starcat-recommend-api` | `codex/trained-recommendations` | `5f5c98a` | v1 SimRepo、v2 自研查询和模型 Registry |

- 机器：Apple Silicon Mac Studio，macOS 26.6.1。
- Starcat：Direct Debug，bundle id `com.starcat.app.direct.debug`，复用主账户数据库。
- Collection：`http://127.0.0.1:5011`，隔离 SQLite。
- Recommend：`http://127.0.0.1:5005`，隔离模型 Registry。
- Trainer：Python 3.12、单机串行 `LocalExecutor`。
- 临时 E2E 根目录：`/tmp/starcat-recommend-e2e.YkSuWV`。

本次没有 push、部署、打包、上传生产模型或修改线上服务。

## 3. 整体数据流向

```text
Starcat 主账户 SQLite（1954 条已 Star repo）
  │
  │  用户主动开启 Toggle；force 完整同步成功边沿
  ▼
RecommendationSnapshot
  repo_id + starred_at
  随机 participant_id / snapshot_id
  canonical content_hash
  │
  │  三阶段幂等上传：create → 2 chunks → commit
  ▼
starcat-collection-api
  participant_id --HMAC-SHA256--> participant_key
  committed snapshot → active snapshot
  │
  │  Admin Key Pull；NDJSON + ETag + checksum
  ▼
starcat-recsys-trainer
  raw → canonical Parquet → quality filter → train/validation/test
  Popular + co-star；SVD 因单主体明确 skipped
  │
  ▼
ServingBundle
  manifest.json + checksums.json + recommendations.sqlite
  │
  │  独立 Publish Key；校验后原子激活
  ▼
starcat-recommend-api
  /api/v1 → SimRepo（不变）
  /api/v2 → active ServingBundle
  │
  ▼
Starcat Direct RecommendAPI(.trainedV2) → 现有推荐 UI/缓存
```

## 4. 各阶段数据处理细节

### 4.1 Starcat 采集与旁路上传

主账户数据库初始事实：

| 指标 | 数值 |
|---|---:|
| 已 Star 仓库 | 1954 |
| Private | 0 |
| inaccessible | 0 |
| archived | 87 |
| 最早 `starred_at` | `2016-07-21T07:23:33Z` |
| 最晚 `starred_at` | `2026-08-22T01:00:04Z` |

操作与结果：

- 设置页开关原始为关闭；人工点击后写入当前账户偏好，`is_enabled=1`。
- 普通工具栏同步走增量路径，没有生成贡献快照，证明“增量/304 不上报”。
- 通过“操作 → 刷新仓库列表/详情”触发 `force: true` 完整同步。
- 完整同步成功后在旁路 actor 中读取全部已 Star 仓库，生成排序、去重后的 snapshot。
- payload 只包含 `repo_id`、可空 `starred_at`、随机主体/快照 ID、schema、采集时间和 hash。
- 标签、笔记、README、AI/RAG、Token、GitHub 登录名、真实用户 ID 和本地路径均未进入 payload。
- 上传成功后 Starcat `data_contribution_outbox` 为 0；上传失败逻辑没有改变 Stars 同步完成态。

### 4.2 Collection 接收、匿名化与导出

| 指标 | 结果 |
|---|---:|
| committed uploads | 1 |
| active snapshots | 1 |
| 匿名主体 | 1 |
| snapshot items | 1954 |
| chunks | 2 |
| chunk item 数 | 1000 + 954 |
| 压缩 chunk payload | 112727 bytes |
| captured_at | `2026-08-23T18:49:14Z` |
| committed_at | `2026-08-23T18:49:15.512764Z` |

处理步骤：

1. 公共客户端 key 只能调用 create/chunk/commit，不能访问训练导出。
2. `participant_id` 只用于请求期归属验证，落库前通过 HMAC-SHA256 转为 `participant_key`。
3. commit 重新校验块数、总数、全局 repo 排序、重复项和 canonical `content_hash`。
4. 只有 committed snapshot 能成为 active；Trainer 只看到每个匿名主体最新 active snapshot。
5. Admin 导出返回 `application/x-ndjson`，本次 ETag/checksum 为：

```text
sha256:884c1be3636a196333bdc191d6402ed69716fbba466b4185dc530b1d5dbea429
```

导出聚合验证为 1 个匿名主体、1954 条互动，所有 `repo_id` 均为整数，时间范围与 Starcat 源数据一致。测试输出和报告没有记录主体值。

### 4.3 Metadata 输入

Collection 只负责行为快照，不保存完整仓库 metadata。本次 E2E 为避免对 GitHub 发起 1954 次 REST 请求，从同一个 Starcat 主库导出已缓存的公开 metadata，转换成 Trainer 的 `raw_repositories` JSONL：

- 1954 行，932562 bytes。
- 字段包括 repo ID、full name、description、topics、language、license、stars、forks、archived、visibility、pushed_at 和 fetched_at。
- 这是本机测试输入生成方式，不是生产耦合；正式训练仍可使用 `GitHubRepositoryMetadataSource` 按 canonical repo ID 延迟补齐。

### 4.4 Canonical、质量门禁与时间切分

| 指标 | 数值 |
|---|---:|
| input interactions | 1954 |
| latest snapshot rows | 1954 |
| deduplicated rows | 1954 |
| 过滤 archived 后 final rows | 1867 |
| training eligible subjects | 1 |
| train | 1509 |
| validation | 64 |
| test | 294 |
| missing occurred_at | 0 |

规则：

- metadata 必须为 public、非 archived、非 disabled；本次 87 个 archived repo 被过滤。
- 同一来源保留最新完整 snapshot，再做 source-local subject/repo 唯一化。
- `occurred_at < 2025-06-01T00:00:00Z` 为 train。
- `2025-06-01T00:00:00Z <= occurred_at < 2026-01-01T00:00:00Z` 为 validation。
- 其余为 test；缺时间的历史兼容行只进入 train，本次为 0。
- `training_eligible` 只由 train cutoff 前的 repo 数决定，validation/test 不能改变训练资格或主体权重。

### 4.5 训练逻辑

配置：

| 配置 | 值 |
|---|---:|
| selected model | `costar` |
| reference time | `2025-06-01T00:00:00Z` |
| top_k | 20 |
| half_life_days | 365 |
| shrinkage | 1 |
| maximum_repositories_per_subject | 100 |
| random seed | 42 |

单主体真实数据触发了冷启动边界：

- Popular 正常训练。
- SVD 至少需要 2 个主体和 2 个仓库；本次 `train:svd` 被明确记录为 `skipped`，原因写入 run manifest。
- co-star、no-decay、no-shrinkage 正常训练。
- 执行器只对 `InsufficientTrainingDataError` 降级；配置、I/O、算法或发布异常仍中止管道。
- co-star 为控制单个超大 Star 集合的 pair 数，只选择时间权重最高的 100 个 train repo 构造 pair。

最终 `recommendations.sqlite`：

| 指标 | 数值 |
|---|---:|
| metadata repositories | 1867 |
| recommendation edges | 2000 |
| source repositories | 100 |
| target repositories | 100 |
| rank 范围 | 1～20 |

离线 validation 指标为 Recall@20、NDCG@20、MRR@20、Coverage 全部 0。原因是当前只有一个贡献主体，无法形成跨用户协同泛化信号；这不影响工程链路验证，但明确说明该模型不具备生产质量结论。下一步 BigQuery bootstrap 的首要价值就是补充大量匿名 `actor_id → repo_id` 行为主体。

### 4.6 Bundle、发布和在线查询

- 本地模型版本：`real-star-e2e-20260824-v2`。
- Trainer Git commit：`08131a06a87a4a533834ea17b25c3df13a379ee0`。
- 发布压缩包：297337 bytes。
- Bundle checksum：

```text
sha256:c250c607115edee3364c6016296bd82dcb29190ff278abdfa2f1518845bc1131
```

Recommend API 服务端重新校验文件白名单、manifest、checksums、SQLite `quick_check`、必需表和 schema 后安装并激活。进程重启后仍恢复同一 active version。

以 `getsentry/sentry`（repo ID `873328`）查询，v2 返回：

- `source=starcat_trained`
- `fallback=false`
- `model_version=real-star-e2e-20260824-v2`
- Top 1：`yihong0618/xiaogpt`
- reasons：`基于公开 Star 共现关系`
- signals：`kind=time_decayed_costar`，并包含 cosine、support、half_life_days

单仓 GET 和多 seed POST 都通过；输入 repo 可通过 exclude 排除。v1 ping 在整个测试期间保持可用，没有修改 SimRepo Provider。

### 4.7 Starcat Direct 消费

- Direct target 构造 `RecommendAPI` 时使用 `.trainedV2`；App Store target 仍使用 `.simRepoV1`。
- URLProtocol 契约测试验证 `/api/v2/repos/{id}/recommendations`、`model_version`、signals/reasons 解码。
- 新增 live integration test，使用产品 `RecommendAPI(.trainedV2)` 访问本机 5005 服务；通过 `STARCAT_RECOMMEND_LIVE_REQUIRED=1` 强制确保没有因缺环境变量而跳过。
- live test 成功解码 active model `real-star-e2e-20260824-v2`，并验证 items 非空、来源均为 `starcat_trained`。
- UI 视觉验收使用本专项 worktree 的 Direct Debug 产物，完整路径为 `Starcat-collection-pipeline/build/DerivedData-NoSandbox/Build/Products/Debug/Starcat.app`。
- 在 Starcat 全局搜索打开 `getsentry/sentry`，点击“相似仓库”后，弹窗显示 10 个自研结果；首三项依次为 `yihong0618/xiaogpt`、`MuShibo/Micro-Wheeled_leg-Robot`、`xinnan-tech/xiaozhi-esp32-server`。
- 推荐卡片理由显示“基于公开 Star 共现关系”，与 v2 API 返回一致。验收时同时核对运行进程路径，排除了同 bundle id 的其他 Debug 构建。

## 5. 自动化测试结果

| 项目 | 命令/证据 | 结果 |
|---|---|---|
| Starcat 全量 | `xcodebuild ... test` + `.xcresult` | Passed；总计 2582，通过 2571，失败 0，跳过 10，预期失败 1 |
| Starcat v2 live | `RecommendAPILiveIntegrationTests` + REQUIRED 环境变量 | 1/1 通过 |
| Collection | `make check` | 普通测试、race、vet、build 全部通过 |
| Trainer | `make check` | Ruff format/lint、strict mypy、58 pytest 全部通过，覆盖率 88% |
| Recommend | `make check` + `go test -race ./...` | 12 项测试、race、vet、build 全部通过 |
| Bundle | `bundle verify` / `bundle query` | 通过 |
| 服务恢复 | Recommend 进程停止并用原 Registry 重启 | active model 与 v2 查询恢复 |

Starcat `.xcresult` 还记录了 4 条来自既有 `DiagnosticsTests.swift` 的“background threads publish” runtime warning；没有测试失败，也没有指向本专项新增文件，作为既有测试告警记录，不计为本链路失败。

## 6. BigQuery 当前查询逻辑

### 6.1 查询目的与返回数据

BigQuery Connector 查询 GH Archive 的 `WatchEvent`，把公开 GitHub Star 事件转换为训练行为输入。每一行只取：

| 输出列 | 来源 | 用途 |
|---|---|---|
| `source_record_id` | `event.id` 转 STRING | 来源内去重和追踪 |
| `actor_id` | `actor.id` 转 STRING | GH Archive 来源内的训练主体 |
| `repo_id` | `repo.id` 转 INT64 | 与 GitHub repository metadata 连接 |
| `created_at` | 事件时间 | 时间切分和衰减 |

只保留 `type='WatchEvent'` 且 actor/repo ID 非空的记录。`WatchEvent` 能表示 Star，不能提供完整 Unstar 事件历史，因此它适合推荐 bootstrap，不应被解释为精确 Star History。

### 6.2 当前示例配置的时间范围

`configs/example-bigquery.yaml` 当前配置：

```yaml
start_date: "2026-08-01"
end_date: "2026-08-07"
maximum_bytes_billed_per_day: 10737418240
location: US
```

语义是 UTC 闭区间，共 7 个显式日表：`20260801`～`20260807`。Connector 不拼一个日期通配查询，而是逐日执行：

1. 校验日期并生成一个 `YYYYMMDD` 表后缀。
2. 对该日 SQL 执行 dry run。
3. 如果 estimated bytes 超过 10 GiB，则在正式查询前失败。
4. 正式查询继续携带相同的 `maximum_bytes_billed`，防止 dry run 后配置漂移或误扫。
5. 结果转 Arrow，再以 zstd Parquet 写入 raw 分区。

### 6.3 当前 SQL 模板

```sql
SELECT
  CAST(id AS STRING) AS source_record_id,
  CAST(actor.id AS STRING) AS actor_id,
  CAST(repo.id AS INT64) AS repo_id,
  created_at
FROM `githubarchive.day.{table_suffix}`
WHERE type = 'WatchEvent'
  AND actor.id IS NOT NULL
  AND repo.id IS NOT NULL
```

例如查询 `2024-01-01` 时，实际 SQL 为：

```sql
SELECT
  CAST(id AS STRING) AS source_record_id,
  CAST(actor.id AS STRING) AS actor_id,
  CAST(repo.id AS INT64) AS repo_id,
  created_at
FROM `githubarchive.day.20240101`
WHERE type = 'WatchEvent'
  AND actor.id IS NOT NULL
  AND repo.id IS NOT NULL
```

不能改成 `githubarchive.day.*`：该 dataset 同时含有 `yesterday` View，通配前缀会触发 `Views cannot be queried through prefix`。

### 6.4 已实际验证的 BigQuery 数据

此前生产链路验证与当前 SQL 完全一致，但只验证单日 `2024-01-01`，不是上面示例的未来 7 日范围：

| 指标 | 结果 |
|---|---:|
| 表 | `githubarchive.day.20240101` |
| dry run 扫描量 | 191450481 bytes |
| 正式查询硬上限 | 200000000 bytes |
| 返回行数 | 131766 |
| 转换 | BigQuery result → Arrow 成功 |
| 结算状态 | 验证项目当时未绑定结算账号 |

2026-08-24 本次复核发现：GCP CLI 有 1 个 active account，但默认 project 为 unset；直接执行 `bq query` 会报：

```text
Cannot start a job without a project id.
```

这不影响 Trainer 代码，因为 `BigQueryConfig.billing_project` 是必填项并显式传给 SDK。下一次正式采集前必须把目标 GCP project 写入 YAML 的 `billing_project`，或为 `bq` CLI 显式传 `--project_id`，不能依赖当前默认配置。

Google Cloud 当前按需查询免费层是每月前 1 TiB 查询数据免费；仍必须保留逐日 dry run 和 `maximum_bytes_billed`，因为免费额度是账户级月度额度，不是单次查询无限免费：

- <https://cloud.google.com/bigquery/pricing>
- <https://docs.cloud.google.com/bigquery/docs/best-practices-costs>

### 6.5 下一步用 BigQuery 训练的建议执行顺序

1. 选择并显式填写 `billing_project`，确认 BigQuery API 和结算/沙箱状态。
2. 先对目标日期逐日 dry run，汇总预计字节，不直接跑整月。
3. 从 1～7 天开始采集，检查 actor 数、repo 数、每主体 repo 分布和 metadata 命中率。
4. 根据 canonical repo 热度只为有上限的 repo ID 调用 GitHub metadata API。
5. 完成时间切分、三模型/降级状态和离线指标后，再决定是否扩大到整月。

## 7. 数据与隐私核对

- 用户开关默认关闭，本次由人工明确开启。
- 上传是完整同步成功后的旁路任务，失败不影响 Starcat 主功能。
- Collection 不保存原始 `participant_id`，Trainer 不接触 GitHub 登录身份。
- Canonical/dataset 只保留 source-local 匿名主体。
- ServingBundle 和 Recommend API 响应不包含主体、Star 列表、快照 ID或原始行为表。
- 本次报告只保存聚合数量、时间范围、模型版本和文件 checksum，没有保存匿名主体值或密钥。

## 8. 限制与结论边界

1. 当前只有一个真实贡献主体，工程链路已打通，但离线指标为 0，不能据此切换生产默认推荐。
2. 为限制单主体 pair 爆炸，co-star 本次只覆盖 100 个 source repo；BigQuery bootstrap 后应重新评估上限和模型质量。
3. 当前第一版是 Popular/SVD/co-star 离线基线，不等于 61 号设计中的 Metric Learning、内容 embedding、动态融合和 MMR 完整生产系统。
4. 本机服务使用隔离数据库、临时 key 和临时 Registry；没有验证生产 TLS、正式密钥、部署 SLO、shadow 或灰度回滚。
5. 当前结论只覆盖本机 Direct Debug 和隔离服务；生产部署与灰度仍按上面的边界单独验收。

## 9. 证据位置

- Collection SQLite：`/tmp/starcat-recommend-e2e.YkSuWV/collection.sqlite`
- Trainer run manifest：`/tmp/starcat-recommend-e2e.YkSuWV/trainer-workspace/runs/real-star-e2e-20260824-v2/run-manifest.json`
- 质量报告：`/tmp/starcat-recommend-e2e.YkSuWV/trainer-workspace/runs/real-star-e2e-20260824-v2/dataset/quality-report.json`
- 离线指标：`/tmp/starcat-recommend-e2e.YkSuWV/trainer-workspace/runs/real-star-e2e-20260824-v2/evaluation/validation-metrics.json`
- 本地 Bundle：`/tmp/starcat-recommend-e2e.YkSuWV/trainer-registry/versions/real-star-e2e-20260824-v2`
- Recommend Registry：`/tmp/starcat-recommend-e2e.YkSuWV/model-registry`
- Starcat 全量 `.xcresult`：`/tmp/starcat-recommend-e2e.YkSuWV/starcat-test-derived/Logs/Test/Test-Starcat-2026.08.24_03-13-26-+0800.xcresult`

这些是本机测试证据，不是长期生产存储；`/tmp` 可能被系统清理。
