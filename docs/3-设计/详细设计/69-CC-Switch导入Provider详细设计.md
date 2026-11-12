# 69 — 从 CC Switch 导入 AI Provider 详细设计

> 日期：2026-09-13
> 状态：导入入口、预览与解析器已有实现；2026-11-12 核对源码，旧实施拆分不再表示待开工
> 适用版本：dev 后续功能迭代（不改已发布 schema）
> 关联：`15-AI设置与调用链重构方案.md`、`68-Anthropic服务商详细设计.md`
> 上游：https://github.com/farion1231/cc-switch （本机库默认 `~/.cc-switch/cc-switch.db`）

---

## 1. 原问题与当前实现

用户在 CC Switch 维护的供应商配置原先需要手工重复录入。当前 `AISettingsView` 已有 CC Switch 导入入口和预览 Sheet；`CCSwitchConfigStore` 只读打开 SQLite，或解析 SQL dump 中的 Provider 数据，不执行备份文件里的任意 SQL。

目标：在 AI 设置页提供一次性导入。只导入能被 Starcat 调用的 BYOK Profile（OpenAI 兼容，以及已接入的 Anthropic Messages）。永远新增，不覆盖现有 Profile。

源码入口：`Starcat/Features/Settings/AISettingsView.swift` 和 `Starcat/Features/Settings/CCSwitchImport/`。当前 mapper 已能识别 Claude / Anthropic 路径并映射协议；不能因读取到一行配置就宣称它可调用，仍需保留跳过原因与连接测试结果。本次未读取用户真实 CC Switch 数据库，也未补签真实凭据导入验收。

## 2. 已冻结决策

| 项 | 决策 |
|---|---|
| 导入目标 | Starcat「设置 → AI」的 `AIProviderProfile` + Keychain，给摘要 / Chat / RAG 用 |
| 范围 | 凡带 API Key 的 CC Switch `providers` 行都尝试；能映射才进预览；其余跳过并写原因 |
| 命名 | 显示名 = `cc-switch: ` + 原名（冒号后一个空格）。重名则 `cc-switch: DeepSeek 2` |
| 冲突 | **永远新增**新 UUID。不覆盖已有 Key / URL / 模型 / 任务绑定 |
| 预览 | 确认前不写 Key。可导项默认全选；跳过项只展示 |
| 测试 | 确认后对勾选项串行跑现有 `/models`（Anthropic 则走文档 68 的 listModels）。成功进正式列表；失败保留未验证 Profile |
| Direct | 先读默认路径；失败再弹 `NSOpenPanel` |
| App Store | 一律 `NSOpenPanel`。说明里写 **真实用户家目录** 下的默认路径，不用沙盒容器路径 |
| 文件类型 | `.db` / `.sqlite` / `.sql`（CC Switch 官方 SQL 备份） |
| 不做 | MCP / Skills / Prompt / OAuth 官方登录 / 与 CC Switch 双向同步 / 监视 db |

## 3. 明确不做

- 不覆盖用户已经配好的 DeepSeek 等同名或同类型 Profile。
- 不导入 Google Official / Claude Official / OpenAI Official / GitHub Copilot 等无 Key 或代理注入 OAuth。
- 不把 Anthropic URL 强行映射成 OpenAI；使用现有 Anthropic adapter，无法匹配的协议保留跳过原因。
- 不读 CC Switch 的代理接管占位符 Key（见 §7.3）。
- 不新增表、不做 CloudKit 同步 Key。
- 不改 `功能实现总览.md`（需 dong4j 另行确认）。

## 4. 当前实现锚点

| 锚点 | 用途 |
|---|---|
| `AIProviderProfile` / `AIServiceProvider` | 写入目标 |
| `KeychainManager.loadAIKey` / `persistAPIKey`（`AISettingsView`） | Key 落盘，按 **新 profile.id** |
| `AISettingsView.testAndFetchModels` | 导入后复用，不要复制一份测试实现 |
| `AIClientFactory` | 测试走工厂；`.anthropic` 是否可用决定 Claude 行能否导入 |
| `DistributionChannel.current.isDirect` | 是否先探测默认路径 |
| `Starcat.entitlements` `com.apple.security.files.user-selected.read-write` | App Store 选择器已具备 |
| `StarcatDirect.entitlements` 无沙盒 | Direct 可直接读 `~/.cc-switch/` |
| GRDB | 只读打开外部 SQLite，不要写进用户主库 |

