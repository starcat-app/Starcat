# WatchEvent 与 Star History 每日增量运维指南

## 1. 适用范围

本文是 WatchEvent 每日追赶、History 日增量构建、生产发布和定时运维的统一复现入口。它只处理已经存在生产 History Snapshot 的日常增量，不负责首次十年全量回填和首个 Snapshot 激活；首次建库请先按 `supports/starcat-history-api/README.md` 完成 Silver、Snapshot 和激活。

每日链路只追加最新完整 UTC 日的数据，不重新下载十年 WatchEvent，也不重新上传完整 History Snapshot：

```text
BigQuery GH Archive WatchEvent 日表
  -> Raw Parquet + download-state.json + manifest.json
  -> History Silver 日分区
  -> History Delta SQLite/ZIP
  -> HTTPS 发布到 starcat-api 的 History 模块
  -> 事务应用并推进 active_watermark
  -> Starcat /events 查询立即读取新水位，无需重启 API
```

生产 `active_watermark` 是发布事实；Raw checkpoint 是下载事实。两者可以短暂不同，但任务必须先连续补齐 Raw，再从生产水位逐日追赶，禁止跳日。

## 2. 前置条件

### 2.1 软件与认证

本机需要：

- `gcloud`，并完成 Application Default Credentials（ADC）认证；
- `uv`、Python 3.12、`jq`、`curl`；
- 已安装 `starcat-history-api` Builder 虚拟环境；
- `/Volumes/T0` 已挂载且有足够空间；
- 生产 History 已有 active Snapshot，且 Publish Key 可用。

检查命令：

```bash
command -v gcloud uv jq curl
gcloud auth application-default print-access-token >/dev/null
test -x supports/starcat-history-api/builder/.venv/bin/starcat-history-builder
test -d /Volumes/T0/Starcat/bigquery/watch-events-2016-2026/raw/gh_archive
test -w /Volumes/T0/Starcat
```

若 Builder 尚未安装：

```bash
(
  cd supports/starcat-history-api/builder
  uv sync --extra test --python 3.12
)
```

BigQuery billing project 默认由现有 Trainer 配置解析；换机器后如需覆盖，使用 `STARCAT_BQ_BILLING_PROJECT`，不要修改下载脚本中的数据集契约。

### 2.2 固定目录

本文按当前机器目录书写。换机器时只需要调整 `STARCAT_ROOT` 和数据卷路径，不要把 Raw 复制到 Trainer 或 History API 仓库：

```bash
export STARCAT_ROOT="/Users/dong4j/Developer/1.AI/ai-incubator/Starcat"
export TRAINER_ROOT="$STARCAT_ROOT/supports/starcat-recsys-trainer"
export HISTORY_ROOT="$STARCAT_ROOT/supports/starcat-history-api"
export WATCH_ROOT="/Volumes/T0/Starcat/bigquery/watch-events-2016-2026"
export HISTORY_DATA_ROOT="/Volumes/T0/Starcat/history"
```

## 3. 数据与产物目录

| 阶段 | 目录/文件 | 作用 |
|---|---|---|
| Raw | `$WATCH_ROOT/raw/gh_archive/watch-events-YYYYMMDD.parquet` | 单个完整 UTC 日 WatchEvent |
| Raw checkpoint | `$WATCH_ROOT/raw/gh_archive/download-state.json` | 已完成分区与断点续传事实 |
| Raw manifest | `$WATCH_ROOT/raw/gh_archive/manifest.json` | 每日行数、扫描字节和校验信息 |
| Silver | `$HISTORY_DATA_ROOT/silver/daily/watch-silver-YYYYMMDD-v1/` | `repo_id + event_day + event_count` 日聚合 |
| Delta | `$HISTORY_DATA_ROOT/deltas/watch-delta-YYYYMMDD-v1/` | SQLite、manifest、checksums 和 ZIP |
| 发布回执 | Delta 目录内 `publish-receipt.json` | 生产应用结果和目标水位 |
| Spill | `$HISTORY_DATA_ROOT/spill/` | DuckDB 临时文件，可重建 |

History API 不直接读取 T0。只有 Delta ZIP 会通过 HTTPS 上传；原始 WatchEvent、actor 和本地路径不会进入生产服务。

## 4. 首次配置

### 4.1 环境文件

```bash
mkdir -p ~/.config/starcat
cp supports/scripts/history-daily.env.example ~/.config/starcat/history-daily.env
chmod 600 ~/.config/starcat/history-daily.env
```

