# 公开 Star 自研推荐全链路需求完成结果报告

## 项目目标

在既有公开 Star 静默贡献基线上，完成 Starcat Direct、独立 Collection、离线 Trainer、统一 Recommend API v2 和现有推荐 UI 的完整自研推荐链路；保持 `/api/v1` SimRepo 不变，不创建重复的 `starcat-recsys-api`。

## 完成内容

- Starcat Direct 显式使用 Recommend API v2，App Store target 保持 v1。
- Trainer 在本地 Registry 安装后，可用独立 Publish Key 上传并激活 ServingBundle。
- Recommend API 新增 v2 单仓/多 seed 查询、模型发布、不可变 Registry、active 指针和启动恢复。
- 使用主账户 1954 条真实公开 Star 完成上报、Collection 导出、训练、发布和在线查询。
- 修复单主体 SVD 会中止整条管道的问题；明确记录 skipped 并继续交付可用模型。
- 增加 Starcat 产品 v2 client 对本机 active Bundle 的强制 live integration test。
- 生成包含 BigQuery 时间范围、返回字段、精确 SQL、已验证扫描量和下一步执行前置条件的最终测试报告。

## 功能清单

- `/api/v1/repos/{repo_id}/recommendations`：继续代理 SimRepo。
- `/api/v2/repos/{repo_id}/recommendations`：读取 active ServingBundle 单仓 Top-K。
- `/api/v2/recommendations/query`：支持 positive、negative、exclude 和 limit。
- `/internal/v1/model-bundles/{version}`：白名单压缩包、checksum、manifest、SQLite 和 schema 校验后不可变安装/激活。
- `/internal/v1/model-bundles/active`：查询当前模型版本和 selected model。
- Trainer `publish.recommend_api`：独立密钥、超时、大小上限、activate 开关和无凭据 receipt。
- Starcat `RecommendationAPIContract`：Direct `.trainedV2`，App Store `.simRepoV1`。
- v2 DTO：复用现有推荐卡片结构并增加 `model_version`。
- 单主体训练：Popular/co-star 正常；SVD 的明确样本不足异常只降级当前节点。

## 文档同步情况

- 需求入口、开发前问题清单、61/63 号详细设计与四仓实现一致。
- 63 号第二阶段 checklist 在 UI 验收后全部回填。
- 新增第 5～7 轮审查报告和最终测试报告。
- Trainer README、架构设计、使用说明、实施清单已补单主体冷启动行为。
- `BRANCH.md` 已按四仓目标分支、HEAD 和本地合并状态更新。
- `docs/功能实现总览.md` 与四份中英文更新日志已在 dong4j 明确授权后同步。

## 测试情况

- Starcat 合并后全量：总计 2628、通过 2617、失败 0、跳过 10、预期失败 1。
- Starcat v2 live：1/1 通过，强制要求环境变量并校验真实模型版本。
- Collection：普通测试、race、vet、build 通过。
- Trainer：Ruff、strict mypy、58 项 pytest、88% 覆盖率通过。
- Recommend：12 项测试、race、vet、build 通过。
- 真实数据 E2E：1954 输入 → 1867 有效仓库 → 2000 条 co-star 边 → Bundle 发布/激活 → v2 GET/POST → Starcat client 解码通过。
- Recommend 进程重启后 active model 和查询结果恢复。
- Starcat Direct UI：`getsentry/sentry` 推荐弹窗显示自研 Top-K，首项 `yihong0618/xiaogpt`，推荐理由与 v2 API 一致。

## 审查轮次

- 第 5 轮：发现并修复单主体 SVD 中止全管道问题。
- 第 6 轮：补充 Starcat 真实 v2 client test，核对 Bundle 重启恢复和 BigQuery 前置条件。
- 第 7 轮：完成正确 Direct 构建路径、UI 自研结果、四仓代码、文档、测试和进度一致性复审。
- 合并回归：同步最新 `dev`，收口两组并行 `v22` migration，复跑全量与 live 测试并合入四仓目标分支。

## 遗留问题

单主体离线指标为 0 属于当前真实数据规模限制，不是工程链路缺陷。BigQuery bootstrap、生产部署、正式密钥/TLS、shadow、灰度和生产质量门槛属于下一阶段，不在本次“独立离线基线 + 本机完整链路”的完成定义内。

## 最终完成状态

**已完成并合入各仓库本地目标分支，未 push。**