CC Switch `providers` 表（上游 `schema.rs`，2026-09 仍为此结构）：

```sql
PRIMARY KEY (id, app_type)
-- 列：id, app_type, name, settings_config, website_url, category,
--     created_at, sort_index, notes, icon, icon_color, meta, is_current, in_failover_queue
```

`settings_config` 是 JSON，按 `app_type` 形状不同。

## 5. 架构

```text
用户点「从 CC Switch 导入」
        │
        ├─ Direct：存在且可读 ~/.cc-switch/cc-switch.db ？
        │     是 → 解析
        │     否 → NSOpenPanel
        └─ App Store → NSOpenPanel（message 含真实默认路径）
                │
                ▼
        CCSwitchConfigStore.open(url)   // sqlite 或 sql dump
                │
                ▼
        CCSwitchProviderMapper.map(rows, anthropicAvailable:)
                │
                ▼
        预览 Sheet（勾选 / 跳过原因）
                │ 用户确认
                ▼
        为每条勾选项：
           1. 分配 UUID，displayName 加前缀并去重
           2. 写入 aiProviderProfiles（isEnabled=false, lastTestStatus=.notTested）
           3. Keychain 存 Key
           4. 调用现有 testAndFetchModels
           5. 成功则 isEnabled=true 且 lastTestStatus=.success
                │
                ▼
        同一 Sheet 切到结果（成功 / 失败 / 跳过）
```

全部逻辑放在独立类型里，`AISettingsView` 只负责按钮、Sheet 状态和调用 `testAndFetchModels`。禁止把 SQL / JSON 解析写进 View。

## 6. 入口 UI

位置：`AISettingsView` Provider 工具行，现有 `+` **左侧**（或 `+` 与删除之间偏左），避免破坏「+ 是新增草稿唯一入口」的注释约定。导入不是草稿模式，不设置 `draftProfile`。

- 按钮：`Label("settings.ai.provider.importCCSwitch", systemImage: "square.and.arrow.down")`，`.labelStyle(.iconOnly)`，`.buttonStyle(.plain)` + `.focusEffectDisabled()`，尺寸与 `+` 相同（28×28）。
- `.help` / `accessibilityLabel` 用同一 i18n key 的 Hint 变体。
- `draftProfile != nil` 或正在测试时禁用（与 `+` 一致）。
- 本按钮是 icon-only 工具，不是「设置页独立操作按钮必须右对齐」那类 Section 内 Button；跟现有 `+` / 删除同一 `HStack` 即可。

Sheet：内容为单列清单 + 底部操作，走 **自动 SwiftUI `.sheet`**（文档 `UI-Sheet-尺寸与承载规范.md` §2），不要固定 AppKit 工作台。根视图必须 `.appLocaleEnvironment()`。右上角 `SheetCloseButton`。

建议宽度：表单自然宽度；清单用 `List` 或 `ScrollView`，行数按本机库通常 < 50，可接受。

## 7. 读文件

### 7.1 默认路径

真实家目录（**禁止**用沙盒 `NSHomeDirectory()` / `FileManager.homeDirectoryForCurrentUser`）：

```swift
enum POSIXHome {
    static var directory: URL? {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }
}

// ~/.cc-switch/cc-switch.db
POSIXHome.directory?
    .appendingPathComponent(".cc-switch", isDirectory: true)
    .appendingPathComponent("cc-switch.db")
```

App Store 提示必须用这个 URL 的 `path`（例如 `/Users/dong4j/.cc-switch/cc-switch.db`）。若用容器路径，用户会去错误目录找文件。

Direct：`FileManager.isReadableFile` 该路径则直接打开；不可读再 panel。

### 7.2 NSOpenPanel

```swift
panel.canChooseFiles = true
panel.canChooseDirectories = false
panel.allowsMultipleSelection = false
panel.message = String.l10n("settings.ai.provider.importCCSwitch.panelMessage")
// panelMessage 内插真实路径；en / zh-Hans 都要含完整 path
```

允许扩展名：`db`、`sqlite`、`sqlite3`、`sql`。不要限制成单一 UTType 导致 SQL 备份选不中。

选择器打开后，message 额外提示可用「前往文件夹」（⇧⌘G）粘贴该路径。App Store 沙盒无法自己 cd 到 `~/.cc-switch`。

### 7.3 打开策略

`CCSwitchConfigStore`：

1. 读文件头 16 字节。若是 `SQLite format 3\0`，按 SQLite 打开。
2. 否则按 UTF-8 文本解析 SQL dump。
3. 打开 SQLite 时：

