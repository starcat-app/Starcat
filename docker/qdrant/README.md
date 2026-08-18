# 本机 Qdrant

Starcat 默认用 SQLite 存 embedding、本地算 cosine。这个目录用来在本机起一个 Qdrant，给可选的外部向量后端做验证。

索引里会写入知识库向量和 payload（`repo_id`、`embedding_model` 等），端口只绑 `127.0.0.1:6333`，不要改成 `0.0.0.0`。镜像钉死 `qdrant/qdrant:v1.19.0`，客户端走 REST：named vector、`/points/query`、`wait=true` 写入。Starcat 不用 gRPC，所以不暴露 6334。

和 Meilisearch 互不影响，可以同时跑。关键词仍走 FTS 或 Meilisearch；这里只接向量检索。

## 启动

需要 Docker Desktop，或任意能跑 Compose 的环境。

```bash
cd docker/qdrant
cp .env.example .env
```

把 `.env` 里的 `QDRANT_API_KEY` 换成随机串：

```bash
openssl rand -base64 24
```

这把 key 就是 Starcat 要填的 API Key，请求头是 `api-key`，没有 master / Admin 分叉。`.env` 已被 gitignore，不要提交。

```bash
docker compose up -d
```

健康检查通过后：

```bash
set -a && source .env && set +a
curl -sS http://127.0.0.1:6333/healthz \
  -H "api-key: ${QDRANT_API_KEY}"
```

应返回 `healthz check passed`。容器名是 `starcat-qdrant`，数据在 Docker volume `starcat-qdrant-storage`。

从仓库根目录也可以：

```bash
docker compose -f docker/qdrant/docker-compose.yml up -d
```

缺少 `.env` 或没设 `QDRANT_API_KEY` 时，compose 会直接失败，避免无密钥启动。

停实例：

```bash
docker compose down
```

连数据一起清掉（下次要重新灌向量）：

```bash
docker compose down -v
```

## 接到 Starcat

设置 → AI → RAG 后端：

| 项 | 填什么 |
|---|---|
| 向量检索 | Qdrant |
| Endpoint | `http://127.0.0.1:6333` |
| Collection | `starcat_rag_chunks`（默认即可） |
| Vector 名称 | `content`（默认即可，必须和客户端创建 collection 时的 named vector 一致） |
| API Key | `.env` 里那把 `QDRANT_API_KEY` |

这一套 compose 强制了 API key，Starcat 里不能留空。填完后点「测试并保存」。这一步会打 `/healthz`，再 `GET` 一次 collection：404 算正常，collection 会在首次带 ready 向量的重建里按当前 embedding 维度创建。

然后点同一段里的「重建」，或用知识库工作台 / 浏览器索引概览的重建。Qdrant **只收当前模型的 ready 向量**，pending / stale / 纯 metadata 不会写入。没配 Embedding、或向量化还没跑完时，dashboard 里看不到 collection 是正常的。

检索时如果 Qdrant 挂了，可打开「外部后端不可用时回退 SQLite」。

## Dashboard

浏览器打开 `http://127.0.0.1:6333/dashboard`。若要求输入 API key，填 `.env` 里同一把，不要留空。

## 常见情况

- 测试并保存成功，但 dashboard 没有 `starcat_rag_chunks`：还没重建，或重建还在拉 README / 向量化，还没有当前模型的 ready 分片。
- 重建报 401：Starcat 里的 API Key 和 `.env` 不一致，或留空了。
- 重建报 named vector 缺失或维度不匹配：这个 collection 不是 Starcat 建的，或换过 embedding 模型导致维度变了。不要硬灌。删掉 collection，或 `docker compose down -v` 后再重建。
- `down -v` 或换了 `QDRANT_API_KEY` 之后：volume 没了要再重建；key 变了设置里要重填。
