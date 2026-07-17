# RepoContext 分片管理审查报告（第 2 轮）

> 日期：2026-07-17
> 范围：UI、功能闭环、编辑删除下载、进度交互、accessibility 与 i18n
> 结论：发现 1 个 P1，先记录报告，待独立提交修复后回填。

## 1. 审查方法

- 从知识库详情逐项走查生成、重新生成、进度、停止、成功、失败、切仓、编辑、删除和下载状态。
- 对照主窗口 AI 摘要进度的 hover / focus 停止交互，检查键盘与鼠标入口。
- 检查 `KnowledgeRAGChunkEditor` 是否复用现有 sheet、保存错误是否阻止关闭、下载是否使用当前草稿。
- 检查所有新增固定文案的 en / zh-Hans、sheet locale、plain button focus ring 和明暗主题颜色。
- 执行 xcstrings JSON 检查、禁用本地化 API 扫描、RepoContext 定向测试和编译。

## 2. 已确认正确

- RepoContext 是元数据后的第二项；编辑复用 `KnowledgeRAGChunkEditor` sheet，没有新增 popover。
- XML 行支持编辑与破坏性删除确认；生成活动期间入口禁用，ViewModel 也有保存/删除兜底 guard。
- 编辑保存失败以内联错误留在 sheet；固定标题与路径、等宽正文符合设计。
- 下载按钮位于 sheet header，使用 `square.and.arrow.down` 与 XML 类型 `NSSavePanel`，导出当前未保存草稿；取消静默返回。
- 主动生成入口会根据现有 XML 显示生成/重新生成；失败后入口恢复可用，可直接重试。
- 三段进度不展示百分比；当前 spinner 在 hover / focus 时变为红色 `stop.circle.fill`，具备 help 与 accessibility label。
- 新增 plain button 均有 `.focusEffectDisabled()`；新增颜色仅使用 `.primary`、`.secondary` 或明确的绿/红状态色。
- 新增固定文案均有 en / zh-Hans；相关 sheet 已挂 `.appLocaleEnvironment()`；禁用本地化 API 未新增命中。

## 3. 发现的问题

### P1：生成成功或失败后切换仓库会把上一仓库的结果提示带到新详情

`selectRepository` 和程序化切仓都会调用 `cancelRepoContextGeneration()`，但该方法当前只在 `isGeneratingRepoContext == true` 时把状态收回 idle。成功和失败都属于非活动状态，因此切换到新仓库后仍会显示上一仓库“已生成 / 已复用”或失败文案，直到用户再次生成。

修复要求：生命周期取消必须无条件清空 RepoContext 生成展示状态；显式停止仍保持立即隐藏。补充状态重置测试或最小纯函数测试，确认 idle、success、failed、cancelled 都能被切仓重置，不影响旧 XML 文件。

## 4. 本轮门禁记录

- `RepoContextStorageTests`：7 项通过。
- `Localizable.xcstrings`：JSON 通过，新增 12 个 key 均具备 en / zh-Hans。
- 禁用本地化 API扫描：本需求文件无 `String(localized:)` / `NSLocalizedString` 命中。
- `Starcat` 编译：随定向测试通过。
- 人工真实大仓下载与 UI 点击尚未执行，本报告不伪造人工验收。

## 5. 修复回填

待修复提交完成后回填。