```swift
var config = Configuration()
config.readonly = true
let db = try DatabaseQueue(path: url.path, configuration: config)
```

只执行：

```sql
SELECT id, app_type, name, settings_config, meta
FROM providers
```

表不存在 → 明确错误「不是 CC Switch 数据库」。不要 `SELECT *` 把无关列打进内存日志。

4. SQL dump：只提取 `INSERT INTO providers` / `INSERT INTO "providers"` 行。用最小 SQL 值解析器拆列（处理单引号转义 `''`），按建表列序对齐。解析失败 → 提示「请改选 cc-switch.db，不要选无法识别的 .sql」。
5. 整个过程只读。失败不写 Starcat 任何状态。

### 7.4 跳过损坏行

单行 `settings_config` JSON 坏掉：该行 skip，原因 `settings_config 不是合法 JSON`，不影响其他行。

## 8. 凭据抽取

实现 `CCSwitchCredentialExtractor.extract(appType:settings:meta:)` → `(baseURL: String, apiKey: String, protocolHint: ProtocolHint)`。

与上游 `Provider::resolve_usage_credentials` 对齐（`src-tauri/src/provider.rs`）：

| `app_type` | apiKey 来源（取第一个非空） | baseURL |
|---|---|---|
| `claude` / `claude_desktop` | `env.ANTHROPIC_AUTH_TOKEN`、`ANTHROPIC_API_KEY`、`OPENROUTER_API_KEY`、`GOOGLE_API_KEY` | `env.ANTHROPIC_BASE_URL` |
| `codex` | `auth.OPENAI_API_KEY`，否则从 `config` TOML 抽 token | TOML `config` 里的 `base_url` / `[model_providers.*.base_url]` |
| `gemini` | `env.GEMINI_API_KEY`、`GOOGLE_API_KEY` | `env.GOOGLE_GEMINI_BASE_URL` |
| `opencode` | `options.apiKey` | `options.baseURL` |
| `openclaw` | `apiKey` | `baseUrl` |
| `hermes` | `api_key` | `base_url` |
| `grokbuild` | TOML `config` 凭据 | TOML `base_url` |
| 其他未知 | 尝试扁平 `apiKey`/`api_key` + `baseURL`/`base_url` | 同左 |

Codex TOML 没有标准库。用正则抽第一处：

- `base_url\s*=\s*"(.*?)"`
- `experimental_bearer_token\s*=\s*"(.*?)"`（Codex 0.149+ 密钥可能在 provider 表而不在 auth）

抽不到 Key 则 skip。

### 8.1 必须 skip 的身份

`meta` JSON（或列 `meta`）：

- `provider_type` ∈ `codex_oauth`、`xai_oauth`、`github_copilot`
- `uses_managed_account_auth` 一类布尔若存在且为 true
- 名称精确匹配（忽略大小写）：`Claude Official`、`OpenAI Official`、`Google Official`

Key 看起来是占位符则 skip：`PROXY_TOKEN_PLACEHOLDER`、空串、少于 8 个可见字符、全 `*`。

原因文案 key：`settings.ai.provider.importCCSwitch.skip.noKey` / `.oauth` / `.placeholder`。

## 9. 协议映射

输入：`(appType, baseURL, apiKey)` + `anthropicAvailable: Bool`。

`anthropicAvailable` = `AIServiceProvider` 能构造 `.anthropic` 且 `AIClientFactory` 不会把它送进 `OpenAIClient`。实现写成：

```swift
static var isAnthropicAdapterAvailable: Bool {
    // 文档 68 合入后 rawValue 存在；用 allCases 探测，避免 69 单独合入时编译失败。
    AIServiceProvider.allCases.contains { $0.rawValue == "anthropic" }
}
```

若 68 与 69 同 PR，可直接 `.anthropic`。分 PR 时必须用 rawValue 探测或 `#if` 都不需要——没有该 case 时 `allCases` 不含它，Claude 行走 skip。

### 9.1 判定顺序

1. `baseURL` 为空 → skip `缺少 Base URL`。
2. 若 `anthropicAvailable` 且（`appType` 是 claude / claude_desktop **或** path 含 `/anthropic`）→ **类型 `.anthropic`，URL 只做 trim / 去尾 `/`，不改写 path**。
3. 否则走 OpenAI 兼容映射（§9.2）。
4. 仍无法映射 → skip `Starcat 目前无法调用该协议`（key `settings.ai.provider.importCCSwitch.skip.unsupportedProtocol`）。

