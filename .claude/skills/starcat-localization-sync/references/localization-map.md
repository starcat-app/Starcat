# 本地化同步地图

## 单一来源

| 内容 | 路径 |
|---|---|
| 应用运行时字符串目录 | `Starcat/Resources/Localizable.xcstrings` |
| 公开本地化仓库 | `supports/starcat-localization` |
| 语言包目录 | `supports/starcat-localization/Translation Packages/` |
| 导入导出脚本 | `supports/scripts/starcat-localization.py` |
| `.xcstrings` 修补脚本 | `scripts/xcstrings_patch.py` |
| i18n 规范 | `docs/5-规范/国际化-规范.md` 和 `docs/5-规范/i18n-军规.md` |

公开本地化仓库只维护“每种语言一个 `.xcloc` 包”，不要把完整 `Localizable.xcstrings` 提交到公开本地化仓库。

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

导出会重建 `Translation Packages/`。

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

导入会把 XLIFF target 写回 `Localizable.xcstrings`，并把 state 设为 `translated`。

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
| 导入后 diff 过大 | 检查是否导入了错误包或格式化工具改变了整个文件 |
| grep 命中 `String(localized:)` | 只允许注释命中；代码命中要改为 `String.l10n` |
