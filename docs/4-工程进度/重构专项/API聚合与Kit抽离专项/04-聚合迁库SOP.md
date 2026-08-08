# 聚合迁库 SOP：独立 App `/data` → `starcat-api`

> 日期: 2026-08-08  
> 状态: **首轮五库种子迁移与功能验证已完成；聚合已停机保留，待 1.4.0 最终同步 / 写入冻结与生产切流**
> 相关: `supports/scripts/fly-backup-data.sh`、`prepare-starcat-api-restore.sh`、`fly-restore-data.sh`

## 1. 迁移对象与硬约束

| 来源 App | 聚合卷目标 |
|---|---|
| `starcat-sharing-api` | `/data/sharing.db` |
| `starcat-trending-api` | `/data/trending.db` |
| `starcat-weekly-api` | `/data/weekly.db` + `/data/weekly-repo/` |
| `starcat-wiki-api` | `/data/wiki.db` |
| `starcat-discovery-api` | `/data/discovery.db` |
| `starcat-recommend-api` | 无 SQLite，不迁移 |

- 五个 schema 保持分库，禁止合成单个 SQLite。
- 禁止在业务服务已打开数据库时覆盖 `.db`。
- 禁止把五份来源归档依次恢复到聚合卷；恢复脚本每次都会清空 `/data`，必须先离线合成一包。
- 旧 App 和 Volume 至少保留到 Starcat 正式版发布并稳定观察后。

## 2. 旧 App 一致性备份

在主仓根目录执行：

```bash
make -C supports fly-backup-sharing
make -C supports fly-backup-trending
make -C supports fly-backup-weekly
make -C supports fly-backup-wiki
make -C supports fly-backup-discovery
```

每份产物位于 `supports/backups/<app>/<timestamp>/data.tar.gz`。备份脚本通过 `VACUUM INTO` 生成一致主库并排除在线 `-wal` / `-shm`；weekly 的 `weekly-repo/` 仍是文件级在线快照。

## 3. 离线合并与校验

明确选择同一迁移批次的五份归档：

```bash
make -C supports fly-prepare-api-restore \
  SHARING_BACKUP=backups/starcat-sharing-api/<ts>/data.tar.gz \
  TRENDING_BACKUP=backups/starcat-trending-api/<ts>/data.tar.gz \
  WEEKLY_BACKUP=backups/starcat-weekly-api/<ts>/data.tar.gz \
  WIKI_BACKUP=backups/starcat-wiki-api/<ts>/data.tar.gz \
  DISCOVERY_BACKUP=backups/starcat-discovery-api/<ts>/data.tar.gz
```

默认输出 `supports/backups/starcat-api/<timestamp>/data.tar.gz` 和 `MANIFEST.txt`。脚本会：

1. 拒绝不安全归档路径和链接；
2. 校验五个预期数据库与 `weekly-repo/`；
3. 对每个主库执行 `PRAGMA integrity_check`；
4. 排除所有 `-wal` / `-shm`；
5. 生成唯一的聚合恢复包。

任一步失败都不得进入远端恢复。

## 4. 部署与进入维护模式

2026-08-08 已在 `personal` organization 完成 App、同区 Volume、Secrets 与维护模式首次部署。以下命令仅作为首次部署记录，**不得重复创建 App 或 Volume**：

```bash
# 已完成的首次创建记录
fly apps create starcat-api --org personal
fly volumes create starcat_api_data -a starcat-api --region nrt --size 1 --yes

# 先把首次部署锁在维护模式，避免空库启动 scheduler 或提前承接业务
make -C supports fly-secrets-api
make -C supports fly-maintenance-api-on
make -C supports fly-deploy-api
make -C supports fly-health-api
```

当前 Volume 为 `vol_458j3e5ky32ln1q4`，名称 `starcat_api_data`，Region `nrt`，已挂载到 Machine `185de96f791908`。迁库操作前只需重新核对当前维护态与 Volume，不得重跑创建命令：

```bash
fly status -a starcat-api
fly volumes list -a starcat-api
make -C supports fly-health-api
```

2026-08-08 功能验证结束后，聚合已重新进入维护模式并停止，Machine 的请求自动启动也已关闭。1.4.0 最终迁移窗口开始时，先恢复自动启动配置并显式启动；`STARCAT_MAINTENANCE_MODE=true` 已保留，启动后必须仍只返回 maintenance：

```bash
fly machine update 185de96f791908 -a starcat-api --autostart=true --skip-start -y
fly machine start 185de96f791908 -a starcat-api
make -C supports fly-health-api
```

不得直接执行 `fly machine start` 后解除维护；必须先完成最终归档恢复与完整性核验。

