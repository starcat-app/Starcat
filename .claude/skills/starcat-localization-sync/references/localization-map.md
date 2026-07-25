# 本地化同步地图

## 目录

- [单一来源](#单一来源)
- [状态与责任边界](#状态与责任边界)
- [导出语言包](#导出语言包)
- [AI 初稿](#ai-初稿)
- [维护者接受 AI 初稿](#维护者接受-ai-初稿)
- [导入语言包](#导入语言包)
- [正式发布](#正式发布)
- [审计与报告](#审计与报告)
- [修补 xcstrings](#修补-xcstrings)
- [i18n 自检规则](#i18n-自检规则)
- [失败恢复](#失败恢复)

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
| AI 初稿批准脚本 | `supports/starcat-localization/scripts/promote_drafts.py` |
| 导入导出脚本 | `supports/scripts/starcat-localization.py` |
| `.xcstrings` 修补脚本 | `scripts/xcstrings_patch.py` |
| i18n 规范 | `docs/5-规范/国际化-规范.md` 和 `docs/5-规范/i18n-军规.md` |

公开本地化仓库维护“每种语言一个 `.xcloc` 包”。每个包内含同一份 source
snapshot，作为 Xcode 交换格式的一部分；不要在包外另建运行时
`Localizable.xcstrings`。App 的运行时单一来源仍是主仓库中的 String Catalog。

## 状态与责任边界

### XLIFF target state

| state | 含义 | 默认可导入 |
|---|---|---|
| `needs-translation` / `new` | 尚无译文 | 否 |
| `needs-review-translation` | AI 初稿或 source 改变后待批准 | 否 |
| `translated` | 已批准进入 Catalog | 是 |
| `final` / `signed-off` | 更高等级批准 | 是 |

`translated` 表示“批准导入”，不再隐含“必然由母语人员审核”。批准来源必须另行
记录为 human review 或 maintainer AI acceptance，不能把二者混写。

### locale releaseStatus

| releaseStatus | 含义 |
|---|---|
| `draft` | 不对正式用户开放；可以已有完整并可导入的译文 |
| `released` | Catalog、AppLocale、构建、UI 和 RTL 门禁均通过 |

状态顺序：

```text
AI draft
  -> needs-review-translation
  -> human-reviewed 或 maintainer-ai-accepted
  -> translated
  -> import Catalog
  -> build / AppLocale / UI / RTL
  -> released
```

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

运行时 Catalog 即使已经导入 18 种语言，`.xcloc` 的
`Source Contents/Starcat/Localizable/Localizable.xcstrings` 也只保留
`en` / `zh-Hans` 双语 source 基线；目标语言译文只存放在各自 XLIFF 中，禁止把
同一套 18 语言 target 重复复制进 18 个 source snapshot。重新导出已有包时保留
现有 XLIFF unit 顺序，删除旧 key 只产生删除 diff，新 key 按 Catalog 顺序追加。

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

## 维护者接受 AI 初稿

维护者可以明确承担语义质量风险，跳过母语审核。此决定只豁免 human review，
不自动豁免结构校验、Catalog 编译、应用内布局或 Arabic RTL 验收。

### 工具契约

批量批准必须由专用脚本完成，约定入口：

```bash
# dry-run：报告 locale、候选数、source digest 和阻断项
python3 supports/starcat-localization/scripts/promote_drafts.py --all

# 写入：必须显式声明批准方式
python3 supports/starcat-localization/scripts/promote_drafts.py \
  --all \
  --approval-method maintainer-ai-accepted \
  --approved-by dong4j \
  --apply
```

脚本必须：

1. 只处理 `needs-review-translation`，不覆盖 `translated/final/signed-off`。
2. 写入前运行与公开 validator 相同的结构、占位符和技术字面量校验。
3. 先验证所有目标，再原子写入；任何 locale 失败时不留下部分批准。
4. 在 `locales.json` 写入下文定义的 `translationApproval`。
5. source snapshot 或 target 内容改变后使旧批准失效，并让对应 target 回到 review。
6. 默认不修改 `releaseStatus`，不修改主 Catalog，不修改 `AppLocale`。

如果脚本尚不存在，skill 必须先实施并测试工具，不能退化成 `sed`、正则替换或一次性
Python 命令。

### 批准记录 Schema

每个通过维护者 AI 放行的 locale 使用：

```json
{
  "id": "ja",
  "releaseStatus": "draft",
  "translationApproval": {
    "method": "maintainer-ai-accepted",
    "humanReviewed": false,
    "approvedBy": "maintainer",
    "approvedAt": "ISO-8601 UTC",
    "unitCount": 4149,
    "sourceDigest": "sha256:<hex>",
    "translationDigest": "sha256:<hex>"
  }
}
```

约束：

- `approvedBy` 必须是本次执行者明确提供的非空标识，脚本不得猜测。
- `sourceDigest` 是该 `.xcloc` 内嵌
  `Source Contents/Starcat/Localizable/Localizable.xcstrings` 原始字节的 SHA-256。
- `translationDigest` 按 XLIFF 顺序，对所有非白名单单元依次写入
  `locale + NUL + key + NUL + source + NUL + target + NUL` 的 UTF-8 字节后计算
  SHA-256；它不包含 target state，因此 promotion 前后 digest 保持一致。
- `unitCount` 必须等于参与 digest 的非白名单单元数。
- validator 必须重新计算两个 digest；任一不匹配都拒绝 AI 批准记录。
- `export` 遇到 source 改变，或后续工具改变已批准 target 时，必须删除
  `translationApproval` 并将受影响单元恢复为 `needs-review-translation`。
- `translationApproval` 不改变 `releaseStatus`；正式发布仍走独立门禁。

### 批准后的报告

至少报告：

- locale 列表和每语言提升数量。
- 批准前后的 `translated/review/missing`。
- 批准来源是 `maintainer-ai-accepted`，不是 human review。
- 是否导入 Catalog。
- 仍未执行的 UI/RTL 和正式发布门禁。

## 导入语言包

导入单个包：

```bash
python3 supports/scripts/starcat-localization.py import \
  --package "supports/starcat-localization/Translation Packages/zh-Hans.xcloc"
```

导入全部包：

```bash
python3 supports/scripts/starcat-localization.py import-all
```

默认只导入 `translated`、`final`、`signed-off` 状态。`import-all` 会先完整
验证所有包，再一次性写回；任一包失败都不会留下部分导入结果。

只有实际存在变更时，导入脚本才会在写入前把原始 Catalog 按字节备份到
`supports/backups/localization/`，文件名包含 UTC 时间和原文件 SHA-256 前缀。
该目录已被 Git 忽略，命令会输出真实备份路径，脚本不会自动删除历史备份。
需要恢复时，先停止后续导入，再把对应 `.bak` 原样复制回
`Starcat/Resources/Localizable.xcstrings` 并运行 `jq empty` 与 `audit`。

`--allow-unreviewed` 只允许临时 UI 调试；它保持 review 状态，不得据此提升
`releaseStatus`。

## 正式发布

翻译批准和 Catalog 导入完成后，仍需：

1. 扩展 `Starcat/Core/Settings/LocaleStore.swift` 的 `AppLocale`。
2. 为每种语言配置母语显示名、BCP-47 identifier 和 AI 输出语言映射。
3. 验证跟随系统、手动切换、sheet/popover/AppKit window 和 formatter。
4. 验证构建产物中的 `.lproj`。
5. 对 `zh-Hant` 验证 script/region；对 `ar` 验证 RTL 和 bidi。
6. 最后才把 `locales.json` 的目标语言改为 `released`。

只修改 XLIFF state 或 `releaseStatus` 都不构成完整发布。

## 审计与报告

```bash
python3 supports/scripts/starcat-localization.py audit
python3 supports/scripts/starcat-localization.py report
python3 supports/scripts/starcat-localization.py report --format json
python3 supports/starcat-localization/scripts/validate_packages.py
```

主仓库脚本用于导入导出和运行时 Catalog 审计；公开仓库校验器不依赖私有源码，
供贡献者本地与 CI 使用。`draft` 语言允许不完整或仅完成翻译批准；`released`
语言必须零 missing、零 review，并完成运行时门禁。

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
| Catalog 导入结果需回退 | 从命令输出的 `supports/backups/localization/*.bak` 恢复，再运行 `jq empty` 与 `audit` |
| `xcstrings_patch.py` 报 `MISSING key` | 不要静默新增；确认 key 命名后再决定是否新增 |
| `.xcloc` 缺少 XLIFF | 检查包结构：`Localized Contents/<locale>.xliff` |
| `released locale ... missing/review` | 不要降低门禁；补齐并审核翻译，或保持 `draft` |
| 占位符错误 | 恢复 `%@`、`%1$@`、`%d`、`%%` 等原始 token 后再提交 |
| 用户要求跳过人工审核 | 记录 `maintainer-ai-accepted`，使用 promotion 工具，保持 `draft` |
| promotion 工具不存在 | 先实现脚本、测试和 validator 规则，不做全局 XML 替换 |
| 批准来源与 source digest 不匹配 | 旧批准失效，目标回到 `needs-review-translation` |
| `stale nontranslatable key` | 删除已经不存在的白名单 key，不要扩大白名单绕过校验 |
| 导入后 diff 过大 | 检查是否导入了错误包或格式化工具改变了整个文件 |
| grep 命中 `String(localized:)` | 只允许注释命中；代码命中要改为 `String.l10n` |
