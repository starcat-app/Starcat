# 本地化同步地图

## 单一来源

| 内容 | 路径 |
|---|---|
| 应用运行时字符串目录 | `Starcat/Resources/Localizable.xcstrings` |
| 公开本地化仓库 | `supports/starcat-localization` |
| 语言包目录 | `supports/starcat-localization/Translation Packages/` |
| locale 与发布状态 | `supports/starcat-localization/locales.json` |
| 不翻译 key 白名单 | `supports/starcat-localization/nontranslatable-keys.json` |
| 公开仓库独立校验器 | `supports/starcat-localization/scripts/validate_packages.py` |
| AI 初稿脚本 | `supports/starcat-localization/scripts/translate_draft.py` |
| 导入导出脚本 | `supports/scripts/starcat-localization.py` |
| `.xcstrings` 修补脚本 | `scripts/xcstrings_patch.py` |
| i18n 规范 | `docs/5-规范/国际化-规范.md` 和 `docs/5-规范/i18n-军规.md` |

公开本地化仓库维护“每种语言一个 `.xcloc` 包”。每个包内含同一份 source
snapshot，作为 Xcode 交换格式的一部分；不要在包外另建运行时
`Localizable.xcstrings`。App 的运行时单一来源仍是主仓库中的 String Catalog。

## 导出语言包

```bash
supports/scripts/starcat-localization.py export
supports/scripts/starcat-localization.py export --locale en --locale zh-Hans
```

可用自定义路径：

```bash
supports/scripts/starcat-localization.py \
  --catalog /tmp/Localizable.xcstrings \
  --repo /tmp/starcat-localization \
  export
```

导出只原子替换本次指定的语言包，不会删除其他语言包。旧 target 会被保留；
source 文案变化时，已有 target 会降级为 `needs-review-translation`。

## 导入语言包

导入单个包：

```bash
supports/scripts/starcat-localization.py import \
  --package "supports/starcat-localization/Translation Packages/zh-Hans.xcloc"
```

导入全部包：

```bash
supports/scripts/starcat-localization.py import-all
```

默认只导入 `translated`、`final`、`signed-off` 状态。`import-all` 会先完整
验证所有包，再一次性写回；任一包失败都不会留下部分导入结果。

## 审计与报告

```bash
supports/scripts/starcat-localization.py audit
supports/scripts/starcat-localization.py report
supports/scripts/starcat-localization.py report --format json
python3 supports/starcat-localization/scripts/validate_packages.py
```

主仓库脚本用于导入导出和运行时 Catalog 审计；公开仓库校验器不依赖私有源码，
供贡献者本地与 CI 使用。`draft` 语言允许不完整，`released` 语言必须没有
missing 或 review 文案。

## AI 初稿

```bash
# dry-run：只报告待翻译数量
python3 supports/starcat-localization/scripts/translate_draft.py --locale ja

# 小批试译
python3 supports/starcat-localization/scripts/translate_draft.py \
  --locale ja --limit 40 --apply

# 续跑整包；已有 target 会自动跳过
python3 supports/starcat-localization/scripts/translate_draft.py \
  --locale ja --apply

# 定向重译一个 AI 待审核 key
python3 supports/starcat-localization/scripts/translate_draft.py \
  --locale ja --key settings.mcp.agentSetup.mcpPrompt --apply

# 不调用 API，只恢复被改写的可执行代码、行内代码和 URL
python3 supports/starcat-localization/scripts/translate_draft.py \
  --locale ja --repair-protected-literals --apply
```

脚本从 `DEEPSEEK_API_KEY` 读取凭据，逐批验证 key、空值、占位符、可执行代码块、
行内代码和 URL 并原子写回。`text` fence 中的说明文字允许本地化，但技术标识符
和值不能改写。
所有结果固定为 `needs-review-translation`，不能替代母语审核或 UI/RTL 验收。

## 修补 `.xcstrings`

查询：

```bash
python3 scripts/xcstrings_patch.py show --pattern "uncategorized"
```

单 key 双语修补：

```bash
python3 scripts/xcstrings_patch.py set \
  --key "weekly.filter.allLanguages" \
  --value "All Languages"
```

默认 dry-run。真实写入必须显式加 `--apply`。

只改某个 locale：

```bash
python3 scripts/xcstrings_patch.py set \
  --key "weekly.filter.language" \
  --value "Language" \
  --locales en \
  --apply
```

批量修补：

```bash
python3 scripts/xcstrings_patch.py set-batch \
  --patches /tmp/patches.json \
  --apply
```

`patches.json` 格式：

```json
{
  "weekly.filter.allLanguages": "All Languages",
  "trending.language.uncategorized": "Uncategorized"
}
```

## i18n 自检规则

- SwiftUI `Text` / `Label` / `Button` 直接写 `Text("key")`。
- 返回 `String` 的本地化场景使用 `String.l10n("key")`。
- `.sheet` / `.popover` 根视图和自建 `NSWindow` / `NSPanel` hostingView 根视图挂 `.appLocaleEnvironment()`。
- Foundation formatter 显式注入 SwiftUI `\.locale`。
- 新增 key 同时填 `en` 和 `zh-Hans`。

## 失败恢复

| 问题 | 处理 |
|---|---|
| `.xcstrings` JSON 无效 | 停止，先恢复或修正 JSON，再继续 |
| `xcstrings_patch.py` 报 `MISSING key` | 不要静默新增；确认 key 命名后再决定是否新增 |
| `.xcloc` 缺少 XLIFF | 检查包结构：`Localized Contents/<locale>.xliff` |
| `released locale ... missing/review` | 不要降低门禁；补齐并审核翻译，或保持 `draft` |
| 占位符错误 | 恢复 `%@`、`%1$@`、`%d`、`%%` 等原始 token 后再提交 |
| `stale nontranslatable key` | 删除已经不存在的白名单 key，不要扩大白名单绕过校验 |
| 导入后 diff 过大 | 检查是否导入了错误包或格式化工具改变了整个文件 |
| grep 命中 `String(localized:)` | 只允许注释命中；代码命中要改为 `String.l10n` |