默认配置已经指向：

```text
HISTORY_BASE_URL=https://starcat-api.fly.dev
HISTORY_GATEWAY_SERVICE=history
```

环境文件只保存服务地址和非敏感参数，不写 Publish Key。

### 4.2 Publish Key 写入 Keychain

以下命令会安全提示输入密码，不把密钥写进 shell history：

```bash
security add-generic-password \
  -U \
  -a "$(id -un)" \
  -s com.starcat.history-publish-key \
  -w
```

只验证 Keychain 项存在，不打印密钥：

```bash
security find-generic-password \
  -a "$(id -un)" \
  -s com.starcat.history-publish-key \
  -w >/dev/null
```

## 5. 运行前检查

进入主仓库后执行：

```bash
cd "$STARCAT_ROOT"

TARGET_DATE="$(date -u -v-1d +%F)"
TARGET_COMPACT="${TARGET_DATE//-/}"

test -d /Volumes/T0
test -w "$WATCH_ROOT/raw/gh_archive"
gcloud auth application-default print-access-token >/dev/null
security find-generic-password \
  -a "$(id -un)" \
  -s com.starcat.history-publish-key \
  -w >/dev/null
```

不要只看 `download-state.json` 的 `.scope.end_date`。多日任务中断时，它可能是计划终点而不是最后完成日；必须同时检查已完成分区：

```bash
jq '{
  scope_end: .scope.end_date,
  completed_count: (.completed_partitions | length),
  last_completed: (.completed_partitions | keys | max)
}' "$WATCH_ROOT/raw/gh_archive/download-state.json"
```

检查生产水位：

```bash
set -a
source ~/.config/starcat/history-daily.env
set +a

HISTORY_PUBLISH_KEY="$(security find-generic-password \
  -a "$(id -un)" \
  -s "${STARCAT_HISTORY_KEYCHAIN_SERVICE:-com.starcat.history-publish-key}" \
  -w)"

curl -fsS \
  -H "Authorization: Bearer ${HISTORY_PUBLISH_KEY}" \
  -H "X-SC-Svc: ${HISTORY_GATEWAY_SERVICE}" \
  "${HISTORY_BASE_URL}/internal/v1/history-active" \
  | jq '{model_version, active_watermark}'

unset HISTORY_PUBLISH_KEY
```

如果生产还没有 active Snapshot，停止执行本指南，先按 History API README 完成首次 Snapshot；每日追赶不能为一个空服务自动建基线。

## 6. 推荐：一条命令补齐完整链路

补到指定完整 UTC 日：

```bash
cd "$STARCAT_ROOT"
supports/scripts/run-history-daily-sync.sh 2026-08-30
```

不传日期时自动补到 UTC 昨日：

```bash
cd "$STARCAT_ROOT"
supports/scripts/run-history-daily-sync.sh
```

统一脚本依次完成：

1. 加载 `~/.config/starcat/history-daily.env`，从 Keychain 读取 Publish Key；
2. 验证 T0 Raw 目录可写，并用目录锁阻止并发执行；
3. 调用 Trainer `download-watch-events.sh catch-up` 补齐 Raw；
4. 调用 History `run-daily-catch-up.sh`，从生产水位逐日构建 Silver/Delta 并发布；
5. 任一步失败立即停止，不跳日、不伪造成功水位。

成功日志最后应出现：

```text
INFO WatchEvent/History 每日增量完成，目标水位 YYYY-MM-DD。
```

## 7. 分层执行与问题定位

正常运维优先使用第 6 节统一脚本。只有定位故障时才分层执行。

### 7.1 只补 Raw WatchEvent

`catch-up` 是前台同步命令，适合每日编排；`start` 是长期后台下载入口，不用于统一每日链路：

```bash
(
  cd "$TRAINER_ROOT"
  STARCAT_WATCH_TARGET_DATE="$TARGET_DATE" \
    ./scripts/download-watch-events.sh catch-up
)
```

### 7.2 只构建并发布 History

这一步不会访问 BigQuery，要求目标范围内 Raw 文件已经完整存在：