Gemini 官方 URL（`generativelanguage.googleapis.com`）无 OpenAI 兼容层 → skip。若用户把 Gemini 配成 OpenAI 兼容中转（path 含 `/v1`），走 §9.2。

### 9.2 OpenAI 兼容：host 对照表

将 URL host（小写，去掉前导 `www.`）对到 `AIServiceProvider`。命中后 **Base URL 用该 case 的 `defaultBaseURL`**，不要沿用 `/anthropic` path。

| host 后缀或相等 | `AIServiceProvider` |
|---|---|
| `api.openai.com` | `.openAICompatible` |
| `api.deepseek.com` | `.deepSeek` |
| `openrouter.ai` | `.openRouter` |
| `localhost` 且 port `11434` | `.ollama` |
| `127.0.0.1` 且 port `11434` | `.ollama` |
| `localhost` / `127.0.0.1` 且 port `1234` | `.lmStudio` |
| `integrate.api.nvidia.com` | `.nvidia` |
| `router.huggingface.co` | `.huggingface` |
| `api.mistral.ai` | `.mistral` |
| `ark.cn-beijing.volces.com` | `.doubao` |
| `api.x.ai` | `.grok` |
| `api.hunyuan.cloud.tencent.com` | `.hunyuan` |
| `api.moonshot.cn` / `api.moonshot.ai` | `.moonshot` |
| `dashscope.aliyuncs.com` | `.qianwen` |
| `api.siliconflow.cn` | `.siliconflow` |
| `apis.iflow.cn` | `.iflow` |
| `api-inference.modelscope.cn` | `.modelscope` |
| `open.bigmodel.cn` | `.zhipu` |
| `api.z.ai` | `.zai` |
| `api.orcarouter.ai` | `.orcaRouter` |
| `models.github.ai` | `.githubModels` |

host 未命中时：

- path 包含 `/v1`、`/compatible-mode`、`/openai` → `.openAICompatible`，**保留原 URL**（只去尾 `/`）。
- 否则 skip（无法猜测 OpenAI path）。

不要把 `api.deepseek.com/anthropic` 在 Anthropic adapter 已可用时改写成 `api.deepseek.com`。那是第 2 步已经收走的 Anthropic 入口。仅当 `anthropicAvailable == false` 时，DeepSeek 的 `/anthropic` 才允许改写成 `.deepSeek` + `https://api.deepseek.com`（用户至少能用 OpenAI 兼容口；测不通再在结果里失败）。

### 9.3 预览行模型

```swift
struct CCSwitchImportCandidate: Identifiable, Equatable {
    var id: String              // "\(appType)|\(sourceID)" 仅用于 List，不是 Starcat profile id
    var sourceName: String
    var displayName: String     // 已加前缀，尚未做 2/3 去重
    var provider: AIServiceProvider
    var baseURL: String
    var apiKey: String          // 只在内存，确认后写入 Keychain，不进日志
    var appType: String
    var skipReason: String?     // nil = 可导
}

struct CCSwitchImportPreview {
    var sourcePath: String
    var importable: [CCSwitchImportCandidate]
    var skipped: [CCSwitchImportCandidate] // skipReason 非 nil
}
```

UI 展示 Key：`"••••" + apiKey.suffix(4)`，长度不足 4 则全部掩码。

## 10. 确认写入

对每个勾选的 importable：

1. `displayName` 在 `settings.aiProviderProfiles.map(\.displayName)` 中大小写敏感查重。冲突则追加空格 + 从 2 起的整数，直到唯一：`cc-switch: DeepSeek` → `cc-switch: DeepSeek 2`。
2. `AIProviderProfile(id: UUID().uuidString, provider:provider, displayName:displayName, baseURL:baseURL, isEnabled:false, models:[], lastTestStatus:.notTested)`。
3. append 到 `settings.aiProviderProfiles`。
4. 调与设置页相同的 `persistAPIKey`（允许空 Key 仅对 ollama/lmStudio；导入路径若 Key 为空本就不会进 importable）。
5. **不要**设置 `draftProfile`。
6. 调用 `await testAndFetchModels(profile)`。该方法已会在成功时 `isEnabled = true` 并 merge 模型。确认它接受「已在 profiles 数组中的未验证项」——读现实现：成功分支写回 `settings.aiProviderProfiles` 里同 id 项。若当前实现只提升 `draftProfile`，导入路径要走「已存在 id」分支，允许小改 `testAndFetchModels`：以 `profile.id` 查找 draft **或** 数组中的项再写回。这是本方案允许的唯一设置页行为改动。
7. 串行：上一条测试结束（成功或失败）再开始下一条。禁止并发打 `/models`。
8. 用户点 Sheet 关闭 / 取消测试：`Task.cancel()`；已写入的 Profile 保留；未开始测试的保持 `.notTested`。结果区标明「已取消」。

