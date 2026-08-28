# 全量 WatchEvent 推荐训练扩容实施方案

> 日期：2026-08-29
>
> 状态：等待 PushEvent 2016—2026 数据下载完成，尚未开始实施
>
> 实施仓库：`supports/starcat-recsys-trainer`
>
> 数据位置：`/Volumes/T0/Starcat`
>
> 权威约束：[61-Starcat 自研仓库推荐系统详细设计](../../../3-设计/详细设计/61-Starcat自研仓库推荐系统详细设计.md)、[66-Starcat 本地数据湖与云端 Serving 同步详细设计](../../../3-设计/详细设计/66-Starcat本地数据湖与云端Serving同步详细设计.md)

## 1. 目标

当前自研推荐链路已经能够完成 WatchEvent 导入、离线训练、ServingBundle 发布和 Starcat Direct 查询，但 v12/v13 只覆盖 `4,619` 个候选仓库，并对训练主体执行了 `2%` 稳定采样，无法满足大范围仓库推荐覆盖。

本期目标是在不复制 BigQuery Raw、不把主体行为上传云端的前提下，基于本地完整 WatchEvent 和 PushEvent 构建可断点续跑的全量训练数据集，并在确认数据规模、资源消耗和质量后训练下一版模型。

目标口径：

- 对齐 `github-repo-embeddings` 的用户与仓库过滤口径，验证是否达到 `400 万+`有效训练主体。
- 将可训练、可服务仓库规模从 `4,619` 扩展到 `30 万+`量级；实际数量以过滤后的质量报告为准，不为满足数字静默降低质量门槛。
- 为进入训练集的仓库预计算 Top-K 推荐，显著提高 Starcat 已 Star 仓库的推荐覆盖率。
- 对协同行为不足的长尾仓库保留内容特征或热门候选降级，不承诺仅靠 WatchEvent 让所有仓库都产生可靠协同推荐。

本方案只记录下一阶段实施内容。PushEvent 下载完成并通过完整性检查前，不启动全量数据构建或训练。

## 2. 当前实测基线

### 2.1 WatchEvent 原始覆盖

2026-08-28 对本地 Canonical Parquet 执行精确只读聚合，结果如下：

| 指标 | 实测值 |
|---|---:|
| WatchEvent 行数 | `510,104,947` |
| 唯一 GitHub actor | `26,433,554` |
| 唯一 GitHub repo | `43,868,648` |
| 最早事件 | `2016-01-01` |
| 最晚事件 | `2026-08-25` |

Canonical 文件：

```text
/Volumes/T0/Starcat/training/gharchive-local-2016-2026-v10/
  runs/gharchive-local-2016-2026-v10/canonical/interactions.parquet
```

`26,433,554` 是原始唯一 actor 数，不等于有效训练主体数，其中包含仅 Star 少量仓库的用户、异常账号和可能的机器人。全量预处理必须另外计算有效主体数。

### 2.2 当前 v12 训练收缩

| 指标 | v12 值 |
|---|---:|
| 候选仓库 | `4,619` |
| 主体采样率 | `0.02` |
| 有效采样主体 | `60,127` |
| 训练有效主体 | `58,943` |
| 唯一主体—仓库关系 | `2,100,104` |

`60,127 / 0.02 ≈ 3,006,350` 只能作为当前 `4,619` 个候选仓库范围内的抽样估计，不能替代全量同口径统计。下一阶段必须取消 `maximum_repository_count=5000` 和生产数据集的 `subject_sample_rate=0.02`，但可以保留采样配置用于开发期 smoke test。

### 2.3 单用户核验

GitHub 用户 `dong4j` 的公开用户 ID 为 `20341123`。本地 WatchEvent 中查询到：

| 指标 | 实测值 |
|---|---:|
| WatchEvent | `1,673` |
| 唯一 Star 仓库 | `1,656` |
| 最早记录 | `2016-07-21` |
| 最晚记录 | `2026-08-22` |

该结果证明本地数据可以按公开 GitHub actor ID 还原用户—仓库关系。GH Archive Canonical 使用 `SHA256("gh_archive:" + actor_id)` 生成 source-local 主体标识；Starcat Contribution 仍使用独立 HMAC，两个来源禁止通过真实身份连接。

## 3. 开始实施的前置门禁

只有以下条件全部满足后，才能开始全量数据构建：

