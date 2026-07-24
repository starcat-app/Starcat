---
name: starcat-localization-sync
description: Starcat 本地化同步与 String Catalog 维护流程。用于用户要导出或导入 supports/starcat-localization 的 xcloc 语言包、同步 Localizable.xcstrings、批量修补 xcstrings key/value、审计 i18n 规则、维护 18 种语言的 draft/released 门禁、或询问 supports/scripts/starcat-localization.py 与 scripts/xcstrings_patch.py 如何使用的场景。
---

# Starcat 本地化同步

使用这个 skill 处理 Starcat 应用内 `Localizable.xcstrings` 与公开本地化仓库 `supports/starcat-localization` 之间的导出、导入和修补。

## 硬性规则

- 所有说明用中文；命令、路径、locale、key、JSON 字段保持原文。
- 修改本地化文件前先给方案并等确认。
- 新增或修改用户可见文案时，必须同时维护 `en` 和 `zh-Hans`。
- 语言清单与发布状态以 `supports/starcat-localization/locales.json` 为准；`draft` 不等于 App 已支持。
- 只有 `translated`、`final`、`signed-off` 状态可默认导入，禁止把未审核 target 伪装成完成。
- 新增 key 遵守 `{section}.{subsection}.{component}`，不要用 `_`。
- 不使用 `String(localized:)` 或 `NSLocalizedString`；相关代码任务要先读 i18n 规范。
- `.xcstrings` 校验用 `jq empty`，不要只依赖 `plutil`。

## 入口选择

| 任务 | 使用入口 |
|---|---|
| 从应用 String Catalog 导出语言包 | `supports/scripts/starcat-localization.py export` |
| 只导出部分语言 | `supports/scripts/starcat-localization.py export --locale en --locale zh-Hans` |
| 导入单个已审核 `.xcloc` | `supports/scripts/starcat-localization.py import --package <path>` |
| 导入公开仓库全部语言包 | `supports/scripts/starcat-localization.py import-all` |
| 审计包结构、key、占位符、技术字面量和发布门禁 | `supports/scripts/starcat-localization.py audit` |
| 查看 18 种语言完成度 | `supports/scripts/starcat-localization.py report --format json` |
| 为单个 draft locale 生成 AI 初稿 | `python3 supports/starcat-localization/scripts/translate_draft.py --locale <locale> --apply` |
| 单 key 或批量修补 `.xcstrings` | `scripts/xcstrings_patch.py set` / `set-batch` |
| 查询 key 当前值 | `scripts/xcstrings_patch.py show --pattern <pattern>` |

## 标准工作流

1. 读取 `references/localization-map.md`。
2. 只读检查：
   - `git status --short`
   - `jq empty Starcat/Resources/Localizable.xcstrings`
   - `supports/scripts/starcat-localization.py audit`
   - 需要时 `scripts/xcstrings_patch.py show --pattern <pattern>`
3. 说明会修改 `Starcat/Resources/Localizable.xcstrings`、`supports/starcat-localization/Translation Packages/`，还是两者都改。
4. 先 dry-run；`xcstrings_patch.py` 默认 dry-run，只有 `--apply` 才写盘。
5. 等确认后执行写入命令。
6. 写入后验证 JSON、检查 diff，并按 i18n 规范自检。
7. 新语言保持 `draft`，直到翻译审核、自动校验、应用内布局和适用的 RTL 验收全部通过。
8. AI 初稿只能写成 `needs-review-translation`；API Key 只从环境变量读取，不进仓库。
9. 可执行代码块、行内代码和 URL 必须逐字保留；定向重译使用 `--key`，只修复字面量使用 `--repair-protected-literals`。

## 验证

```bash
jq empty Starcat/Resources/Localizable.xcstrings
python3 -m unittest discover -s supports/scripts/tests -p 'test_starcat_localization.py'
python3 supports/starcat-localization/scripts/validate_packages.py
rg "String\\(localized:" --type swift Starcat/
rg "NSLocalizedString" --type swift Starcat/
```

`String(localized:)` 和 `NSLocalizedString` 命中应只出现在注释里。

## 参考

详细命令、文件结构和失败恢复见 `references/localization-map.md`。