失败项：Key 与 Profile 已在，用户可在设置页改 URL 后手动再测。不要自动删除失败项。

## 11. 结果 UI

同一 Sheet 两态：`preview` / `progress` / `result`。

- `progress`：`ProgressView` + `当前 N / 合计 M` + 当前 displayName。
- `result`：三组数字成功 / 失败 / 跳过。失败行显示 `lastTestStatus.displayText`。按钮「完成」关 Sheet。
- 失败行可选「选择该服务商」：`setSelectedProfileID(id)` 后关 Sheet。

关闭按钮在 progress 期间仍可用（取消）。

## 12. 安全

- `AppLog` 只记 `app_type`、displayName、provider rawValue、是否成功。禁止记 Key、禁止记完整 settings_config。
- 预览 List 的 `apiKey` 不进 `CustomStringConvertible`。DEBUG dump 先 redact。
- 只读打开 CC Switch 库；不写回、不改 `is_current`。
- App Store 只能读用户选中的文件；默认路径仅用于文案。

## 13. 文件清单

新增：

| 文件 | 职责 |
|---|---|
| `Starcat/Features/Settings/CCSwitchImport/CCSwitchConfigStore.swift` | 打开 sqlite / sql dump |
| `Starcat/Features/Settings/CCSwitchImport/CCSwitchCredentialExtractor.swift` | 按 app_type 抽 Key / URL |
| `Starcat/Features/Settings/CCSwitchImport/CCSwitchProviderMapper.swift` | 协议映射、skip 原因、前缀 |
| `Starcat/Features/Settings/CCSwitchImport/CCSwitchImportPreviewSheet.swift` | Sheet UI |
| `Starcat/Features/Settings/CCSwitchImport/POSIXHome.swift` | getpwuid 家目录 |
| `StarcatTests/CCSwitchProviderMapperTests.swift` | 映射表、前缀去重、skip |
| `StarcatTests/CCSwitchCredentialExtractorTests.swift` | 各 app_type fixture |
| `StarcatTests/CCSwitchConfigStoreTests.swift` | 临时 sqlite fixture + 非法文件 |
| `StarcatTests/POSIXHomeTests.swift` | 路径以 `/Users/` 或 `/var/` 开头且不含 `Containers` |

修改：

| 文件 | 改动 |
|---|---|
| `Starcat/Features/Settings/AISettingsView.swift` | 按钮、sheet 状态、确认循环里调测试 |
| `Starcat/Resources/Localizable.xcstrings` | 下列 key，**按行插入**，en + zh-Hans |
| `project.yml` | 通常通配；新增文件后 `xcodegen generate` |

### i18n keys

| key | en | zh-Hans |
|---|---|---|
| `settings.ai.provider.importCCSwitch` | Import from CC Switch | 从 CC Switch 导入 |
| `settings.ai.provider.importCCSwitch.help` | Import providers from the CC Switch database | 从 CC Switch 数据库导入服务商 |
| `settings.ai.provider.importCCSwitch.panelMessage` | Default database: %@  Use Shift-Command-G to paste this path. | 默认数据库：%@。可按 ⇧⌘G 粘贴该路径。 |
| `settings.ai.provider.importCCSwitch.sheetTitle` | Import from CC Switch | 从 CC Switch 导入 |
| `settings.ai.provider.importCCSwitch.confirm` | Import Selected | 导入所选 |
| `settings.ai.provider.importCCSwitch.skippedSection` | Skipped | 已跳过 |
| `settings.ai.provider.importCCSwitch.skip.noKey` | No API key | 没有 API Key |
| `settings.ai.provider.importCCSwitch.skip.oauth` | OAuth login cannot be imported | OAuth 登录无法导入密钥 |
| `settings.ai.provider.importCCSwitch.skip.placeholder` | Placeholder token | 占位密钥，已跳过 |
| `settings.ai.provider.importCCSwitch.skip.unsupportedProtocol` | Starcat cannot call this protocol yet | Starcat 目前无法调用该协议 |
| `settings.ai.provider.importCCSwitch.skip.badJSON` | Invalid settings_config JSON | settings_config 不是合法 JSON |
| `settings.ai.provider.importCCSwitch.result.success` | Imported | 已导入 |
| `settings.ai.provider.importCCSwitch.result.failed` | Test failed | 测试失败 |
| `settings.ai.provider.importCCSwitch.result.cancelled` | Cancelled | 已取消 |
| `settings.ai.provider.importCCSwitch.error.notCCSwitch` | This file is not a CC Switch database | 这不是 CC Switch 数据库 |
| `settings.ai.provider.importCCSwitch.error.openFailed` | Could not open the file | 无法打开文件 |