- PushEvent 2016—2026 预定日期分区全部下载完成。
- WatchEvent 与 PushEvent 的下载进程均已停止写入对应 Raw 目录。
- Catalog 中每个分区都有日期、行数、文件大小、checksum、SQL hash 和完成状态。
- 不存在 `.partial`、未关闭 writer 或 checksum 不一致的分区。
- PushEvent 的最大完成日期达到本轮训练输入 watermark。
- T0 剩余空间满足 Raw 不复制、Silver/临时 spill/模型产物并存的容量预算。
- 已明确本轮训练所用 Mac、DuckDB 内存上限、线程数和 T0 临时目录。

PushEvent 下载完成不自动触发训练。必须先生成完整性报告，由 dong4j 确认后再进入数据构建阶段。

## 4. 数据来源与职责

| 数据源 | 用途 | 不承担的职责 |
|---|---|---|
| WatchEvent Raw | 构建公开 user-repo 隐式反馈关系和 Star 时间 | 不提供完整 Unstar，不提供当前仓库 metadata |
| PushEvent Raw | 建立 `repo_id → current observed full_name`、首次/末次 Push 观察时间目录 | 不作为核心 Star 行为，不保证等于 GitHub 当前 `pushed_at` |
| GitHub API | 只为最终候选仓库补 Topics、语言、描述、License、状态等权威 metadata | 不逐个抓取数百万仓库的 Stargazer 列表 |
| Starcat Collection | 补充用户主动贡献的当前公开 Star 快照 | 不与 GH Archive 主体做身份关联 |

Raw 文件在本地只保留一份。Trainer 通过 Artifact URI 或配置路径只读访问，不把 WatchEvent 或 PushEvent 复制进训练版本目录；训练目录只保存 Silver、质量报告、模型和 ServingBundle。

## 5. 全量数据构建

### 5.1 阶段 A：仓库支持度

从 WatchEvent 生成按 repo 分桶的支持度数据集：

```text
repo_id
unique_watcher_count
watch_event_count
first_watch_at
last_watch_at
```

默认保留 `unique_watcher_count > 10` 的仓库。阈值必须写入 dataset manifest，不能写死在 SQL 或通过临时修改绕过质量报告。

### 5.2 阶段 B：用户—仓库去重关系

对同一 GH Archive 主体和仓库只保留首次 WatchEvent：

```text
source
source_subject_id
repo_id
first_starred_at
observed_at
source_weight
```

重复 Star 事件保留在 Raw，不重复进入协同训练关系。当前明确不处理 Unstar。

### 5.3 阶段 C：有效主体过滤

对进入候选仓库集合后的主体重新计算唯一仓库数：

- 最小值：`10`。
- 最大值：小于 `800`。
- 超出上限的主体进入隔离统计，不进入生产训练。
- 对保留主体计算 `1 / log2(2 + repo_count)` 权重，限制高活跃主体支配模型。

输出必须分别报告：原始主体数、少于下限、正常范围、超过上限、最终边数及分位数。

### 5.4 阶段 D：PushEvent 仓库目录

PushEvent 按 `repo_id` 聚合：

- 最新观察到的 `full_name`。
- 首次与末次 Push 观察时间。
- 名称变化记录或最终名称选择依据。

该目录用于批量解析仓库名称和基本活跃性。最终训练候选再按规模分层调用 GitHub API 补权威 metadata；404、451、DMCA、private、archived、disabled 等状态必须进入质量报告，不能导致整批失败。

### 5.5 阶段 E：版本化 Silver Dataset

生成不可变、可追溯的数据集版本：

```text
dataset/
  manifest.json
  quality-report.json
  repo-popularity/bucket=.../*.parquet
  user-repo-edges/bucket=.../*.parquet
  eligible-subjects/bucket=.../*.parquet
  repositories/bucket=.../*.parquet
```

Manifest 至少记录：

- WatchEvent/PushEvent watermark。
- 输入分区 checksum 集合或 manifest checksum。
- Trainer git commit、config hash 和 schema version。
- 每阶段输入/输出行数、过滤数量、耗时和峰值资源。
- DuckDB 版本、随机 seed、分桶数量和失败恢复点。

## 6. 单机资源与断点续跑

全量构建不能继续使用对 `5.1 亿`行一次完成多个 `COUNT(DISTINCT ...)` 的单 SQL。实测该方式在 `12GB` DuckDB 内存上限下会在 per-user 聚合阶段耗尽内存。

实施要求：

- DuckDB `temp_directory` 固定在 T0 训练 workspace，禁止回落到系统盘。
- 设置明确 `memory_limit`、线程数和磁盘下限保护。
- 先按 `repo_id` 或稳定主体哈希分桶，再分阶段物化 Parquet。
- 每阶段完成后写 manifest/checksum；进程重启只重做未完成桶。
- 设置 `preserve_insertion_order=false`，不依赖 DuckDB 非稳定内部顺序。
- 中间聚合优先顺序扫描和外部 spill，不在 Python 内存持有全量边。
- 训练工作目录与 Raw 目录分离；清理任务只能删除已登记的可再生临时目录。

