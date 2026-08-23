# Starcat 公开 Star 数据贡献使用说明

## 1. 功能行为

Starcat 的“匿名贡献公开 Star 数据”默认关闭。用户登录 GitHub 后可在“设置 → 通用 →
隐私与推荐”开启。开启代表允许当前 GitHub 账户在下一次**正常成功的 Stars 完整同步**后，
静默上传以下字段：

- 账户级随机 `participant_id`；不由 GitHub ID、login、设备或硬件信息派生。
- 完整快照时间、随机 `snapshot_id`、schema 版本和 canonical hash。
- 公开仓库的 GitHub `repo_id` 与可空 `starred_at`。

不会上传 Private/Internal 仓库、仓库名称、GitHub 账号资料、Token、标签、笔记、状态、
列表、搜索、浏览、README、AI/RAG 内容或本地路径。关闭开关会立即停止后续贡献并清空
未发送 Outbox，但保留随机 `participant_id`，再次开启不会制造重复匿名主体。

上报是严格旁路：不会主动触发 GitHub 同步，也不会展示待传数量、上次成功时间、错误、
通知或重试状态。Collection 不可用、超时、鉴权失败或 App 退出都不影响 Starcat 其他功能；
任务在后台指数退避，最长 24 小时，并在启动、网络恢复、账户切换和完整同步成功时扫描。

## 2. 客户端配置

`starcat-collection-api` 使用独立域名和 Bearer Key，不经过 `starcat-api` Gateway：

```text
https://collection.starcat.ink
```

在未提交的 `Configs/Secrets.xcconfig` 中配置服务端 `API_KEYS` 白名单中的客户端写入 key：

```xcconfig
STARCAT_COLLECTION_API_KEY = your-client-write-key
```

不要把 Collection Admin Key 放进 Starcat App。Admin Key 只供训练管道 Pull 导出，必须通过
训练进程环境变量 `STARCAT_COLLECTION_ADMIN_KEY` 提供。

## 3. 本机三仓完整 E2E

### 3.1 启动独立 Collection 服务

在 `supports/starcat-collection-api` 执行：

```bash
E2E_DIR="$(mktemp -d)"
PORT=5011 \
STORE_FILE="$E2E_DIR/collection.db" \
API_KEYS='client-e2e-key' \
ADMIN_API_KEYS='admin-e2e-key' \
PARTICIPANT_HMAC_KEY='collection-e2e-hmac-key-at-least-32-bytes' \
go run ./cmd/server
```

保持该进程运行。`GET /healthz` 只证明进程存活；Swift live test 会真实执行 create、chunk
和 commit，成功后才能被 Admin 导出。

### 3.2 用 Starcat Swift DTO 真实上传

在 Starcat 根目录执行：

```bash
xcodebuild -scheme Starcat \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS= \
  STARCAT_COLLECTION_API_BASE_URL='http://127.0.0.1:5011' \
  STARCAT_COLLECTION_API_KEY='client-e2e-key' \
  -only-testing:StarcatTests/CollectionAPILiveIntegrationTests test
```

该显式测试生成 repo 1～4 的 Swift schema v1 完整快照并提交。常规测试没有上述构建设置时
不会访问网络。

### 3.3 Collection Pull → 完整训练 → Bundle

在 `starcat-recsys-trainer` 执行：

```bash
export STARCAT_COLLECTION_ADMIN_KEY='admin-e2e-key'
uv run starcat-recsys pipeline run --config configs/example-collection-local.yaml

uv run starcat-recsys bundle verify \
  workspace/registry-e2e/versions/example-collection-local-v1

uv run starcat-recsys bundle query \
  workspace/registry-e2e/versions/example-collection-local-v1 \
  --repo-id 1 --limit 3
```

该配置使用真实 Collection NDJSON 导出，并用本地公开 metadata fixture 补齐 repo 1～4，
不访问 GitHub API。管道仍完整执行 raw、canonical、dataset、Popular、SVD、co-star、
ablation、离线评估、ServingBundle 发布、checksum/SQLite 校验和只读查询。

Registry 版本不可覆盖。再次运行时复制配置并同时修改 `run_id`、`workspace`、`registry`
与 `publish.model_version`。

## 4. 验收边界

- 自动化测试证明 DTO、hash、Outbox、HTTP 协议、同步边沿、重试、开关与三仓 E2E。
- 设置页的实际布局、文案换行和 VoiceOver 仍需在 macOS App 中人工查看一次。
- 当前任务不部署 Collection 服务、不发布训练 Bundle，也不 push 任一仓库。
