# 聚合迁库 SOP：独立 App `/data` → `starcat-api`

> 日期: 2026-08-08  
> 状态: 文档就绪（**本文不执行** Fly 部署 / 迁库；由运维人工按需执行）  
> 相关: `supports/docs/fly-io-环境变量.md`、`supports/scripts/fly-backup-data.sh`、`fly-restore-data.sh`

## 1. 目标

把六个业务 API（不含 license）从各自 Fly App 的 volume，迁到单一 `starcat-api` volume：

| 来源 App（遗留） | 目标路径（聚合卷 `/data`） |
|------------------|---------------------------|
| starcat-sharing-api | `/data/sharing.db` |
| starcat-trending-api | `/data/trending.db` |
| starcat-weekly-api | `/data/weekly.db` + `/data/weekly-repo/` |
| starcat-wiki-api | `/data/wiki.db` |
| starcat-discovery-api | `/data/discovery.db` |
| starcat-recommend-api | 无 SQLite，无需迁库 |

**禁止**把多库 schema 合成单文件；同卷分文件即可。

## 2. 前置

1. 本地已能 `fly auth login`，有权操作旧 App 与 `starcat-api`。
2. `supports/starcat-api/.env` 已填 `STARCAT_SHARED_API_KEY` 与各前缀 secrets（见 `.env.example`）。
3. Starcat 客户端默认已指向 `https://starcat-api.fly.dev`；切流前须先完成部署与验收。
4. 预留维护窗口：迁库期间对应服务短暂不可用。

## 3. 备份（旧 App）

在 `supports/`：

```bash
make fly-backup-all
# 或逐个：
make fly-backup-sharing
make fly-backup-trending
make fly-backup-weekly
make fly-backup-wiki
make fly-backup-discovery
```

产物：`supports/backups/<app>/<timestamp>/`（含 `data.tar.gz`、`MANIFEST.txt`）。  
**保留备份至少至切流稳定后再删旧 App volume。**

## 4. 准备聚合 App

1. 创建 / 确认 Fly App `starcat-api` 与 volume 挂载 `/data`（见 `supports/starcat-api/fly.toml`）。
2. 同步 secrets（**不**在本文自动执行）：

```bash
make -C supports fly-secrets-api
```

3. 首次部署聚合二进制（人工）：`make -C supports fly-deploy-api`。

## 5. 恢复到聚合 `/data`

原则：对每个有状态服务，把备份中的主库（及 weekly-repo）放到聚合 Machine 的对应路径。

推荐流程（示意；具体以 `fly-restore-data.sh` / SSH 为准）：

1. 从各备份解出 `*.db`（优先用备份内 `VACUUM INTO` 一致性副本）。
2. `fly ssh console -a starcat-api`（或脚本）上传到：
   - `/data/sharing.db`
   - `/data/trending.db`
   - `/data/weekly.db` + `/data/weekly-repo/`
   - `/data/wiki.db`
   - `/data/discovery.db`
3. 上传后删除远端残留的 `*-wal` / `*-shm`（若有），再重启 Machine。

若脚本尚未支持「目标 App = starcat-api、自定义 STORE 路径」，可用：

```bash
# 示例：先在本机解包，再 scp/sftp 到聚合机（路径按实际 Machine 调整）
tar xzf supports/backups/starcat-trending-api/<ts>/data.tar.gz -C /tmp/restore-trending
# 将解出的 trending.db 放到聚合 /data/trending.db
```

weekly 必须同时恢复 `weekly-repo/`，否则周刊源缓存会冷启动重拉。

## 6. 验收（切流前）

```bash
curl -fsS https://starcat-api.fly.dev/healthz
# 六个服务（替换 <key>）：
for s in trending weekly sharing wiki recommend discovery; do
  curl -fsS -H "X-SC-Svc: $s" -H "Authorization: Bearer <key>" \
    https://starcat-api.fly.dev/api/v1/ping
done
```

抽样业务：trending repos、weekly bulk、wiki probe、sharing ping、discovery summary、recommend（依赖 simrepo）。

## 7. 切流与旧 App

1. 发版 Starcat（baked-in Key = 共用 Key；默认 URL 已是聚合）。
2. 观察错误率 / 状态栏 `/healthz`。
3. 旧 `starcat-*-api`：**先停 Machine / 摘流量，保留 volume 数日**，再销毁。
4. 独立开源仓可继续存在（单仓叙事 / 自托管）；与是否停 Fly 独立 App 解耦。

## 8. 回滚

1. 恢复旧 App Machine（volume 未删则可直接起）。
2. 客户端临时在「设置 → 服务」填回各 `*-api.fly.dev`，或回退 App 版本。
3. 聚合卷上的新写入不会自动回灌旧 App——以切流前备份为准。

## 9. 明确不做（本 SOP 范围外）

- 不合并 license-api
- 不要求用户删库重建客户端本地数据
- Agent / 自动化默认**不**执行本 SOP 中的 deploy / restore（铁律 #3）
