# 任务计划与 Checklist

2026-11-19，Direct 版开发交付清单 **13/13**，等待 dong4j 功能与 UI 验收。专项分支 `codex/skill-evaluator` 从 `origin/dev` 的 `d436acf6` 建立。需求、方案与任务计划提交为 `43a78a5b`，实现提交为 `a64cc8c4`。将 `origin/dev` 的 `3f3ce589` 合入专项分支后，在 `fe47ccef` 上完成最终定向测试和双渠道构建。

## 开发交付

- [x] 写需求分析、落地方案，创建独立 worktree，登记基线与后续归宿。
- [x] 以 v1.0.1 CLI 和无害样本核对命令、报告、退出码、三类 AI 调用边界及扫描器依赖。
- [x] 为固定仓库提交与本机库 UUID 生成原始快照，移除副本文件的执行权限，限制文件与模型输入范围。
- [x] 定位固定版本的工具，从报告读取结构、质量、兼容性、静态安全、AI 质量、Skill 内去重和跨 Skill 重叠的证据。
- [x] 接入上次报告、过期判定、JSON 导出、批量队列及取消，两处入口使用同一任务服务。
- [x] 接入仓库详情的单选和管理窗口的单选、多选，支持在评估面板筛选检查状态。
- [x] 登记 Direct 公共 CLI/MCP 工具，覆盖读写分级、账号范围、任务取消和 App Store 隐藏。
- [x] 校验新增文案的 17 种语言、占位符、编译资源和审核状态。
- [x] 运行定向单测、公共目录与 Skill 契约校验、CLI 测试和双渠道构建。
- [x] 第一轮评审覆盖输入、子进程、网络与凭据，修复并回归验证。
- [x] 第二轮评审覆盖缓存、取消、并发与公共 API，修复并回归验证。
- [x] 第三轮评审覆盖 UI 状态、渠道、辅助功能与本地化，修复并回归验证。
- [x] 记录评审证据，提供验收工具、运行方式与人工清单。

## 三轮代码评审

| 轮次 | 发现与修复 | 复验 |
|---|---|---|
| 1 · 输入与执行 | 对固定 Git blob 校验原始字节和大小，拒绝改指向或越界的本地链接。取消或超时后回收同组子进程。兼容报告剔除由临时位置产生的规则，静态安全必须有完成扫描的证据。 | `SkillEvaluationInputTests` 覆盖无效清单、空文件、二进制、同长异内容及预算。`SkillEvaluationRunnerTests` 覆盖实际启动的子进程、取消与超时、扫描器只有版本、缺失 Agent 结果，以及每种模式使用的参数和凭据。 |
| 2 · 任务与缓存 | 重新打开面板按模式、选区与仓库提交恢复任务。批次取消保留此前的报告和失败项。切账号时等待旧任务退出，损坏的缓存由成功重跑替换。 | `SkillEvaluationServiceTests` 用隔离缓存与可控 CLI 验证回接、互斥、批次部分完成、切号重跑和文件改变。`StarcatMCPPublicCapabilityTests` 验证仅当前提交可读、默认预览、AI 同意及公共取消句柄。 |
| 3 · 界面与渠道 | 兼容矩阵逐行呈现六种 Agent 的证据与缺项。已知报告模板随 App 语言显示，未知模板保留原文。长译文可改为纵排，VoiceOver 可整行读取。 | `SkillEvaluationReportPresentationTests` 核对六种 Agent、未知规则、分数精度及定位。Catalog 完成编译与占位符校验，公共目录测试验证渠道差异。视觉、键盘及 VoiceOver 实际体验留在下方人工清单。 |

## 自动验证记录

