# 决策服务暴露专项 Checklist

> 状态：本地实现与验收完成，待功能实现总览登记（2026-11-21）
>
> 本专项把 Starcat 已有的 Jev / Laya 决策执行器暴露给外部调用方。外部只面向 Jev `/v1/systemone` 兼容协议，不感知 Starcat 内部选择的是原生 Jev、OpenRouter 还是本地 Laya；权益、服务开关、配对凭据与写入授权继续沿用现有 App 设置。

## 目标与边界

- [x] 将 Jev 默认原生模型升级为 `jev-1.14.0`，OpenRouter 兜底使用官方 Decisions ID `typesafe/jev-1.14`。保留用户已保存的原生版本。
- [x] 补齐共享决策契约的完整题型：`noul`、`choice`、`score`、`box`。
- [x] 原生 Jev 支持全部题型；Laya 支持文本题型的既有推理路径，不支持的题型返回明确错误。
- [x] Jev 沿用现有承载回退。原生 Key 缺失或最近显式连接测试失败时使用已启用且已验证的 OpenRouter 配置。选定执行路径失败后直接报错。
- [x] Laya 沿用本地执行路径。模型已安装时按需加载，后续复用已加载的模型。
- [x] 通过公共能力目录同时暴露 CLI 通用调用与 MCP 工具，复用同一个 App 执行器。
- [x] 通过 MCP 服务 HTTP listener 暴露 `POST /v1/systemone`，沿用 Bearer、服务开关、Pro、Host / Origin 与 `write` 权限门禁。
- [x] 更新中英文用户手册，说明能力范围、认证、冷启动、题型与错误边界。

## 实施记录

- [x] C01 建立专项 Checklist 与提交拆分（`a4ebf141`）。
- [x] C02 核实 Jev 1.14 与 OpenRouter 路由，升级默认值并保留已保存版本（`df41fb74`）。
- [x] C03 扩展共享 DTO、请求校验与原生 Jev 协议映射（`56aa570`）。首轮 5 个套件的 58 项测试通过。
- [x] C04 扩展 Laya 的三种文本题型，并拒绝图片和 `box`（`82a7d57b`）。常规 runtime 测试 5 项、真实 checkpoint 测试 2 项通过。
- [x] C05 注册 CLI 与 MCP 公共能力并复用 App 执行器（`0b9ad95d`）。执行器路由与公共能力定向测试 16 项通过。
- [x] C06 提供 `POST /v1/systemone`，支持 JSON Base64 和 multipart（`8cc89d8b`、`6279b9d5`）。覆盖响应格式、图片启用头、认证与写权限、请求体大小上限。
- [x] C07 在 `supports/starcat-docs` 添加双语手册、导航和 CLI／MCP 入口链接（`abcf047`）。Node 22 下 `mint validate` 与 `mint broken-links` 通过。
- [x] C08 完成定向测试、双渠道构建、公共能力静态检查与交付复核。

## 验证结果

- `make test` 定向回归通过 12 个套件的 103 项测试。运行日志为 `build/DerivedData-Tests/Logs/Test/Test-Starcat-2026.11.21_22-35-57-+0800.xcresult`。
- Jev 原生与 OpenRouter 使用模拟上游验证请求映射、路由和失败行为。Laya 使用本机已安装的真实多语言 checkpoint 对拍，覆盖文本批次与加载、卸载。
- 官方 Python SDK `typesafe-sdk[zstd]==0.7.5` 使用真实回环 listener 和替身引擎验证。`compression=False` 时，JSON 文本批次与 `attach_assets` multipart Box 均通过，SDK 成功读取 `model`、`usage`、零基 `score.legend` 和 `box.confidence: null`。默认压缩的大请求返回 `415`，手册提供未压缩配置。
- `make build-appstore` 与 `make build-direct` 的 Debug 构建和产物校验均通过。
- `python3 scripts/check-public-capabilities.py` 验证 133 个工具与 179 条登记。CLI 的 `go test ./...` 和 `go mod verify` 通过。

## 授权边界

- 本 Checklist 授权代码实现、测试、用户手册与本地提交。
- 不授权修改 `docs/功能实现总览.md`、生成 Changelog、推送远端、打包发布或执行 GUI 验收。
- 主仓库中与本专项无关的既有未提交改动必须保留，不得纳入任何提交。
