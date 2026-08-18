# 本机 Meilisearch

Starcat 默认用 SQLite FTS5 做知识库关键词检索。这个目录用来在本机起一个 Meilisearch，给可选的外部关键词后端做验证。

索引里会写入公开知识库分片正文，端口只绑 `127.0.0.1:7700`，不要改成 `0.0.0.0`。镜像钉死 `getmeili/meilisearch:v1.53.1`，和当前客户端按 1.53 写的 REST 调用对齐。`MEILI_ENV=development` 是为了打开 mini-dashboard，不代表可以省掉 master key。

## 启动

需要 Docker Desktop，或任意能跑 Compose 的环境。

```bash
cd docker/meilisearch
cp .env.example .env
```

把 `.env` 里的 `MEILI_MASTER_KEY` 换成至少 16 字节的随机串：

```bash
openssl rand -base64 24
```

master key 只用来管 `/keys`，不要填进 Starcat。`.env` 已被 gitignore，不要提交。

```bash
docker compose up -d
```

健康检查通过后：

```bash
curl -sS http://127.0.0.1:7700/health
```

应返回 `{"status":"available"}`。容器名是 `starcat-meilisearch`，数据在 Docker volume `starcat-meilisearch-data`。

从仓库根目录也可以：

```bash
docker compose -f docker/meilisearch/docker-compose.yml up -d
```

缺少 `.env` 或没设 `MEILI_MASTER_KEY` 时，compose 会直接失败，避免无密钥启动。

停实例：

```bash
docker compose down
```

连数据一起清掉（下次要重新灌索引）：

```bash
docker compose down -v
```

## 取出 Default Admin API Key

自托管设了 master key 之后，Meilisearch 会生成默认 API key。Starcat 要的是 Default Admin API Key，用来建 index、写文档、改 settings。Default Search API Key 只能搜，灌索引会失败。

在 `docker/meilisearch/` 下：

```bash
set -a && source .env && set +a
curl -sS 'http://127.0.0.1:7700/keys' \
  -H "Authorization: Bearer ${MEILI_MASTER_KEY}"
```

在 `results` 里找 `name` 为 `Default Admin API Key` 的那条，复制 `key` 字段。也可以只打出这一条：

```bash
curl -sS 'http://127.0.0.1:7700/keys' \
  -H "Authorization: Bearer ${MEILI_MASTER_KEY}" \
| python3 -c 'import json,sys; keys=json.load(sys.stdin)["results"]; print(next(k["key"] for k in keys if "Admin" in (k.get("name") or "")))'
```

## 接到 Starcat

设置 → AI → RAG 后端：

| 项 | 填什么 |
|---|---|
| 关键词检索 | Meilisearch |
| Endpoint | `http://127.0.0.1:7700` |
| Index | `starcat_rag_chunks`（默认即可） |
| API Key | 上一步拿到的 Default Admin API Key |

这一套 compose 强制了 master key，Starcat 里的 API Key 不能留空。填完后点「测试并保存」。这一步只打 `/health`，能通只说明实例活着，不证明 key 有写权限，也不会创建 index。

然后点同一段里的「重建」，或用知识库工作台 / 浏览器索引概览的重建。重建一开始就会把公开仓正文 upsert 进 Meilisearch，不必等向量化跑完。dashboard 里暂时看不到 `starcat_rag_chunks` 是正常的：index 是 POST 文档时才建出来的。

检索时如果 Meilisearch 挂了，可打开「外部后端不可用时回退 SQLite」。

## mini-dashboard

浏览器打开 `http://127.0.0.1:7700`。若要求输入 API key，填 Default Admin API Key，不要填 `MEILI_MASTER_KEY`。部分版本的 dashboard 还会再要一个和 Admin key 不同的会话密钥，那是 dashboard 自己的限制，Starcat 检索不依赖它。

## 常见情况

- 测试并保存成功，但检索仍像 FTS、dashboard 没有文档：还没重建，或重建还没跑到关键词同步。
- 重建报 401 / 403：Starcat 里填了 master key，或填了只能搜的 Search API Key。
- `down -v` 或换了 `MEILI_MASTER_KEY` 之后：volume 没了要再重建；默认 API key 也会变，设置里要重填。