第一轮建议在 64GB Mac 上执行，T0 作为 Raw、Silver、DuckDB spill 和产物盘。24GB Mac mini 可承担下载、Catalog、checksum 和小规模 smoke test，不作为首轮全量训练默认节点。

## 7. 先报告、后训练

Silver Dataset 完成后先停止并生成全量规模报告，至少包含：

- 有效主体数及 Star 仓库数 P50/P90/P99。
- 候选仓库数及独立 watcher 数分布。
- 去重前事件数、去重后 user-repo 边数。
- PushEvent 名称覆盖率、缺失率、重命名数量。
- GitHub API metadata 可获取率和不可用原因。
- `dong4j` 的 `1,656` 个历史 Star 仓库进入候选集的数量和比例。
- 预计 co-star 组合量、Metric Learning 训练规模、临时空间和耗时。

未审查报告前，不直接启动完整 co-star、SVD 或 Metric Learning 训练。

## 8. 训练扩容顺序

### 8.1 规模试跑

先使用全量主体、分层仓库子集做资源基准：

1. `10 万`候选仓库试跑。
2. 验证内存、spill、耗时、Top-K 产物大小和推荐覆盖率。
3. 根据基准决定 `30 万+`仓库全量训练参数，不能通过恢复 `2%` 主体采样掩盖扩展问题。

### 8.2 协同推荐

- co-star 只保留每个仓库 Top 500～1000 条边。
- 限制单主体参与的 pair 数，避免 `O(n²)` 组合爆炸。
- 使用用户权重、时间衰减、支持度收缩和最小共同主体门槛。
- 训练和发布阶段都不得生成完整 repo-repo 笛卡尔关系。

### 8.3 行为向量与基线

- 保留 TruncatedSVD 作为可复现 baseline。
- 按 61 号设计验证 128D Metric Learning 行为向量。
- 对比 co-star、SVD、Metric Learning 和融合结果，不能只根据少量热门仓库主观选模型。

### 8.4 长尾降级

对于行为支持度不足或完全没有共现边的仓库：

1. 优先使用内容向量召回。
2. 内容 metadata 不完整时使用语言/Topics/活跃度约束的热门候选。
3. API 明确返回 `fallback` 和 signal，不能把低置信降级结果伪装成高置信行为推荐。

## 9. 下一模型版本与验收

下一次全量扩容模型暂定为 v14，但版本号必须在实际 run manifest 创建时确认，避免与已有本地实验产物冲突。

验收至少包含：

| 类别 | 指标 |
|---|---|
| 数据规模 | 有效主体、候选仓库、边数达到质量报告确认的目标；未达 `400 万/30 万`时解释过滤漏斗 |
| 仓库覆盖 | 有推荐的候选仓库比例、长尾分桶覆盖率、空结果率 |
| 用户样本 | `dong4j` 的 `1,656` 个历史 Star 仓库中可查询推荐的数量和比例 |
| 推荐质量 | Recall@K、NDCG@K、HitRate@K、Coverage、Novelty、Diversity 和 Popularity Bias |
| 在线性能 | `/api/v2` P50/P95、分页查询、并发查询和 Bundle 切换延迟 |
| 产物治理 | manifest/checksum/SQLite quick check、原子激活和上一版本回滚 |
| 客户端 | model version 缓存失效、详情页非阻塞加载、分页和 fallback 标识 |

不能用“每个仓库都返回任意结果”代替推荐覆盖。协同证据不足时应走可解释降级，并单独统计真实行为推荐覆盖率。

## 10. 交付物

- 可断点续跑的全量 Silver Dataset 构建任务。
- WatchEvent/PushEvent 完整性与质量报告。
- 全量规模和资源评估报告。
- co-star、SVD、Metric Learning 及融合模型评估结果。
- 版本化 ServingBundle、model card 和发布记录。
- Starcat Direct 全链路验收报告，包含 `dong4j` 样本覆盖。

## 11. 当前等待清单

- [ ] PushEvent 2016—2026 下载完成。
- [ ] PushEvent 分区完整性、checksum 和 watermark 检查通过。
- [ ] 确认首轮全量构建机器和资源上限。
- [ ] 实施分桶 Silver Dataset 构建。
- [ ] 生成全量规模报告并等待确认。
- [ ] 执行规模试跑与算法评估。
- [ ] 训练、发布并验收下一模型版本。

当前只完成方案记录，不代表上述实施项已经完成。