```bash
set -a
source ~/.config/starcat/history-daily.env
set +a

export HISTORY_PUBLISH_KEY="$(security find-generic-password \
  -a "$(id -un)" \
  -s "${STARCAT_HISTORY_KEYCHAIN_SERVICE:-com.starcat.history-publish-key}" \
  -w)"

(
  cd "$HISTORY_ROOT"
  ./scripts/run-daily-catch-up.sh "$TARGET_DATE"
)

unset HISTORY_PUBLISH_KEY
```

History 追赶会先预检全部缺失日期的 Raw，再发布第一个新日期，避免处理中途才发现后续 Raw 缺口。

## 8. 分阶段验收

### 8.1 Raw

确认目标文件存在：

```bash
test -s "$WATCH_ROOT/raw/gh_archive/watch-events-${TARGET_COMPACT}.parquet"
```

确认 checkpoint 已登记目标日期：

```bash
jq --arg d "$TARGET_COMPACT" \
  '.completed_partitions[$d] // error("目标日期尚未完成")' \
  "$WATCH_ROOT/raw/gh_archive/download-state.json"
```

确认 manifest 有目标分区；字段名以当前 manifest 为准：

```bash
jq --arg d "$TARGET_COMPACT" \
  '.partitions[] | select(.partition == $d)' \
  "$WATCH_ROOT/raw/gh_archive/manifest.json"
```

### 8.2 Silver

```bash
SILVER_DIR="$HISTORY_DATA_ROOT/silver/daily/watch-silver-${TARGET_COMPACT}-v1"

test -s "$SILVER_DIR/manifest.json"
jq '{
  dataset_id,
  source_watermark,
  input_checksum,
  repositories,
  event_days,
  watch_events,
  minimum_event_day,
  maximum_event_day
}' "$SILVER_DIR/manifest.json"
```

`source_watermark` 应等于目标日期，`minimum_event_day` 与 `maximum_event_day` 应相等（manifest 使用内部日序整数）；`watch_events` 应等于 Raw 目标分区的事件行数。

### 8.3 Delta 与发布回执

```bash
DELTA_DIR="$HISTORY_DATA_ROOT/deltas/watch-delta-${TARGET_COMPACT}-v1"

test -s "$DELTA_DIR/history-delta.sqlite"
test -s "$DELTA_DIR/manifest.json"
test -s "$DELTA_DIR/checksums.json"
test -s "$DELTA_DIR/watch-delta-${TARGET_COMPACT}-v1.zip"
test -s "$DELTA_DIR/publish-receipt.json"

jq '{
  delta_id,
  from_watermark,
  to_watermark,
  source_checksum,
  rows
}' "$DELTA_DIR/manifest.json"

jq '{
  delta_id,
  target_watermark,
  response: {
    active_watermark: .response.active_watermark,
    applied: .response.applied,
    rows: .response.rows
  }
}' "$DELTA_DIR/publish-receipt.json"
```

`to_watermark` 和回执中的 `active_watermark` 都应等于目标日期。重复执行时服务端可以返回已应用/no-op，但水位必须保持一致。

### 8.4 生产 API

重新查询 `/internal/v1/history-active`，确认水位已经推进。Delta 在生产事务中应用并切换 active 状态；成功响应后，`/api/v1/repos/{owner}/{repo}/star-history/events` 立即读取新数据，不需要重启 `starcat-api` 或 Starcat。

任选一个目标日有 WatchEvent 的公开仓库，用 Starcat 已配置的客户端 Key 验证 `/events`；响应中的 `active_watermark` 应等于目标日期。不要用 Publish Key 调公共查询接口。

## 9. 安装每日 LaunchAgent

```bash
cd "$STARCAT_ROOT"
supports/scripts/install-history-daily-launch-agent.sh install
supports/scripts/install-history-daily-launch-agent.sh status
```

任务每天本地时间 10:00 执行，只处理 UTC 昨日。LaunchAgent 显式使用 `/bin/bash`，并由脚本补齐最小 PATH，不依赖交互式 shell。

安装后必须执行一次真实后台验收：

```bash
launchctl kickstart -k "gui/$(id -u)/com.starcat.history-daily-sync"
tail -f ~/Library/Logs/Starcat/history-daily-sync.log
```

完成后检查：

```bash
supports/scripts/install-history-daily-launch-agent.sh status \
  | rg 'state =|last exit code'
```

期望最近一次 `last exit code = 0`。日志默认位于：

```text
~/Library/Logs/Starcat/history-daily-sync.log
~/Library/Logs/Starcat/watch-events-daily.log
```

