# WatchEvent 与 Star History 每日增量运维指南

## 目标

每日链路只追加最新完整 UTC 日的数据，不重新下载十年 WatchEvent，也不重新上传完整 History
Snapshot：

```text
BigQuery WatchEvent 日表
  -> /Volumes/T0/Starcat/.../watch-events-YYYYMMDD.parquet
  -> History Silver 日分区
  -> History Delta ZIP
  -> starcat-api 中的 History 模块
  -> active_watermark 推进一天
```

生产 History 水位是发布事实；本地 checkpoint 是下载事实。两者可以短暂不同，但每次任务
必须先补 Raw，再从生产水位按相邻日期追赶，禁止跳日。

## 首次配置

```bash
mkdir -p ~/.config/starcat
cp supports/scripts/history-daily.env.example ~/.config/starcat/history-daily.env
chmod 600 ~/.config/starcat/history-daily.env
```

生产 `HISTORY_PUBLISH_KEY` 默认保存在 macOS Keychain 的
`com.starcat.history-publish-key` 项目中，不写入环境文件、Git 或 LaunchAgent plist。环境文件
只保存服务地址和非敏感运行参数，默认数据根目录为 `/Volumes/T0/Starcat`。

安装每天 10:00 执行的 LaunchAgent：

```bash
supports/scripts/install-history-daily-launch-agent.sh install
supports/scripts/install-history-daily-launch-agent.sh status
```

选择 10:00 是为了给 UTC 昨日 GH Archive 日表留出完成时间。任务不会处理 UTC 当天。
LaunchAgent 显式使用 `/bin/bash` 执行编排脚本，并由脚本补齐运行 PATH；这既不依赖登录
shell 配置，也能让 macOS 将 T0 后台访问正确归因到已经授权的 Bash。

## 手工补齐与验证

补齐到指定日期：

```bash
supports/scripts/run-history-daily-sync.sh 2026-08-30
```

不传日期时自动补到 UTC 昨日：

```bash
supports/scripts/run-history-daily-sync.sh
```

LaunchAgent 和 WatchEvent 每日任务日志默认写入用户日志目录，避免把标准输出绑定到尚未挂载的
T0：

```text
~/Library/Logs/Starcat/history-daily-sync.log
~/Library/Logs/Starcat/watch-events-daily.log
```

macOS 会单独限制后台进程访问可移动卷。安装后必须通过一次 `kickstart` 验证 LaunchAgent 能读取
和写入 `/Volumes/T0`；如果日志出现 `Operation not permitted`，需在“系统设置 → 隐私与安全性 →
完全磁盘访问权限”中授权实际执行脚本的 `/bin/bash`，随后重新登录并再次验证。手工在 Terminal
执行成功不能替代这项后台权限验收。编排器在访问 BigQuery 前会创建并立即删除一个 Raw 写权限
探针；探针失败时不会产生查询或推进任何水位。

检查 Raw 水位：

```bash
jq -r '.scope.end_date' \
  /Volumes/T0/Starcat/bigquery/watch-events-2016-2026/raw/gh_archive/download-state.json
```

检查生产水位时从 Keychain 读取 Publish Key，不要把密钥直接写入 shell history：

```bash
set -a
source ~/.config/starcat/history-daily.env
set +a
HISTORY_PUBLISH_KEY="$(security find-generic-password \
  -a "$(id -un)" -s "${STARCAT_HISTORY_KEYCHAIN_SERVICE}" -w)"
curl -fsS \
  -H "Authorization: Bearer ${HISTORY_PUBLISH_KEY}" \
  -H "X-SC-Svc: ${HISTORY_GATEWAY_SERVICE}" \
  "${HISTORY_BASE_URL}/internal/v1/history-active" | jq .
```

## 失败与恢复

- `/Volumes/T0` 未挂载：下载器立即退出，避免误写本机磁盘。
- BigQuery 额度读取失败或达到停止阈值：不提交新查询，History 水位不变。
- Raw 日期缺失：History 在发布任何新日期前失败，不跳过缺失日。
- Delta 发布失败：已成功日期保留，下一次从生产 `active_watermark` 继续。
- 同时触发两次：第二次发现互斥锁后直接跳过，不产生并发发布。
- 重复执行：Raw checkpoint 和生产水位共同保证幂等，不重新下载或重复应用已完成日期。

卸载定时任务：

```bash
supports/scripts/install-history-daily-launch-agent.sh uninstall
```

## 2026-08-31 首次补齐验证

本次从 `2026-08-26` 连续补齐到最新完整 UTC 日 `2026-08-30`：

| 日期 | Raw WatchEvent | History repo-day | 发布结果 |
|---|---:|---:|---|
| 2026-08-27 | 2,525 | 2,023 | 已应用 |
| 2026-08-28 | 2,305 | 1,846 | 已应用 |
| 2026-08-29 | 3,417 | 2,689 | 已应用 |
| 2026-08-30 | 3,176 | 2,496 | 已应用 |

- Raw checkpoint：3,895 个连续分区，`end_date=2026-08-30`。
- 生产 History：`model_version=watch-history-20260825-v1`，`active_watermark=2026-08-30`。
- 幂等重跑：Raw 返回无待下载日期，History 返回 `published_days=0`。
- BigQuery 本月计费：720,630,710,272 字节，占 1 TiB 免费层约 65.54%，低于 80% 警告线。
- LaunchAgent：脚本、Keychain、最小 PATH 和 T0 后台写权限均通过真实 `kickstart` 验证；
  任务幂等完成并以退出码 0 结束。
