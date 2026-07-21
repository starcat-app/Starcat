# AI 个人笔记生成专项 Checklist

> 状态: 进行中
> 创建: 2026-07-22
> 基线: `dev@45aa9763`
> 实施分支: `dev`
> 工作区: `/Users/dong4j/Developer/1.AI/ai-incubator/Starcat`

## 1. 目标与边界

- [x] 新增正式方案，明确 AI 个人笔记的产品边界、步骤可视化、数据安全与验收标准。
- [x] 新增详细设计，明确状态机、README 准备、AI 流式调用、确认保存、UI 与测试设计。
- [x] AI 仅接收原始 README Markdown 和点击生成时的个人笔记快照，不使用 README HTML。
- [x] 既有个人笔记为必须保留的上下文，AI 只能整理、补全，不得静默丢失。
- [x] AI 先生成独立草稿，用户确认后才写入本地笔记并刷新语义索引。
- [x] 本期复用 AI 摘要的 Provider / Model / 参数与流式实现，不新增独立设置页。
- [x] 复用已有 `repo_notes.is_ai_generated`，不新增数据库迁移。

## 2. 笔记保存语义

- [ ] `RepoNoteRepositoryProtocol` 支持显式传入 `isAIGenerated`。
- [ ] AI 草稿确认保存时写入 `is_ai_generated = true`。
- [ ] 用户后续手工修改或清空笔记时写入 `is_ai_generated = false`。
- [ ] 新增 Repository 单测，覆盖 AI 标记设置、手工修改清除与删除语义。

## 3. README 准备与 AI 流式生成

- [ ] 新增可测试的 README 准备边界：先查本地 Markdown 缓存，缺失时下载原始 README Markdown。
- [ ] README 主记录未建立时，先刷新 README 主记录，再下载 Markdown。
- [ ] 无 README、下载失败或 Markdown 仍为空时结束流程并显示可诊断错误。
- [ ] AI 就绪预检在 README 网络请求之前执行，避免无配置时无意义下载。
- [ ] 新增个人笔记专用 prompt，要求快速上手、必要大纲和简短描述，并显式保留既有笔记。
- [ ] 输入按 UI 语言指定输出语言，README 和笔记被标记为不可信数据。
- [ ] 复用 AI 摘要的流式客户端语义，正确处理 delta、完成、空响应、取消与非流式 Provider。
- [ ] 新增稳定 AI 用量功能标识，个人笔记生成请求可在用量面板中独立识别。
- [ ] 新增 prompt 与流式服务单元测试。

## 4. 状态机与取消安全

- [ ] 实现七个固定步骤：检查 AI、读取 README、下载 README、准备笔记、AI 生成、等待确认、保存笔记。
- [ ] 步骤状态覆盖 pending / running / completed / skipped / failed / cancelled。
- [ ] 实现总体阶段 idle / running / awaitingConfirmation / applying / completed / failed / cancelled。
- [ ] 每个 `await` 返回后校验 generation ID 与取消状态，防止旧任务回写新 UI。
- [ ] 切换仓库、折叠分区或点击取消时，中止生成且不写库。
- [ ] 生成期间笔记发生变化时阻止强制覆盖，保留草稿并提示重新生成。
- [ ] 保存失败时保留 AI 草稿，支持用户重试。
- [ ] 新增 ViewModel 单元测试，覆盖缓存命中、下载、错误步骤、流式、取消、冲突与保存重试。

## 5. UI 与交互

- [ ] 个人笔记折叠标题行右侧新增 AI 生成入口。
- [ ] 标题行生成期显示紧凑进度：已完成数 / 总步骤、当前步骤和成功 / 失败状态。
- [ ] 展开后显示全量步骤列表，可看见 README 下载的 completed / skipped / failed。
- [ ] 流式草稿单独显示，提供取消、重试、放弃和“使用此草稿”操作。
- [ ] 保留个人笔记折叠标题整行可点击，且不形成嵌套 Button。
- [ ] 所有 `.buttonStyle(.plain)` 的 Button 禁用 focus ring，文字 / 图标仅使用 `.primary` / `.secondary`。
- [ ] 动画遵循 Reduce Motion，步骤状态同时用图标与文字表达，不仅依赖颜色。
- [ ] 不可用时给出稳定解锁原因与辅助功能标签。

## 6. 国际化、测试与验收

- [ ] 新增 en / zh-Hans 国际化 key，保持 `Localizable.xcstrings` 目录编辑与最小 diff。
- [ ] 新增人工验收步骤，覆盖本地 README、下载 README、既有笔记、取消、冲突、失败重试和主题切换。
- [ ] 新增 Swift 关键概念学习索引引用，指向本专项的 `@Observable`、`Task`、`AsyncThrowingStream` 与 SwiftUI 组合位置。
- [ ] 运行专项单测并通过。
- [ ] 运行全量单测并通过。
- [ ] 运行 `xcodegen generate`、构建验证、i18n 静态检查、`git diff --check` 并通过。

## 7. 多轮审查

- [ ] 第一轮：文档、需求边界与 Checklist 完整性审查；先提交报告，再修复发现。
- [ ] 第二轮：代码架构、并发、数据安全与 UI 契约审查；先提交报告，再修复发现。
- [ ] 第三轮：单元测试、失败路径、国际化与构建结果审查；先提交报告，再修复发现。
- [ ] 第四轮：文档、代码、测试、工程进度、Checklist 与提交历史一致性终审；先提交报告，再修复发现。
- [ ] 所有问题关闭后新增最终复审报告和结果报告。

## 8. 提交与受保护文档

- [ ] 每完成一个小功能提交一次，commit message 使用中文且符合项目规范。
- [ ] 不 push，不执行打包、发布或上传脚本。
- [ ] 只读核对 `docs/功能实现总览.md`；未获得单独授权时只在结果报告给出拟同步文案。
- [ ] 未获得单独授权时不修改 App Store / Direct / 官网 Changelog，只在结果报告给出建议。
- [ ] 不带入并行工作产生的无关改动，最终保持本专项文档、代码、测试与提交历史一致。