macOS 会单独限制后台进程访问可移动卷。若日志出现 `Operation not permitted`，在“系统设置 → 隐私与安全性 → 完全磁盘访问权限”中添加 `/bin/bash`，重新登录后再次 `kickstart`。Terminal 手工执行成功不能替代后台权限验收。

卸载：

```bash
supports/scripts/install-history-daily-launch-agent.sh uninstall
```

## 10. 幂等、失败与恢复

| 现象 | 行为与恢复 |
|---|---|
| `/Volumes/T0` 未挂载或不可写 | 写探针失败后立即退出，不访问 BigQuery；挂载/授权后重跑统一脚本 |
| ADC 失效 | Raw 下载失败，History 不运行；重新完成 ADC 认证后重跑 |
| BigQuery 额度达到停止阈值 | 不提交新查询、不推进任何 History 水位；等待额度恢复或人工调整计划 |
| Raw 日期缺失/损坏 | History 在发布任何新日期前停止；修复或重下缺失分区后重跑 |
| Silver/Delta 同 ID 但 checksum 不同 | 拒绝覆盖不可变产物；先人工确认来源变化，再使用新版本或清理错误的未发布产物 |
| Delta 发布失败 | 已成功日期保留，下一次从生产 `active_watermark` 继续 |
| 同时触发两次 | 第二次发现目录锁后安全跳过 |
| 任务重启 | Raw checkpoint 避免重查已完成日期，生产水位避免重复应用 Delta |
| API 已到目标水位 | 追赶返回 `published_days=0` 或已应用结果，属于正常幂等完成 |

不要通过手工修改 `download-state.json`、删除生产回执或跳过日期来“修复”水位。先确认 Raw、Silver、Delta、生产 active 四层事实，再从最早不一致的层级重跑。

## 11. 换机器复现

在另一台 macOS 上复现时：

1. 拉取 Starcat、`starcat-recsys-trainer`、`starcat-history-api` 对应 `dev` 代码；
2. 挂载包含同一 Raw/History 数据的卷，并按第 2.2 节调整路径；
3. 安装 `gcloud`、`uv`、Python 3.12、`jq`、`curl`，恢复 ADC；
4. 在 History Builder 执行 `uv sync --extra test --python 3.12`；
5. 新建 0600 环境文件，并把 Publish Key 写入该机器 Keychain；
6. 手工运行一次统一脚本并完成四阶段验收；
7. 安装 LaunchAgent，为 `/bin/bash` 授权 T0，执行真实 `kickstart`；
8. 只有 `last exit code = 0` 且生产水位正确，才算迁移完成。

LaunchAgent plist 会在安装时写入当前仓库脚本绝对路径，因此仓库移动后必须重新执行 `install`，不能继续使用旧 plist。

## 12. 日常检查清单

- [ ] T0 已挂载，Raw 目录可写。
- [ ] Raw `last_completed` 已到最新完整 UTC 日（键格式为 `YYYYMMDD`）。
- [ ] Silver `source_watermark` 与目标日一致。
- [ ] Delta manifest、checksum、ZIP 和发布回执完整。
- [ ] 生产 `active_watermark` 与目标日一致。
- [ ] LaunchAgent 最近退出码为 0，日志无权限/额度/checksum 错误。
- [ ] Starcat `/events` 查询能看到新 active watermark，无需重启服务。

## 13. 2026-08-31 首次补齐验证

本次从 `2026-08-26` 连续补齐到最新完整 UTC 日 `2026-08-30`：

| 日期 | Raw WatchEvent | History repo-day | 发布结果 |
|---|---:|---:|---|
| 2026-08-27 | 2,525 | 2,023 | 已应用 |
| 2026-08-28 | 2,305 | 1,846 | 已应用 |
| 2026-08-29 | 3,417 | 2,689 | 已应用 |
| 2026-08-30 | 3,176 | 2,496 | 已应用 |

- Raw checkpoint：3,895 个连续分区，最后完成日为 `2026-08-30`。
- 生产 History：`model_version=watch-history-20260825-v1`，`active_watermark=2026-08-30`。
- 幂等重跑：Raw 无待下载日期，History 返回 `published_days=0`。
- BigQuery 本月计费：720,630,710,272 字节，占 1 TiB 免费层约 65.54%，低于 80% 警告线。
- LaunchAgent：脚本、Keychain、最小 PATH 和 T0 后台写权限均通过真实 `kickstart` 验证，任务退出码为 0。
