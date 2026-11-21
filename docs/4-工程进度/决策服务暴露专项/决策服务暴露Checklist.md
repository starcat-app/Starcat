# 决策服务暴露专项 Checklist

> 状态: 进行中（2026-11-21 dong4j 授权实施）
>
> 本专项把 Starcat 已有的 Jev / Laya 决策执行器暴露给外部调用方。外部只面向 Jev `/v1/systemone` 兼容协议，不感知 Starcat 内部选择的是原生 Jev、OpenRouter 还是本地 Laya；权益、服务开关、配对凭据与写入授权继续沿用现有 App 设置。

## 目标与边界

- [x] 将 Jev 默认原生模型升级为 `jev-1.14.0`，OpenRouter 兜底使用官方 Decisions ID `typesafe/jev-1.14`。保留用户已保存的原生版本。
- [x] 补齐共享决策契约的完整题型：`noul`、`choice`、`score`、`box`。
- [x] 原生 Jev 支持全部题型；Laya 支持文本题型的既有推理路径，不支持的题型返回明确错误。
- [ ] Jev 只保留现有内部承载回退：原生 Key 缺失或最近显式连接测试失败时使用已启用且已验证的 OpenRouter 配置；选定执行路径失败后直接报错。
- [ ] Laya 继续复用已加载模型；模型已安装但未加载时按现有逻辑执行首次加载，不新增跨引擎兜底。
- [x] 通过公共能力目录同时暴露 CLI 通用调用与 MCP 工具，复用同一个 App 执行器。
- [ ] 通过 MCP 服务 HTTP listener 暴露 `POST /v1/systemone`，沿用 Bearer、服务开关、Pro、Host / Origin 与 `write` 权限门禁。
- [ ] 更新中英文用户手册，说明能力范围、认证、冷启动、题型与错误边界。

## 实施记录

- [x] C01 建立专项 Checklist 与提交拆分（`a4ebf141`）。
- [x] C02 核实 Jev 1.14 与 OpenRouter 路由，升级默认值并覆盖已保存版本。模型契约单测纳入 C08。
- [x] C03 扩展共享 DTO、请求校验与原生 Jev 协议映射，5 个相关套件的 58 项定向测试通过。
- [x] C04 扩展 Laya 文本题型推理与不支持题型错误，验证：常规 runtime 单测 5 项通过；公开 checkpoint parity 2 项通过（load 3.87s，首次推理 2.11s，热推理 0.025s）。
- [x] C05 抽象对外决策执行服务并注册公共能力，验证：公共能力静态检查 133 项通过；DecisionSystemOneService routing 与 Starcat public capabilities 定向测试 16 项通过。
- [ ] C06 暴露兼容 HTTP 路由，验证：认证、权益、权限、Host / Origin、schema 与执行器复用单测。
- [ ] C07 编写中英文用户手册并登记导航，验证：Mintlify 双语校验与链接检查。
- [ ] C08 完成定向测试、双渠道构建、公共能力静态检查与交付复核，验证：所有命令通过或明确记录环境限制。

## 授权边界

- 本 Checklist 授权代码实现、测试、用户手册与本地提交。
- 不授权修改 `docs/功能实现总览.md`、生成 Changelog、推送远端、打包发布或执行 GUI 验收。
- 主仓库中与本专项无关的既有未提交改动必须保留，不得纳入任何提交。
