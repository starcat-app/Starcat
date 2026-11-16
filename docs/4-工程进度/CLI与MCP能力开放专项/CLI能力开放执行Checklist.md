# CLI 能力开放执行 Checklist

> 状态：代码、契约、规则、自动化与双渠道构建完成；真实连接验收另列
> 原实施工作区：`../Starcat-cli-browser-access`；2026-11-16 已合入各仓 `dev` 并清理，当前使用主工作区，见[合并与清理记录](2026-11-16-dev合并与worktree清理记录.md)。
> 总清单：[CLI与MCP能力开放Checklist.md](CLI与MCP能力开放Checklist.md)
> 本页保留 2026-11-15 首轮交付证据。当前契约 v3、127 个工具及旧 32 项复查以[整改 Checklist](全能力审查与读写权限整改Checklist.md)和[覆盖表](能力覆盖清单.md)为准，下列旧数字不代表当前状态。

## 执行批次

- [x] EXEC-01 核对现有授权、基线、分支与配套仓库，创建隔离 worktree 并复制本机配置
- [x] EXEC-02 115 项登记，96 个现有动作均有结论，入口 / 权限 / 副作用 / 证据已关联
- [x] EXEC-03 公共目录 v2、默认预览迁移、Schema、任务与文件契约已落档
- [x] EXEC-04 tools / resources、单对象 stdin / file、统计 JSON 已实现并有 Go 回归
- [x] EXEC-05 24 基线全部双入口，既有协议 / 写入及 global-search 回归；真实版本组合见 CASE
- [x] EXEC-06 已批准适配器复用 App 执行器，32 个暂缓项记录真实条件，不虚构规划功能
- [x] EXEC-07 正式规范、三仓 AGENTS 与任务模板、静态检查已接入
- [x] EXEC-08 设计 / CLI / Skill 文档已同步，help + App 注册 validator 通过
- [x] EXEC-09 Swift 103 项 / 10 Suite、App Store / Direct 构建与校验、Go test / race / vet / 五平台编译通过
- [x] EXEC-10 总清单及 CASE 逐项关联证据，平台差异与人工验收见验证与交付记录

## 验证记录

只记录实际执行命令与结果。未验证、受外部依赖阻塞、等待人工验收均保持未完成，不用“已评估”代替实现。

完整命令及真实限制见[验证与交付记录](验证与交付记录.md)。本轮未执行真实用户库写入、AI 计费生成或 GUI；READ-07、CASE 实机组合与正式关闭门禁继续保留。
