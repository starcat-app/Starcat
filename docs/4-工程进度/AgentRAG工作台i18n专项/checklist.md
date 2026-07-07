# Agent / RAG 工作台 i18n 专项进度

> 状态: 进行中
> 创建: 2026-07-07
> 目标分支: `feature/agent`

## 1. 目标

把 Agent 工作台和 RAG 工作台的用户可见固定文案接入 Starcat 现有国际化体系:

1. SwiftUI 固定文案改为 `Text("key")` / `Label("key", systemImage:)`。
2. 返回 `String` 的标题、placeholder、panel 标题、状态文案改为 `String.l10n("key")`。
3. `Localizable.xcstrings` 新增 en + zh-Hans 双语 key。
4. 保留 LLM prompt、用户输入、仓库数据、Markdown artifact 等运行内容的原始语义,不在本专项强行翻译动态内容。
5. 补文档、主进度和基础校验。

## 2. 不做范围

- [x] 不翻译用户输入。
- [x] 不翻译 GitHub README / repo metadata / 运行时抓取内容。
- [x] 不重写 Agent 输出语言策略。
- [x] 不调整工作台布局。
- [x] 不 push。

## 3. 实施 checklist

- [x] 新增 Agent / RAG 工作台 i18n 专项 checklist。
- [x] RAG 工作台 UI 壳层文案接入 i18n。
- [x] Agent 工作台 UI 壳层文案接入 i18n。
- [x] 独立 workspace window title 接入 i18n。
- [x] Agent 定义 / 状态 / artifact 类型等用户可见模型文案接入 i18n。
- [x] 同步 `Localizable.xcstrings` en + zh-Hans。
- [ ] 更新 `docs/功能实现总览.md`。
- [ ] 执行 i18n 自检和 JSON 校验。
- [ ] 新增结果报告。

## 4. 验收标准

- [ ] RAG 工作台固定 UI 文案不再直接硬编码中文。
- [ ] Agent 工作台固定 UI 文案不再直接硬编码中文。
- [ ] 两个工作台窗口标题跟随 App 语言设置。
- [ ] 新增 key 均包含 en + zh-Hans。
- [ ] `jq empty Starcat/Resources/Localizable.xcstrings` 通过。
- [ ] `rg "String\\(localized:" --type swift Starcat/` 与 `rg "NSLocalizedString" --type swift Starcat/` 未引入新违规。