Catalog 禁止 StrReplace 整文件写回。实现阶段用 Xcode 或按行插入。

## 14. 实施顺序

1. `POSIXHome` + 单测。
2. `CCSwitchConfigStore`：用测试 fixture 建临时 sqlite（`providers` 最小列）+ 一份假 SQL dump。
3. `CCSwitchCredentialExtractor` fixture：claude env、codex auth+toml、opencode options、oauth skip。
4. `CCSwitchProviderMapper`：host 表、anthropic 开关真/假两条、前缀去重。
5. Sheet UI + `AISettingsView` 按钮。
6. 确认循环接到 `testAndFetchModels`（必要时改写回分支）。
7. Direct 手测默认路径；App Store 包手测选择器文案路径不含 `Containers`。

```bash
make test TEST_ARGS="-only-testing:StarcatTests/CCSwitchProviderMapperTests -only-testing:StarcatTests/CCSwitchCredentialExtractorTests -only-testing:StarcatTests/CCSwitchConfigStoreTests -only-testing:StarcatTests/POSIXHomeTests"
```

## 15. 测试契约

### Mapper

- `https://api.deepseek.com/anthropic` + anthropicAvailable true → `.anthropic`，URL 仍含 `/anthropic`。
- 同上 + false → `.deepSeek`，URL `https://api.deepseek.com`。
- Codex MiniMax 带 openai base_url → `.openAICompatible` 或 host 表命中。
- `Claude Official` 无 Key → skipped oauth。
- 显示名去重：已有 `cc-switch: DeepSeek` → 新的变成 `cc-switch: DeepSeek 2`。
- 已有手工 `DeepSeek` 不影响导入 `cc-switch: DeepSeek`（不是覆盖）。

### Store

- 最小合法 sqlite 读出 2 行。
- 空文件、PNG 头、缺表 → `notCCSwitch`。
- SQL dump 含一条 INSERT providers → 读出 name。

### Extractor

- claude env 只填 `ANTHROPIC_AUTH_TOKEN`。
- 空 token 有 `ANTHROPIC_API_KEY` 则用后者。
- Codex 只有 toml bearer、auth 为空。

禁止测试 fixture 使用真实用户 Key。用 `sk-test-xxxx`。

## 16. 验收

- Direct：本机已装 CC Switch 时，点导入直接出预览，路径为真实 `~/.cc-switch/cc-switch.db`。
- App Store：选择器 message 含 `/Users/<name>/.cc-switch/cc-switch.db`，不含 `Library/Containers`。
- 预览里官方 OAuth 行在跳过区；带 Key 的 Codex / 可映射项在可导区且默认勾选。
- 确认后 Starcat 出现 `cc-switch: …` 新 Profile；原有同类型 Profile 的 Key 不变。
- 测试成功的进入正式列表并可被摘要任务选中；失败的仍能在 Picker 草稿/未验证区看到（以当前设置页「未验证不进正式列表」为准）。
- 再导一次同一条：得到 `cc-switch: Name 2`，第一条不动。
- 日志无 Key。

## 17. 回滚

删除入口按钮与 `CCSwitchImport/` 目录即可。已导入的 Profile 是普通 `AIProviderProfile`，用户可在设置页手动删除。不需要 migration 回滚。

## 18. 与文档 68 的衔接

| 合入顺序 | 导入行为 |
|---|---|
| 只合 69 | Claude `/anthropic` 尽量改写成已知 OpenAI host；改不了则 skip |
| 先 68 后 69 | Claude 与 `/anthropic` 进 `.anthropic`，URL 不改写 |
| 两份同 PR | 按 68 已可用处理 |

建议落地顺序：68 → 69。69 的 mapper 测试必须同时覆盖 anthropicAvailable true/false，避免后合 68 时行为静默变化没人测到。