`starcat_api_data` 必须与 `fly.toml` 的 `[[mounts]].source` 完全一致，Region 必须与 `primary_region = 'nrt'` 一致。

维护模式不会装配六个业务服务、不会打开任何业务 SQLite；首次 deploy 后 `GET /healthz` 必须返回：

```json
{"status":"maintenance"}
```

其它请求统一返回 503。只有确认该状态后，恢复脚本才允许清空聚合 `/data`。

首次部署曾验证公网与 Machine 内 `/healthz` 均返回 `{"status":"maintenance"}`，根路径和带服务头的 `/api/v1/ping` 均返回 503；当时 `/data` 仅有 Volume 初始化产生的 `lost+found`。该记录是迁库前证据，不能替代后续现场核验。

## 5. 一次性恢复聚合卷

```bash
make -C supports fly-restore-api \
  RESTORE_ARCHIVE=backups/starcat-api/<ts>/data.tar.gz
```

脚本会先在本地重复检查归档结构和五库完整性，再核对远端维护状态，要求输入 `starcat-api` 二次确认，随后只清空一次 `/data` 并整包恢复。完成后仍保持维护模式，便于人工检查远端文件。

确认 `/data` 中只有五库和 `weekly-repo/` 后恢复业务：

```bash
make -C supports fly-maintenance-api-off
```

### 5.1 2026-08-08 首轮种子迁移记录

- 五个来源均先创建 Fly Volume Snapshot，再用 `VACUUM INTO` 生成一致 SQLite 归档；有效备份批次分别为 Sharing `20260808-203127`、Trending `20260808-203941`、Weekly `20260808-204220`、Wiki `20260808-205141`、Discovery `20260808-205957`。
- 唯一合并归档：`supports/backups/starcat-api/20260808-210340/data.tar.gz`；`MANIFEST.txt` 记录五个来源路径、`sqlite_integrity_check=ok`、五库与 `weekly-repo/` 清单及 WAL / SHM 排除规则。
- 恢复完成后将 `/data` 所有权统一修正为镜像运行用户 `app:app`（UID/GID `100:101`），避免 macOS 离线重打包的 UID/GID 导致 SQLite 无法创建 WAL；恢复脚本已固化该步骤。
- 五库本地/远端 SHA-256 逐一一致，`weekly-repo` 本地与远端均为 545 个文件，远端无 WAL / SHM；迁后 Snapshot `vs_P2NQQAXpbv9jUyVVmvy5qe5v` 状态 `created`，约 95 MiB。
- 迁移后仍保持维护模式：`/healthz` 返回 maintenance，根路径与业务 ping 返回 503；六个旧 App health check 全部通过并继续承载生产。
- 旧 Wiki `wiki.db` 在本轮备份后继续写入（核验 mtime `2026-08-08 13:14:05 UTC`），因此本轮归档是验证备份、合并、恢复与回滚证据的**种子批次**，不是可直接切流的最终快照。

**首轮种子迁移后已执行**：`fly-maintenance-api-off`、六服务鉴权 ping、六服务只读业务抽样；旧 App 保持运行，未切换 `starcat.ink`。

**尚未执行**：切流前最终同步 / 写入冻结、最终生产复验、`starcat.ink` 切换、旧 App 停机或销毁。

最终切流批次必须在明确的写入冻结窗口内重新生成来源备份与唯一合并归档，恢复后立即核对哈希并进入业务验收；只要旧 App 仍接收写请求或运行会写库的 scheduler，就不能把已有种子归档当作最终数据源。

### 5.2 解除维护后的本地 / 受控验证记录

- Machine version 2，health check 返回六服务列表与 `status=ok`；六服务鉴权 `/api/v1/ping` 全部 HTTP 200。
- 只读业务抽样全部 HTTP 200：Trending repos、Weekly repos、Wiki probe、Recommend recommendations、Discovery summary、Sharing stats、Sharing 公开仓库页。
- `wiki.db` 在聚合 scheduler 启动后更新，证明 `/data` 的 `app:app` 写权限有效；日志未发现 permission denied、SQLite、panic 或启动失败。
- CodeWiki probe 的 `status=error` 在旧 Wiki App 上对同一仓库同样存在，DeepWiki 正常，判定为既有单一上游状态而非聚合回归。
- 六个旧 App health check 全部通过且未停用。验证期间新旧服务都会独立写各自数据库；验证结束后聚合已停机，最终切流前仍必须覆盖式执行最终同步。

### 5.3 验证后停机记录

