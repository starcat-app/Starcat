---
name: starcat-localization-sync
description: Starcat 本地化生产、同步与发布门禁流程。用于同步 Localizable.xcstrings 与 supports/starcat-localization 的 xcloc、生成或修复 AI 初稿、人工审核或维护者明确接受 AI 翻译、导入已批准翻译、审计 18 种语言、调整 draft/released、扩展 AppLocale，以及排查 key、状态、占位符、技术字面量、UI 或 RTL 问题。
---

# Starcat 本地化同步

处理 Starcat 运行时 String Catalog 与公开本地化仓库之间的完整生命周期。先读
`references/localization-map.md`，再按本文件选择执行路径。

## 核心模型

始终区分四个阶段，不得用后一个阶段的状态掩盖前一个阶段缺失的证据：

| 阶段 | 含义 | 允许结果 |
|---|---|---|
| AI 初稿 | 机器翻译完成，尚未批准 | `needs-review-translation` |
| 翻译批准 | 人工审核，或维护者明确接受 AI 风险 | `translated` / `final` / `signed-off` |
| 导入 Catalog | 已批准 target 写回 App | locale 仍可保持 `draft` |
| 正式发布 | 编译、AppLocale、UI 和 RTL 门禁通过 | `releaseStatus=released` |

“翻译批准”不等于“正式发布”。维护者跳过母语审核时，也不能自动跳过 UI、编译和
Arabic RTL 验收。

## 硬性规则

- 所有说明使用中文；命令、路径、locale、key、JSON 字段保持原文。
- 写入前先给出范围、状态变化和验证方案，等用户确认。
- 运行时单一来源是 `Starcat/Resources/Localizable.xcstrings`；公开协作单一来源是
  `supports/starcat-localization/Translation Packages/`。
- `supports/starcat-localization` 是独立 Git 仓库；分别检查、提交和回滚，不混入
  Starcat 主仓库 commit。
- 新增或修改用户可见文案时，同时维护 `en` 和 `zh-Hans`。
- 新增 key 使用 `{section}.{subsection}.{component}`，禁止 `_`。
- AI 生成只能写 `needs-review-translation`。
- 默认只导入 `translated`、`final`、`signed-off`；禁止普通流程使用
  `--allow-unreviewed`。
- 可执行代码块、行内代码、URL 和占位符必须逐字保留。
- `.xcstrings` 只做局部编辑；用 `jq empty` 校验，禁止用 formatter 重写全文。
- 不使用 `String(localized:)` 或 `NSLocalizedString`；Swift 代码任务先读 i18n 规范。
- 未观察到的母语质量、UI 或 RTL 验收不得写成已完成。

## 任务路由

| 用户目标 | 入口 |
|---|---|
| 同步最新 key/source | `python3 supports/scripts/starcat-localization.py export` |
| 查看完成度 | `python3 supports/scripts/starcat-localization.py report --format json` |
| 审计包和发布门禁 | `python3 supports/scripts/starcat-localization.py audit` |
| 生成/续跑 AI 初稿 | `python3 supports/starcat-localization/scripts/translate_draft.py` |
| 定向重译 | `translate_draft.py --key <key> --apply` |
| 恢复技术字面量 | `translate_draft.py --repair-protected-literals --apply` |
| 人工审核后导入 | `starcat-localization.py import` / `import-all` |
| 维护者接受 AI 初稿 | `python3 supports/starcat-localization/scripts/promote_drafts.py` |
| 正式开放语言 | 先导入，再扩展 `AppLocale`，最后提升 `releaseStatus` |
| 修补已有 `.xcstrings` | `scripts/xcstrings_patch.py show/set/set-batch` |

## 通用执行顺序

1. 只读检查：
   - `git status --short`
   - `git -C supports/starcat-localization status --short`
   - `jq empty Starcat/Resources/Localizable.xcstrings`
   - `python3 supports/scripts/starcat-localization.py audit`
   - `python3 supports/scripts/starcat-localization.py report --format json`
2. 明确本次只改哪一层：
   - 公开 `.xcloc`
   - 主 Catalog
   - `locales.json`
   - `AppLocale`
3. 先 dry-run；如果命令没有 dry-run，先缩小到单 locale 并明确告知会直接写入。
4. 写入后运行对应测试、validator、`git diff --check` 和状态报告。
5. 报告自动化证据与仍未执行的人工/UI 门禁。

## 维护者 AI 放行

只有用户明确表示“跳过人工审核并接受 AI 翻译风险”时才进入此路径。

执行前必须满足：

1. 目标 locale 均为 `draft`，且 target 仍是 `needs-review-translation`。
2. `missing=0`，key/source snapshot 一致。
3. 占位符、可执行代码、行内代码、URL 和状态校验全部通过。
4. 使用专用、默认 dry-run、原子写入的 promotion 脚本。
5. 在 `locales.json` 对应 locale 的 `translationApproval` 记录批准来源，明确
   `humanReviewed=false`，并绑定当前 source snapshot 与实际 target 内容；任一内容
   改变时旧批准必须失效。字段和 digest 算法见 reference。

`--all` 必须从 `locales.json` 动态选择满足条件的 `draft` locale，不得把 16 种语言
硬编码进脚本，也不得包含已经 `released` 的 `en` / `zh-Hans`。

若未来检出缺少 `supports/starcat-localization/scripts/promote_drafts.py`：

- 不要用临时脚本、正则或 XML 全局替换伪造批量批准。
- 先提出并实现该脚本、回归测试、validator 规则和文档同步。
- promotion 工具通过验证后，再单独请求执行当前翻译状态提升。

批准完成后默认只做：

- `needs-review-translation` → `translated`
- 写入真实批准来源，例如 `maintainer-ai-accepted`
- 保持 `releaseStatus=draft`

只有用户另行明确要求正式发布，才继续导入 Catalog、扩展 `AppLocale` 和提升
`releaseStatus`。

## 正式发布门禁

对每个待发布 locale 逐项确认：

- `translated + review + missing` 中只有 `translated` 非零。
- 导入后的 Catalog 含目标 locale，构建产物包含对应 `.lproj`。
- `AppLocale` 包含目标 BCP-47 identifier、母语显示名和 AI 输出语言映射。
- 跟随系统与手动切换均正确。
- 主窗口、sheet、popover、AppKit window、日期和数字格式通过检查。
- `zh-Hant` script/region 行为正确。
- `ar` 完成 RTL、双向文本、箭头、代码和 URL 局部 LTR 验收。

未满足这些条件时保持 `draft`，不能只改 `locales.json` 绕过门禁。

## 验证

```bash
python3 -m unittest discover -s supports/scripts/tests -p 'test_*.py'
python3 -m unittest discover -s supports/starcat-localization/tests -p 'test_*.py'
python3 supports/starcat-localization/scripts/validate_packages.py
python3 supports/scripts/starcat-localization.py audit
jq empty Starcat/Resources/Localizable.xcstrings
rg "String\\(localized:" --type swift Starcat/
rg "NSLocalizedString" --type swift Starcat/
git diff --check
git -C supports/starcat-localization diff --check
```

`String(localized:)` 和 `NSLocalizedString` 只允许命中解释性注释。

## 参考

详细命令、状态转换、维护者放行契约、失败恢复和交付模板见
`references/localization-map.md`。