| 验证对象 | 结果 |
|---|---|
| App 定向回归 | 6 个套件，81 项全部通过。除上述 5 个套件，还有 `RepoSkillTests` 复验仓库 Skills 的扫描、阅读与安装行为。 |
| Direct 与 App Store | 在同一源码提交先后执行 `make build-direct` 与 `make build-appstore`，两套 App 及各自 Widget 均通过产物校验。 |
| CLI、MCP 与 Skill | `scripts/check-public-capabilities.py` 核对 133 个工具、180 条登记。CLI 的 `go test ./...` 和 Skill 的 `scripts/validate_contract.py` 均通过。连接正在运行的 Direct App 调用工具留给人工验收。 |
| 国际化 | `skills.evaluation.*` 共 114 个键，每键含 17 种语言，共 1,938 条文案。140 条为 `translated`，1,798 条为 `needs_review`。机器校验含占位符和编译结果，翻译质量仍待人工复核。 |
| 上游命令 | 固定版本 CLI 已在无害样本上验证五种模式。静态安全使用真实 SkillSpector `2.13.4`。三个 AI 模式均使用本机模拟端点，真实模型验收需要用户选择配置和发送范围。[上游契约实测](04-上游契约实测.md) |

## 运行验收版

本机专项 worktree 已生成 `build/DerivedData-NoSandbox/Build/Products/Debug/Starcat.app`。第一次打开评估面板时，可通过「选择评估工具…」选中 `build/SkillEvaluator-acceptance/bin/skillevaluator`。这份独立环境已装好三个 AI 模式所需依赖，固定版本探测、快速检查和兼容性报告均已在该副本复验。

在其他机器上可用以下命令安装同一版本。默认用户安装位置为 `~/.local/bin/skillevaluator` 时，App 可自动发现。如果配置了其他工具安装目录，可在面板手动选择可执行文件。该版本支持 Python 3.12–3.14。[上游安装说明](https://github.com/NVIDIA/SkillEvaluator/blob/v1.0.1/README.md#get-started) · [版本与依赖声明](https://github.com/NVIDIA/SkillEvaluator/blob/v1.0.1/pyproject.toml)

```bash
uv tool install --python 3.13 'skillevaluator[tier2]==1.0.1'
skillevaluator --version
```

版本探测应显示 `skillevaluator, version 1.0.1`。快速检查无需模型。静态安全可能需要联网获取扫描器。AI 模式在确认页显示首发端点，固定版上游 SDK 可能跟随该服务的 HTTP 重定向。

## dong4j 人工验收

- [ ] **仓库详情 → Skills**。选中一个 Skill，点击工具栏清单图标「评估」，运行「快速检查」。打开报告，核对结构、质量和六种 Agent 的静态兼容信息。关闭、重开应能回读上次报告。切换条目后检查报告归属，切换翻译后仍评估原始文件。
- [ ] **Skill 管理 → 单选**。评估一个测试用本机 Skill，在报告明细中导出 JSON。改动该测试条目的正文，再打开同一模式，旧报告应显示「已过期」。重跑后检查新结果。
- [ ] **Skill 管理 → 多选**。选中多个条目，运行批量快速检查或静态安全。关闭面板再用相同选区和模式回接。完成一项后取消，核对已完成报告、逐项失败、其余条目的状态，以及状态筛选结果。
- [ ] **静态安全**。使用无害样本核对扫描器结果。在扫描器不可用或覆盖不足时，确认界面能区分「未完成」和「通过」。
- [ ] **实际模型连接**。单选试「AI 质量评审」与「Skill 内去重」，多选两个测试条目试「跨 Skill 重叠」。核对端点、模型和所选条目，先取消一次确认，再明确发送。分别查看评审维度、重复段依据及条目间描述重叠。
- [ ] **CLI/MCP**。连接验收版 Direct，查看 `starcat.start_skill_evaluation` 的参数并先预览，用测试条目显式执行。用 `starcat.get_task_status` 跟踪，然后通过 `starcat.get_skill_evaluation` 回读、`starcat.export_skill_evaluation` 导出。App Store 目录应隐藏三个专项工具。
- [ ] **界面与辅助功能**。两处入口分别检查明暗主题、窄栏、放大字号、长译文和 RTL。用键盘打开报告、返回和关闭，并检查「减少动态效果」和 VoiceOver 朗读兼容矩阵。

实际效果评测已按需求排除。验收期间保留专项 worktree。CLI 独立仓的中英文 README，以及 Skill 独立仓的命令参考与校验脚本，均在各自的专项 worktree。外部任务未查到匹配主关联，尚未登记为已验收。
