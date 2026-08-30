# Star History 全链路最终测试报告

## 1. 测试结论

Star History 当前交付链路已在真实 WatchEvent 和 Fly 生产环境中跑通：BigQuery 日分区连续追加、本地 Silver 聚合、完整 Snapshot、每日 Delta、聚合服务发布、云端事务应用、进程重启恢复、Starcat `/events` 查询与本地校准均已验证。生产 active watermark 为 `2026-08-26`。

Discovery 的旧按请求 BigQuery History 实现已在生产关闭；其代码只按 62 号设计保留一个稳定发布窗口，窗口结束后再删除，不属于当前线上数据路径。

## 2. 测试环境与版本

| 项目 | 分支 / 版本 | 作用 |
|---|---|---|
| Starcat | `dev` / `ff171d4d` | History 客户端、Repository、本地校准与文档 |
| `starcat-history-api` | `dev` / `7a45234` | Builder、Publisher、Registry、查询 API |
| `starcat-recsys-trainer` | `dev` / `5b2ce10` | BigQuery WatchEvent 连续追加与 Raw checkpoint |
| `starcat-api` | `dev` / `6616cc4` | 七服务聚合部署与 `X-SC-Svc: history` 分流 |
| `starcat-discovery-api` | `dev` / `43d6f8b` | 迁移期旧路径；生产默认关闭 |
| 本地数据盘 | `/Volumes/T0/Starcat` | 唯一 Raw、History Silver/Delta/Snapshot |
| 生产 | Fly `starcat-api` / NRT | 聚合 API + 30GB 持久卷 |

所有提交均为本地提交；本次没有执行 Git push。

## 3. 整体数据流向

```text
GH Archive BigQuery 日表
  -> 按 UTC 日 dry run + 最大扫描预算
  -> /Volumes/T0/Starcat/.../raw/gh_archive/watch-events-YYYYMMDD.parquet
  -> 同一 Raw 文件被 History Builder 只读复用
  -> repo_id + UTC event_day 聚合
  -> History Silver Parquet
  -> 完整 Snapshot 或相邻日 Delta SQLite
  -> manifest + checksum + ZIP
  -> HTTPS POST 到 starcat-api，X-SC-Svc: history
  -> starcat-history-api Registry 校验并事务应用
  -> Fly Volume active runtime SQLite
  -> GET /api/v1/repos/{owner}/{repo}/star-history/events
  -> Starcat 使用本机公开 starsCount 做单一当前锚点校准
  -> Repository 合并本机精确快照
  -> 项目洞察 Star 历史曲线
```

Raw 不复制到 History 项目目录或云端；云端不保存 `actor_id`、actor login、原始 payload、私有仓库数据或本地绝对路径。

## 4. BigQuery 查询逻辑

### 4.1 查询范围

- 数据源：`githubarchive.day.YYYYMMDD` 日表。
- 当前连续范围：`2016-01-01` 至 `2026-08-26`。
- 分区数：`3,891`。
- 每个 UTC 日独立执行一次 dry run，再携带同一 `maximum_bytes_billed` 执行真实查询。
- 只读取 `WatchEvent`，要求 `actor.id` 与 `repo.id` 非空。

### 4.2 精确 SQL

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

`actor_id` 只属于本地 Raw/推荐训练输入；History Builder 聚合后不再保留或上传该字段。

### 4.3 本次真实追加

| 项目 | 结果 |
|---|---:|
| 追加日期 | `2026-08-26` |
| BigQuery 返回行数 | 1,675 |
| 估算扫描字节 | 109,874,787 |
| WatchEvent Raw 累计估算扫描字节 | 525,913,714,729 |
| Raw checkpoint 完成分区 | 3,891 |
| Raw 文件 | `watch-events-20260826.parquet` |
| Raw 文件大小 | 约 38KB |

追加使用原 `run_id`/checkpoint 和同一 Raw 目录，只允许重放已覆盖日期或追加紧邻下一日；不会重扫、重写或复制此前 3,890 个分区。

## 5. History 数据处理细节

### 5.1 日级聚合

Builder 使用 DuckDB 将原始时间戳转换为 UTC 日并聚合：

```sql
SELECT
  CAST(repo_id AS BIGINT) AS repo_id,
  CAST(
    date_diff(
      'day',
      DATE '1970-01-01',
      CAST(created_at AT TIME ZONE 'UTC' AS DATE)
    ) AS INTEGER
  ) AS event_day,
  CAST(COUNT(*) AS BIGINT) AS event_count
FROM read_parquet(?, union_by_name=true)
WHERE repo_id IS NOT NULL
  AND repo_id > 0
  AND created_at IS NOT NULL
GROUP BY repo_id, event_day
ORDER BY repo_id, event_day
```

`2026-08-26` 的 1,675 条 WatchEvent 聚合为 1,393 个 repo-day，涉及 1,393 个仓库；Silver 数据和 manifest 均保存在 `/Volumes/T0/Starcat/history/silver/daily/watch-silver-20260826-v1`。

