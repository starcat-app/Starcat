# App Store Connect CLI 评估与暂缓接入记录

> 评估日期：2026-08-10  
> 上游项目：[rorkai/App-Store-Connect-CLI](https://github.com/rorkai/App-Store-Connect-CLI)  
> 评估版本：`3.7.0`  
> 当前状态：**暂缓接入，继续使用现有 Xcode Organizer 手动流程**  
> 适用渠道：仅 App Store / TestFlight；不适用于 Direct DMG 发布

---

## 1. 结论

Starcat 可以使用 App Store Connect CLI（命令名 `asc`）补齐 App Store Connect 自动化，但不应让它替换现有 App Store archive 校验，也不应接入 Direct 发布链路。

本轮判定：

- **GO（后续可做）**：只读状态检查、build 查询、`.pkg` 上传、TestFlight 内测、feedback / crash 查询、metadata dry-run、截图上传规划。
- **NO-GO（当前不做）**：立即安装和认证、改造发布脚本、自动上传 build、自动修改线上 metadata、自动提交 App Review。
- **NO-GO（长期边界）**：替换 `scripts/package-appstore.sh` 的 Starcat 专用校验，或介入 Direct 的 DMG、notarization、Sparkle、官网上传流程。

当前手动链路已可用，没有必须立即引入新工具的阻塞。因此先保留本文档，等发布频率、TestFlight 运营或多语言商店物料维护成本明显上升后再启动。

---

## 2. Starcat 当前发布事实

### 2.1 App Store 渠道

| 项目 | 当前值 |
|------|--------|
| Scheme | `Starcat` |
| Bundle ID | `com.starcat.app.store` |
| App Store numeric App ID | `6788809803` |
| archive | `dist/appstore/Starcat-AppStore.xcarchive` |
| 当前上传方式 | Xcode Organizer Validate / Distribute |
| 支付 | StoreKit / Apple IAP |

`scripts/package-appstore.sh` 不只是调用 `xcodebuild archive`，还承担以下 Starcat 专用门禁：

- 只构建 `Starcat` scheme，不触碰 `StarcatDirect`。
- 验证 `STARCAT_DISTRIBUTION=appstore` 和 `com.starcat.app.store`。
- 验证主 App 具备 App Sandbox entitlement。
- 排除 Sparkle 及 Direct 渠道能力。
- 单独重签 `codebase.bin`，验证其 Sandbox entitlement。
- 生成并核对 `codebase.bin.dSYM` UUID。

因此，未来即使接入 `asc`，仍应先运行现有 `make package-appstore`，不能直接用 `asc xcode archive` 绕过这些门禁。

相关事实来源：

- [`scripts/package-appstore.sh`](../../scripts/package-appstore.sh)
- [`App Store 打包教程.md`](App%20Store%20打包教程.md)
- [`SOP-双渠道签名与发布.md`](SOP-双渠道签名与发布.md)
- [`SOP-App-Store-首次上架流程.md`](SOP-App-Store-首次上架流程.md)

### 2.2 Direct 渠道

Direct 正式发布仍由以下链路负责：

```text
scripts/release-direct.sh
  -> Developer ID 签名
  -> notarytool
  -> staple / Gatekeeper 校验
  -> DMG / Sparkle appcast
  -> 远程上传与在线校验
```

App Store Connect CLI 不管理 Direct 分发，未来接入时不得修改或复用这条链路。

---

## 3. 工具能力与 Starcat 适配度

| 能力 | Starcat 价值 | 当前判定 |
|------|--------------|----------|
| `asc auth status` / `asc auth doctor` | 检查 API Key 和网络认证 | 后续只读 POC |
| `asc apps info view` | 核对 App 记录和 Bundle ID | 后续只读 POC |
| `asc builds list` / `asc status` | 查询 processing、TestFlight、审核状态 | 推荐 |
| `asc review doctor` | 提前发现审核阻塞项 | 推荐，只读优先 |
| `asc builds upload --pkg` | 上传 macOS App Store `.pkg` | 推荐，第二阶段 |
| `asc builds add-groups` | 将 build 加入 Internal Testers | 推荐，第二阶段 |
| TestFlight feedback / crash | 集中查看测试反馈和崩溃 | 推荐 |
| metadata pull / validate / dry-run | 把线上 metadata 变成可审查文件 | 推荐，第三阶段 |
| screenshots plan / apply | 复用商店截图并减少后台手工上传 | 推荐，第三阶段 |
| certificate / profile 管理 | 自动管理签名资产 | 当前不做，避免扰动稳定签名环境 |
| `asc publish appstore` | 高层上传、挂 build、提交审核 | macOS 路径暂不采用 |

上游能力入口：

- [README Common Workflows](https://github.com/rorkai/App-Store-Connect-CLI#common-workflows)
- [Apple：Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [Apple：Submit an app](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app)

---

## 4. macOS 接入的关键限制

截至 `3.7.0`，上游对 macOS build 的明确上传入口是：

```bash
asc builds upload \
  --app "6788809803" \
  --pkg "/path/to/Starcat.pkg" \
  --version "X.Y.Z" \
  --build-number "BUILD_NUMBER" \
  --wait \
  --output json
```

但高层 `asc publish appstore` 仍以 `--ipa` 为主要输入，不能把它直接视为完整可靠的 macOS `.pkg` 一键发布入口。

未来接入应采用下列分层：

```text
make package-appstore
  -> Starcat-AppStore.xcarchive
  -> xcodebuild -exportArchive
  -> Starcat.pkg
  -> asc builds upload --pkg
  -> asc builds add-groups / asc status
```

只有当上游明确提供并验证 `publish appstore --pkg` 后，才重新评估是否收敛为高层 publish 命令。

---

## 5. 暂缓原因

1. **当前流程可用**：`make package-appstore` + Xcode Organizer 已经过真实发版验证，没有自动化阻塞。
2. **会新增远程写权限**：引入 `asc` 需要 App Store Connect API Key，并可能获得上传、metadata、截图或提交审核权限。
3. **macOS 高层命令尚未闭环**：`.pkg` 上传可用，但高层 `publish appstore` 仍偏向 `.ipa`。
4. **上游迭代很快**：评估期版本更新频繁，未来接入前必须重新核对命令、稳定性标签和变更记录。
5. **首次自动化收益有限**：Starcat 当前不是高频 App Store 发版，先保留人工确认更符合 IAP、隐私标签和审核资料的风险级别。
6. **自动化不能替代后台验收**：协议、税务银行、IAP 关联、隐私标签、Review Notes 和审核账号仍需要人工确认。

---

## 6. 后续启动条件

满足以下任一条件时，可以重新评估：

- App Store / TestFlight 上传频率明显提高，Organizer 操作成为重复成本。
- 需要稳定维护多个 TestFlight 测试组、What to Test、feedback 或 crash。
- App Store metadata / screenshots 开始覆盖多个 locale，需要版本化和批量审核。
- 引入 CI/CD，需要无界面的 `.pkg` 上传和 processing 轮询。
- 上游稳定支持 macOS `publish appstore --pkg`，并提供明确的兼容承诺。

重新启动时先检查：

```bash
asc version
asc --help
asc builds upload --help
asc publish appstore --help
```

本文档中的 `3.7.0` 命令只能作为评估快照，不能直接假定为未来版本的当前接口。

---

## 7. 推荐实施阶段

### 阶段 A：只读 POC

目标：证明认证、App 定位和状态查询可用，不修改 App Store Connect。

建议验证：

- `asc auth status --validate`
- `asc auth doctor`
- `asc apps info view --app "6788809803"`
- `asc builds list --app "6788809803" --output json`
- `asc review doctor --app "6788809803"`
- `asc status --app "6788809803"`
- localization / screenshot 只读查询

阶段 A 不允许执行 upload、apply、replace、submit、delete、expire 或 signing 资产修改。

### 阶段 B：`.pkg` 上传与 TestFlight

目标：保留现有 archive 门禁，只自动化导出、上传和 processing 等待。

建议约束：

- `scripts/package-appstore.sh` 保持默认只产出 `.xcarchive`。
- 新增独立脚本处理 `.xcarchive -> .pkg -> asc upload`，避免安全入口和远程写入口混在一起。
- version / build number 从 archive 中读取；命令行参数只能用于显式核对，不能静默覆盖产物事实。
- 上传必须要求显式确认，例如 `CONFIRM=YES`。
- 默认只进入 Internal Testers，不自动触发 External Beta App Review。
- processing 失败时保留 upload ID、版本号、build number 和日志，不自动重复上传同一 build。

### 阶段 C：metadata 与截图

目标：把线上商店资料变为可 diff、可人工审核的文件。

顺序必须是：

1. 从 App Store Connect `pull` 当前线上基线。
2. 将基线放入独立 metadata 目录，不与客户端 i18n 混用。
3. 执行 validate / dry-run。
4. 人工检查 locale、字符限制、隐私、截图顺序和真实显示效果。
5. 获得明确确认后才 apply。

Starcat 已有 `resources/screenshots/1.2.0-app-store/en-US/` 商店截图，但素材存在不等于已经通过当前版本的文案、隐私和 UI 人工验收。

### 阶段 D：审核提交

至少完成多个版本的只读检查和上传验证后，才考虑自动挂载 build 或提交 App Review。

第一版自动化仍应停在“准备完成、等待人工确认”，不得默认执行 `--submit --confirm`。

---

## 8. 安全边界

### 8.1 API Key

- `.p8` 私钥只能下载一次，必须放在 Keychain 或 CI Secret Manager。
- 禁止提交到仓库、写入 `Configs/Secrets.xcconfig`、普通 JSON、Markdown、shell history 或构建日志。
- 本机优先使用 Keychain-backed profile，不使用仓库内 `./.asc/config.json` 保存密钥。
- 上传 build 最低可使用 `Developer` 权限；自动提交审核需要 `Account Holder`、`Admin` 或 `App Manager`，两类权限应尽量分开。
- Key 丢失或怀疑泄露时立即在 App Store Connect revoke，不能只删除本地文件。

参考：[Apple：App Store Connect API](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api)

### 8.2 工具与网络

- 正式接入时锁定已验证版本，发版当天不自动升级 `asc`。
- 上游 telemetry 默认开启；Starcat 发布环境应先执行 `asc telemetry disable` 或设置 `DO_NOT_TRACK=1`。
- 初期不执行 `asc install-skills`，避免在验证 CLI 前修改全局 Agent Skills。
- 不在日志中使用 `--include-sensitive`。

### 8.3 远程写入

- upload、metadata apply、screenshots replace、submit、delete、expire 都是外部写操作。
- Makefile / script 必须把只读命令和写命令分组，并为写命令增加显式确认门禁。
- dry-run 通过不代表线上 apply 已完成；processing 完成也不代表 TestFlight、IAP 或 App Review 已验收。

---

## 9. 未来实现草案

以下仅记录候选结构，当前没有创建这些文件或命令：

```text
scripts/
  package-appstore.sh          # 保持现有 archive + Starcat 专用校验
  export-upload-appstore.sh    # 候选：导出 PKG + asc upload

Makefile
  appstore-asc-doctor          # 只读
  appstore-asc-status          # 只读
  appstore-asc-upload          # 远程写，要求 VERSION / CONFIRM
```

建议继续使用 `6788809803` 作为公开、非敏感的 App ID；API Key ID、Issuer ID 和私钥不写入 Makefile。

---

## 10. 验收标准

未来接入只有同时满足以下条件才算完成：

- 原有 `package-appstore.sh` 全部门禁继续执行并通过。
- 导出的 `.pkg` 中 version、build number、Bundle ID 与 archive 一致。
- API Key、Issuer ID、私钥未进入 Git、产物、日志或 shell history。
- 上传后能定位同一个 build，并区分 Processing、Failed、Complete。
- Internal TestFlight 分组可控，不误发 External TestFlight。
- metadata / screenshots 默认 dry-run，线上写入必须显式确认。
- App Review 提交仍有独立人工门禁。
- Direct 的 `release-direct.sh`、notarytool、DMG 和 Sparkle 链路没有变化。
- 删除候选 wrapper 或停用 `asc` 后，原 Xcode Organizer 手动流程仍可独立工作。

---

## 11. 当前决策记录

2026-08-10：完成上游能力与 Starcat 双渠道发布链路的只读评估。决定暂不安装、不认证、不修改发布脚本、不操作 App Store Connect；保留现有 Xcode Organizer 手动上传流程，后续按本文档的阶段 A 重新启动。