- 2026-08-08 已重新设置 `STARCAT_MAINTENANCE_MODE=true`，公网 `/healthz` 返回 `{"status":"maintenance"}` 后再停机。
- Machine `185de96f791908` 当前为 `stopped`，服务配置为 `autostart=false`；外部请求不会重新拉起实例。
- Volume `vol_458j3e5ky32ln1q4` 仍挂载，迁后 Snapshot `vs_P2NQQAXpbv9jUyVVmvy5qe5v` 状态为 `created`；App、Secrets 和镜像均保留。该 Snapshot 的 Fly 保留期为 5 天，只用于本轮验证证据，1.4.0 最终切流必须重新备份并创建新 Snapshot。
- 六个旧 App 均保持 `started` 且 health check 通过，当前生产流量不受本次停机影响。

## 6. 聚合服务验收

```bash
curl -fsS https://starcat-api.fly.dev/healthz

for service in trending weekly sharing wiki recommend discovery; do
  curl -fsS \
    -H "X-SC-Svc: ${service}" \
    -H "Authorization: Bearer <shared-key>" \
    https://starcat-api.fly.dev/api/v1/ping
done
```

还必须抽样验证真实业务：trending repos、weekly bulk、wiki probe、sharing 创建分享、recommend 查询和 discovery feed。只有 `/healthz` 成功不代表分库、密钥和上游依赖都正确。

## 7. Sharing 公网路由下线门禁

`starcat.ink` 的浏览器公开请求不能自行携带 `X-SC-Svc`。在停止旧 `starcat-sharing-api` 前，反向代理必须把 upstream 切到 `starcat-api.fly.dev` 并注入：

```nginx
proxy_set_header X-SC-Svc sharing;
```

用生产真实数据逐项验收：

- `/s/<existing-share-id>`：历史分享页可读；
- `/r/<owner>/<repo>`：公开仓库预览 HTML；
- `/og/repo/<owner>/<repo>.png`：Open Graph 图片；
- `/r/starcat-logo.png` 与 `/r/fonts/<file>`：静态资源。

任何一项未通过，都不得停止旧 Sharing Machine。代理配置不在本仓库内，本项只能由人工确认，不能用代码测试冒充完成。

## 8. Starcat 1.4.0 发布门禁与旧 App 退役

客户端保持 `https://starcat-api.fly.dev` + `X-SC-Svc`，本专项不增加临时双轨。1.4.0 必须按以下顺序切流：

1. App Store 1.4.0 已审核通过并具备发布条件，Direct 1.4.0 产物和 appcast 已准备完成，但尚未提前关闭旧服务；
2. 冻结五个有状态旧 App 的写请求与所有会写库的 scheduler，生成同一窗口内的最终备份；
3. 以维护模式启动 `starcat-api`，离线合并并一次性恢复最终归档，完成哈希、文件数和 SQLite 完整性核验；
4. 解除维护模式，完成六服务真实业务与 Sharing 公网页验收，并把 `starcat.ink` upstream 切到聚合入口；
5. 确认 Direct 与 App Store 1.4.0 均已公开可下载，已有客户端更新检查能够发现 1.4.0；
6. 六个旧 App Machine 直接停机。先保留 App、Volume 和 Snapshot 作为回滚资产，稳定观察期结束并再次确认后才销毁。

本地缓存只能保证老版本继续展示已经缓存的数据，不代表在线能力兼容。旧服务停机后，老版本的在线刷新、推荐、发现、Wiki 和分享等请求将失败。

老版本提示复用已发布客户端现有能力：Direct 版由 Sparkle 自动检查并展示 appcast 说明；App Store 版启动或重新激活时最多每 24 小时检查一次并弹出更新提示。1.4.0 的 appcast 与 App Store「此版本的新增内容」必须包含以下明确提示：

> 重要更新：Starcat 在线服务已完成升级，请尽快更新至 1.4.0。旧版本仍可查看已有本地缓存，但在线刷新、推荐、发现、Wiki 和分享等服务将不再可用。

只在 1.4.0 新增自定义客户端提示无法触达仍运行老版本的用户，因此本次不新增无效的 1.4.0 应用内迁移横幅。若以后要求老版本弹窗展示自定义迁移原因，必须在停旧服务前另发过渡版本。

## 9. 回滚

- 迁库或聚合验收失败：保持 Starcat 未发布，重新进入维护模式，修复配置或用合并备份重做恢复。
- Sharing 公网异常：把 `starcat.ink` upstream 切回旧 Sharing App，旧 Volume 未删除即可恢复。
- Starcat 正式版一旦发布，客户端默认只认聚合入口；不能把“启动旧 App”当作完整客户端回滚。此时应优先回退聚合镜像 / secrets 或从已验证备份恢复聚合卷。

## 10. 明确不做

- 不合并 `license-api`；
- 不要求用户删除客户端本地数据库；
- 不在本 SOP 或自动审查中擅自执行 deploy、secrets、restore、下线或销毁。