### 5.2 Snapshot 与 Delta

- 完整 Snapshot：每个 repo 一行确定性 varint 压缩时间序列，不在云端保存 2.6 亿条 repo-day SQLite 行。
- 每日 Delta：只包含相邻水位日的 `repo_id + event_day + event_count`。
- 当前基线 Snapshot：`watch-history-20260825-v1`。
- 本次 Delta：`watch-delta-20260826-v1`，1,393 行，ZIP 约 23KB。
- Delta source checksum：`0d159129d9895e2d67c8f5e51eb8ab94dc6a79f05706ca6c936cc488aa01634d`。

服务端在一个 SQLite 事务中完成受影响序列更新、`applied_deltas` 幂等登记、统计增量和 active watermark 推进。相同 ID + checksum 重放返回 `already_applied`；同 ID 不同内容返回冲突；日期不相邻时拒绝应用。

## 6. 大文件校验与安装

完整 Snapshot 使用以下分工：

1. Builder 生成 SQLite 后执行一次完整 `PRAGMA quick_check`。
2. manifest v2 保存 `sqlite_quick_check=ok` 和 `database_bytes` attestation。
3. 云端校验 ZIP 白名单、路径、大小和 manifest 版本。
4. 解压过程中同步计算每个文件 SHA-256，不再落盘后二次扫描大文件。
5. 解压结束立即关闭并删除 ZIP，后续安装不额外占用一份压缩包空间。
6. 校验数据库大小、必需表、常量统计、active model 与 watermark。
7. 安装不可变版本，复制可写 runtime，再原子切换 active pointer。

Delta 体积小，服务端仍执行完整 `PRAGMA quick_check`。legacy Snapshot manifest v1 继续可安装和恢复，但新 Builder 一律生成 v2。

## 7. 生产验证结果

### 7.1 Active 数据

| 指标 | 生产结果 |
|---|---:|
| active model | `watch-history-20260825-v1` |
| active watermark | `2026-08-26` |
| repositories | 43,869,033 |
| event_days | 260,068,094 |
| watch_events | 510,106,622 |
| metadata_entries | 0 |
| runtime DB | 5,758,148,608 bytes |

### 7.2 查询样本

`vinta/awesome-python`（`repo_id=21289110`）：

| 项目 | 结果 |
|---|---:|
| HTTP | 200 |
| 覆盖范围 | `2016-01-01` 至 `2026-08-26` |
| 日事件点 | 3,855 |
| 累计 WatchEvent | 274,690 |
| `2026-08-26` 当日事件 | 3 |
| 部署后公网总耗时 | 0.774 秒 |
| 响应体 | 128,636 bytes |
| ETag 重验 | 304，0.686 秒（公网总耗时） |

公网耗时包含 TLS、Fly 路由和跨网传输，不能直接当作服务内 P95。统计接口只读取单行 `history_statistics`，不会再扫描全量时间序列或占用查询连接。

### 7.3 重启与持久化

- 手动重启 Fly Machine 后健康检查恢复为 1/1。
- 使用新 History 代码重新构建并滚动部署聚合镜像成功。
- 两次重启后 active model、水位和三项全量统计完全一致。
- Fly Volume：29.5GB，总使用 10.9GB，可用 17.4GB，使用率 38%；History Registry 约 10.7GB。

## 8. 自动化测试

| 项目 | 结果 |
|---|---|
| History Go test/vet | 通过 |
| History Builder pytest | 6 passed |
| Trainer `make check` | 122 passed，Ruff/mypy 通过，覆盖率 87% |
| 聚合 API test/vet | 通过 |
| Discovery `make check` | 通过 |
| Starcat History 定向测试 | 21 tests / 3 suites passed |

覆盖的关键场景包括：checksum 不匹配、v2 attestation 缺失、legacy v1、ZIP 提前释放、Delta 幂等/冲突/缺口、统计重启恢复、200/202/304、私有仓库本机阻断、Repository stale/ETag、本地校准和聚合分流头。

## 9. 迁移与遗留边界

- 当前生产客户端和聚合服务均已使用独立 History；Discovery History 默认关闭且无生产 GCP/BigQuery History Secrets。
- 旧 Discovery route、Provider、配置和缓存代码按既有设计保留一个稳定发布窗口，窗口结束后追加数据库 migration 并删除，不能提前破坏回退能力，也不能长期重新启用双轨。
- 月度 Snapshot 是同一 Builder/Registry 契约的例行数据运维，不需要每次复制或上传全部 Raw；每日只上传小型 Delta。
- `docs/功能实现总览.md` 因缺少 dong4j 单独授权保持只读，最终拟回填内容在交付回复中单独提供。

## 10. 最终结论

当前 Star History 需求的可交付主链路已完成并通过真实生产验证。除既定的“一个稳定发布窗口后删除 Discovery 迁移代码”时间门禁外，没有发现未修复的功能、数据、测试或生产问题。
