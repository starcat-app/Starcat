# 公开 Star 数据贡献全链路需求完成结果报告

## 项目目标

在不影响 Starcat 正常功能的前提下，实现用户主动同意后的公开 Star 数据静默贡献链路，并把数据通过独立 `starcat-collection-api` 交付给可扩展离线训练管道，最终生成可校验、可查询的推荐 ServingBundle。

## 完成内容

本次完成了 Starcat 前端隐私开关、公开快照构造、账户级 Outbox、旁路上传与静默重试；完成独立 Collection 服务的接收、校验、匿名化、持久化、导出、migration、回收与限流；完成 Trainer 的 Collection Source Connector、真实 Pull、标准化、训练、离线评估、模型包发布和查询。

## 功能清单

- Starcat 设置页仅提供一个“匿名贡献公开 Star 数据”Toggle，默认关闭，无状态、错误、数量或时间展示。
- 只在下一次正常完整 Stars 同步成功后上报；增量同步、304、失败和取消不触发。
- 客户端只保留公开 `repo_id`、可空 `starred_at`、随机主体/快照 ID、时间、schema 与 hash。
- Private/Internal、身份、Token、标签、笔记、README、AI/RAG、搜索和本地路径不会进入 payload。
- v22 migration 增加账户级授权和单槽 Outbox；关闭时清空未发送任务但保留随机主体。
- 三阶段分块上传幂等，失败静默指数退避，最长 24 小时，且不改变 Stars 同步结果。
- Collection 是独立 Git 仓库、进程、数据库、鉴权和域名边界，不经过 `starcat-api` Gateway。
- Collection 数据库不保存原始 `participant_id`，只保存 HMAC-SHA256 `participant_key`。
- active snapshot 按业务时间原子切换；旧重试不能覆盖更新快照。
- SQL schema 可追加迁移；未提交上传 24 小时回收；公网地址和匿名主体具备短期限流。
- Admin 导出稳定排序并提供 ETag/checksum；客户端公共 key 不能访问。
- Trainer 通过 `starcat_collection_api` Connector Pull，并复用原有多数据源接口和完整训练节点。
- ServingBundle 包含版本、输入 checksum、指标、SQLite 推荐索引，可执行 verify 和 query。

## 文档同步情况

- 需求入口、60/61/63 详细设计已与最终实现核对。
- 新增 Starcat 公开 Star 数据贡献使用说明与三仓本机 E2E 命令。
- Collection 中英文 README、中文 API、隐私、安全、贡献和支持文件齐全。
- Trainer README、使用说明和本机 Collection 示例配置已同步。
- 63 号详细设计专项 checklist 12 项全部完成。
- `docs/功能实现总览.md` 因未取得 dong4j 单独授权保持只读，未擅自改写。

## 测试情况

- Starcat：最终串行全量 `2579` 项，失败 `0`；通过 `2568`、跳过 `10`、预期失败 `1`。
- Collection：`go test ./...`、`go test -race ./...`、`go vet ./...`、`go build ./...` 全部通过。
- Trainer：格式、Ruff、mypy、`53` 项 pytest、`89%` 覆盖率、sdist/wheel 构建全部通过。
- 三仓 E2E：全新 SQLite 上完成 Swift 分块上传、2 个匿名主体导出、完整训练、Bundle verify/query。
- E2E 指标：`evaluated_subjects=1`、`coverage=0.25`、`recall@3=1.0`、`mrr@3=1.0`、`ndcg@3=1.0`。

## 审查轮次

- 第 1 轮：修复旧上传失败错误延后最新 Outbox 快照的并发问题，并补并发测试。
- 第 2 轮：补齐 Collection SQL migration、24 小时未提交上传回收和专项 checklist。
- 第 3 轮：补齐非空离线评估夹具、公网/匿名主体限流及对应测试。
- 第 4 轮：三仓最终文档、代码、测试和进度复审，无新增问题。

## 交付位置

- Starcat 专项分支：`codex/collection-pipeline`
- Collection 仓库：`supports/starcat-collection-api`
- Trainer 专项分支：`codex/collection-api-source`
- 使用说明：`docs/2-产品/需求讨论/推荐算法/Starcat公开Star数据贡献使用说明.md`
- 审查报告：`docs/2-产品/需求讨论/推荐算法/审查报告/`

## 遗留问题

无。

生产部署、真实客户端 key 注入、正式数据训练和设置页视觉人工验收属于后续发布验收，不是本次实现遗留；本次按授权未 push、未部署、未发布模型。

## 最终完成状态

**已完成。** 第一阶段公开 Star 数据贡献与离线推荐训练全链路已实现、已测试、已审查并形成可复现使用文档。
