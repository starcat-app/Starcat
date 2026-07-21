# Starcat 新 Mac 开发、打包与分发环境搭建

> 适用场景：把 Starcat 迁移到第二台 Mac，或从一台干净的 macOS 机器开始恢复完整开发与发布能力。  
> 配套脚本：`scripts/setup-macos-development.sh`  
> 当前项目：Apple Silicon、macOS 15+、Xcode 26.5+、Swift 6、XcodeGen。  
> 本文只准备环境。任何 archive、notarization submit、tag、上传和正式发布都必须另行人工执行。

## 1. 最终目标

完成本文后，新 Mac 应同时满足以下能力：

| 能力 | Starcat App Store | Starcat Direct |
|---|---|---|
| 本地 Debug | `Starcat` scheme | `StarcatDirect` scheme |
| Bundle ID | `com.starcat.app.store` | `com.starcat.app.direct` |
| 本地开发签名 | `Apple Development` | `Apple Development` |
| 正式分发签名 | `Apple Distribution` | `Developer ID Application` |
| Sandbox | 必须开启 | 必须关闭 |
| Sparkle | 禁止包含 | 必须包含，且使用既有 EdDSA key |
| 发布方式 | Xcode Organizer → App Store Connect | Developer ID → notarization → stapled DMG → appcast |

环境验收必须回答两个不同问题：

1. **开发 READY**：可以生成工程、解析依赖、运行 Debug、跑测试。
2. **发布 READY**：还具备三类签名身份、notary profile、Sparkle 私钥、生产配置和发布服务器 SSH。

只登录 Xcode 开发者账号，不代表“发布 READY”。证书对应的私钥、Sparkle 私钥、notary profile 和本地 Secrets 都可能仍然缺失。

## 2. Starcat 配置分布

Starcat 的完整环境不是一个目录可以覆盖的。迁移前先区分配置归属：

| 内容 | 所在位置 | Git 管理 | 新 Mac 处理方式 |
|---|---|---:|---|
| Swift 源码、`project.yml`、脚本、公开配置 | Starcat 仓库 | 是 | Git 或全量目录复制 |
| `Starcat.xcodeproj` | 本地生成 | 否 | 用 `xcodegen generate` 重建 |
| SPM checkout、DerivedData、build、dist | Xcode / 仓库临时目录 | 否 | 不复制，重新生成 |
| `Configs/Secrets.xcconfig` | 仓库本地文件 | 否 | SSH/加密介质安全迁移，权限设为 `600` |
| `sparkle-private-key` 导出文件 | 临时传输文件 | 否 | 只用于导入，导入后移入加密存储 |
| Sparkle EdDSA 私钥 | login Keychain | 否 | 从原 Mac 导出同一私钥，再导入新 Mac |
| Apple 签名证书 + 私钥 | login Keychain | 否 | 导入受密码保护的 `.p12`，或在 Xcode 创建允许的新证书 |
| Provisioning Profiles | Xcode 缓存 | 否 | Automatic Signing 重新下载，不建议直接复制缓存 |
| `starcat-notary` | Keychain generic password | 否 | 每台 Mac 单独执行 `notarytool store-credentials` |
| GitHub / 发布服务器 SSH key | `~/.ssh` | 否 | 安全迁移私钥与 `config`，权限设为 `600` |
| `supports/starcat-pro` 等项目 | `supports/` 下独立 Git 仓库 | 不属于主仓库 | 保留各自 `.git`，逐个 clone 或全量复制 |
| `Starcat/Resources/Codebase/codebase.bin` | Git ignored 构建资源 | 否 | 全量复制或运行下载脚本重新获取 |

不要复制整个 `~/Library/Keychains` 或整个 DerivedData。证书通过 Xcode/Keychain 导入，Sparkle 使用官方 `generate_keys -x/-f`，notary profile 在新 Mac 重新创建。

## 3. 2026-07-21 远端 MBP 只读审计

本次通过 `ssh mbp` 检查，未修改远端配置。

| 检查项 | 当前状态 | 判断 |
|---|---|---|
| 主机 | `dong4jsmbp.local`，Apple Silicon | 满足 |
| macOS | 26.5.2 | 满足 |
| Xcode | 26.6，`xcode-select` 指向完整 Xcode | 满足 |
| Xcode first launch | 已完成 | 满足 |
| Xcode 开发者账号 | dong4j 已人工确认登录 | 满足账号前提 |
| Homebrew | 缺失 | 开发 NO-GO |
| XcodeGen | 缺失 | 开发 NO-GO |
| create-dmg | 缺失 | Direct 打包 NO-GO |
| Apple Development | 未发现可用 identity | Debug 签名 NO-GO |
| Apple Distribution | 未发现可用 identity | App Store archive NO-GO |
| Developer ID Application | 已存在 `8WCUMGCWMB` identity | Direct 签名前提满足 |
| Provisioning Profiles 缓存 | 0 | 由 Xcode Automatic Signing 后续获取 |
| `starcat-notary` | SSH 会话中默认 Keychain 被锁定，无法验证 | 需在新 Mac GUI Terminal 复查/重建 |
| GitHub SSH | 已认证为 `dong4j` | 满足 |
| Direct 发布服务器 `aliyun2` | SSH 连通 | 满足 |
| Starcat 仓库 | 尚未复制到预期路径 | 待全量复制 |

当前结论：这台 MBP 还不能完成 Starcat 开发或双渠道发布。主要缺口是 Homebrew/XcodeGen/create-dmg、Apple Development、Apple Distribution，以及尚未落盘的项目配置与 Sparkle/notary 验证。

SSH 下看到 `keychainLocked` 不等于 GUI 登录后的本机 Terminal 一定失败。macOS 的 login Keychain 会话状态不同；最终凭据配置和公证验证应在新 Mac 的 GUI 登录会话中完成。

## 4. 全量复制 Starcat 目录

### 4.1 推荐保留

全量复制时应保留：

- 主仓库 `.git/`。
- `supports/*` 下每个独立仓库自己的 `.git/`。
- `.claude/skills/`、脚本和文档。
- `Configs/Secrets.xcconfig`。
- `sparkle-private-key`，但它只能作为短期迁移文件。
- `Starcat/Resources/Codebase/codebase.bin`。
- `supports/*/.env` 等 Git ignored 的本地环境文件。

### 4.2 推荐排除

以下内容可以重建，不应占用迁移时间：

```text
.DS_Store
.build/
build/
dist/
DerivedData/
.swiftpm/
Starcat.xcodeproj/
**/xcuserdata/
**/*.xcuserstate
**/*.xcresult
.codegraph/
node_modules/
__pycache__/
```

不要直接复用仓库里的 `scripts/sync-exclude.list` 做“全量迁移”。该文件服务于另一条显式清单同步流程，会故意排除独立 supports 仓库和 `codebase.bin`，不符合这次全目录迁移目标。

### 4.3 rsync 示例

先 dry-run，确认目标路径准确：

```bash
rsync -anE --progress \
  --exclude '.DS_Store' \
  --exclude '.build/' \
  --exclude 'build/' \
  --exclude 'dist/' \
  --exclude 'DerivedData/' \
  --exclude '.swiftpm/' \
  --exclude 'Starcat.xcodeproj/' \
  --exclude 'xcuserdata/' \
  --exclude '*.xcuserstate' \
  --exclude '*.xcresult' \
  --exclude '.codegraph/' \
  /Users/dong4j/Developer/1.AI/ai-incubator/Starcat/ \
  mbp:/Users/dong4j/Developer/1.AI/ai-incubator/Starcat/
```

确认 dry-run 清单后，把 `-n` 去掉执行真实复制。SSH 传输是加密的，但目标磁盘上的 `Secrets.xcconfig`、`.env` 和 `sparkle-private-key` 仍是明文文件，复制完成后必须收紧权限：

```bash
ssh mbp 'chmod 600 \
  /Users/dong4j/Developer/1.AI/ai-incubator/Starcat/Configs/Secrets.xcconfig \
  /Users/dong4j/Developer/1.AI/ai-incubator/Starcat/sparkle-private-key'
```

## 5. 从干净 macOS 开始

### 5.1 安装完整 Xcode

1. 从 Mac App Store 或 Apple Developer 下载完整 Xcode。
2. 把 Xcode 放到 `/Applications/Xcode.app`。
3. 启动一次 Xcode，接受 license 并等待组件安装完成。
4. Xcode → Settings → Accounts，登录 Apple Developer 账号并选择 Team `8WCUMGCWMB`。

命令行验证：

```bash
xcode-select -p
xcodebuild -version
xcodebuild -checkFirstLaunchStatus
```

预期 `xcode-select -p`：

```text
/Applications/Xcode.app/Contents/Developer
```

如果仍指向 Command Line Tools：

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
```

### 5.2 运行交互式准备脚本

在 Starcat 根目录执行：

```bash
chmod +x scripts/setup-macos-development.sh
./scripts/setup-macos-development.sh
```

脚本会逐项询问是否执行：

1. 检查/切换完整 Xcode。
2. 安装 Homebrew。
3. 安装 `xcodegen`、`create-dmg`，缺失时补 `jq`。
4. 从模板创建 `Configs/Secrets.xcconfig`，写入 Team ID，并设置 `chmod 600`。
5. 运行 `xcodegen generate`。
6. 解析 `StarcatDirect` 的 Swift Package，拉取 Sparkle 等依赖。
7. 检查/下载 `codebase.bin`。
8. 检查/克隆 `supports/starcat-pro`。
9. 提示补齐三类签名证书。
10. 可选创建 `starcat-notary`。
11. 验证或导入既有 Sparkle 私钥。
12. 只读验证两个 entitlements、生成工程 capability、线上 AASA 和已有 Direct Debug 产物。
13. 最后输出“开发 READY”和“打包/分发 READY”两个结论。

脚本不会执行：

- `xcodebuild build/test/archive`。
- `scripts/package-*`。
- `notarytool submit`。
- `release-direct.sh`。
- Git tag、push、DMG/appcast/网站上传。

只读复查：

```bash
./scripts/setup-macos-development.sh --check
```

`--check` 会访问 Apple Notary、线上 AASA 和两个 SSH 端点来验证凭据/连通性，但不会修改本地或远端状态，也不会为了验收自动触发 provisioning build。

### 5.3 Codex / SSH 执行时如何处理人工输入

Codex 可以通过 SSH 完成文件同步、工具检查、XcodeGen、SPM 解析和只读审计。脚本检测到 SSH 会话后，会主动跳过 Xcode GUI、签名私钥、notary 凭据和 Sparkle 私钥等 Keychain 敏感步骤。

需要输入 macOS 登录密码、`.p12` 密码、Apple ID 验证码或 App-specific password 时：

1. 不要把密码发到聊天中，也不要拼进 SSH 命令或环境变量。
2. 在目标 Mac 的图形界面中打开 Terminal。
3. 在本机 Terminal 执行：

   ```bash
   cd ~/Developer/1.AI/ai-incubator/Starcat
   ./scripts/setup-macos-development.sh
   ```

4. 只在目标 Mac 的本机安全提示中输入密码；完成后告知 Codex“本机输入已完成”。
5. Codex 再通过 SSH 执行 `./scripts/setup-macos-development.sh --check` 和后续只读验收。

这套交接方式让自动化负责可重复步骤，让开发者本人只接管系统明确要求的人机认证步骤。

## 6. Homebrew 与项目工具

Starcat 必需或直接相关的工具：

| 工具 | 来源 | 用途 |
|---|---|---|
| Xcode / `xcodebuild` / `codesign` / `notarytool` / `stapler` | Apple | 编译、签名、公证 |
| Git / SSH / rsync / Python 3 | macOS 自带即可 | 版本管理、发布上传、脚本 |
| Homebrew | brew.sh | 安装项目 CLI |
| XcodeGen | `brew install xcodegen` | 从 `project.yml` 生成工程 |
| create-dmg | `brew install create-dmg` | 生成带 Finder 布局的 Direct DMG |
| jq | macOS 新版本可能自带；否则 Homebrew | `scripts/sync-untracked.sh` 读取主机配置 |

手动安装：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv)"
brew install xcodegen create-dmg jq
```

把 Homebrew PATH 持久化到 zsh，使用安装器最后打印的命令。Apple Silicon 的标准前缀是 `/opt/homebrew`。

验证：

```bash
brew --version
xcodegen --version
command -v create-dmg
python3 --version
rsync --version
```

## 7. Apple 签名证书与私钥

### 7.1 Starcat 实际需要三类 identity

```text
Apple Development: ... (<个人证书标识>)
Apple Distribution: ... (8WCUMGCWMB)
Developer ID Application: ... (8WCUMGCWMB)
```

用途：

- `Apple Development`：本地 Debug/test host。
- `Apple Distribution`：`scripts/package-appstore.sh` 生成和校验 App Store archive。
- `Developer ID Application`：Direct App、Sparkle 嵌套组件、`codebase.bin` 和 DMG 签名。

`Apple Development` 显示名末尾的括号可能是个人证书标识，不应拿它与 `DEVELOPMENT_TEAM` 做字符串比较。项目 Team 仍由 `DEVELOPMENT_TEAM = 8WCUMGCWMB`、Automatic Signing 和 provisioning profile 共同约束。

虽然 Xcode Organizer 支持 cloud-managed distribution signing，但 Starcat 的 `package-appstore.sh` 会在 archive 后处理嵌入式可执行文件，因此新 Mac 仍应准备本地可用的 `Apple Distribution` identity。

### 7.2 验证 identity

```bash
security find-identity -v -p codesigning
```

证书只有 `.cer` 而没有对应 private key 时，不能签名。Keychain Access 的“My Certificates”中，证书下方应能展开看到私钥。

### 7.3 推荐：从原 Mac 导出 `.p12`

在原 Mac：

1. Xcode → Settings → Accounts。
2. 选择 Apple Account 和 Team `8WCUMGCWMB`。
3. Manage Certificates。
4. 分别选择需要迁移的 identity，右键 Export Certificate。
5. 保存为受强密码保护的 PKCS#12（`.p12`）。
6. 通过 SSH、加密磁盘映像或密码管理器附件传输；密码走另一条通道。

在新 Mac：

1. 双击 `.p12`，导入 login Keychain。
2. 输入导出密码。
3. 重新运行 `security find-identity -v -p codesigning`。
4. 验证完成后从普通目录移除 `.p12`，只保留加密备份。

不要为了新 Mac 随意吊销旧证书。Developer ID 被吊销会影响使用该证书签名的软件。确需新建证书时，先确认账号角色和证书数量限制，再在 Xcode Manage Certificates 或 Apple Developer 后台创建。

### 7.4 Provisioning Profiles

Starcat 使用 `CODE_SIGN_STYLE = Automatic`。正常流程是：

1. 登录 Xcode Account。
2. 确保项目 Team 为 `8WCUMGCWMB`。
3. 第一次 build/archive 时让 Xcode 分别下载匹配以下 Bundle ID 的 profiles：
   - App Store：`com.starcat.app.store`。
   - Direct：`com.starcat.app.direct`。
4. Direct Development Profile 必须授权 `com.apple.developer.associated-domains`，否则源码里的 entitlement 无法进入最终签名。

不要把旧 Mac 的 `~/Library/MobileDevice/Provisioning Profiles` 当作必须迁移资产；它们是可重建缓存。只有 Automatic Signing 无法恢复时，才到 Apple Developer 后台人工下载并排查 App ID/capability。

### 7.5 Universal Links / Associated Domains 的开发签名与设备注册

Universal Links 不是每台 Mac 都重新配置一遍服务器和 Apple Developer 后台，而是分为四层：

| 层级 | 当前 Starcat 配置 | 是否每台新 Mac 重做 |
|---|---|---:|
| 项目声明 | `Starcat.entitlements` 与 `StarcatDirect.entitlements` 都声明 `applinks:starcat.ink` | 否，随仓库同步 |
| Xcode Capability | `xcodegen generate` 后由 `postprocess-xcodeproj.py` 给两个 target 写入 Associated Domains capability | 否，由工程生成脚本恢复 |
| Apple Developer Team | `com.starcat.app.store` 与 `com.starcat.app.direct` 的 App ID 已启用 Associated Domains | 否，Team 级配置 |
| AASA | `starcat.ink` 授权两个 Bundle ID 处理 `/r/*` | 否，网站级配置 |
| Development Signing | 登记这台 Mac，并下载包含 Associated Domains 的 Development Profile | **是** |

因此，新 Mac 不需要重新开启后台 capability，也不能靠手工修改生成后的 `.xcodeproj` 解决；只需要登录相同 Team，然后明确允许 Xcode 更新 provisioning 并登记当前 Mac：

```bash
xcodegen generate

xcodebuild \
  -project Starcat.xcodeproj \
  -scheme StarcatDirect \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData-DirectProvisioning \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build
```

这条命令会产生签名构建并可能在 Apple Developer Team 登记当前 Mac，属于必须由开发者人工明确执行的一次性动作；`setup-macos-development.sh` 不会代跑。

固定产物路径：

```bash
APP="build/DerivedData-DirectProvisioning/Build/Products/Debug/Starcat.app"
```

验证代码签名和最终 entitlement：

```bash
codesign --verify --deep --strict --verbose=2 "$APP"

codesign -d --entitlements :- "$APP" 2>/dev/null \
  | plutil -p -
```

必须看到：

```text
"com.apple.developer.associated-domains" => [
  0 => "applinks:starcat.ink"
]
```

如 App 内包含 Development Profile，可读取实际有效期，不要把某台 Mac 的日期写成所有机器的固定要求：

```bash
PROFILE="$APP/Contents/embedded.provisionprofile"

security cms -D -i "$PROFILE" \
  | plutil -extract ExpirationDate raw -o - -
```

线上 AASA 应同时包含以下 app ID，并把 `/r/*` 交给 Starcat：

```text
8WCUMGCWMB.com.starcat.app.store
8WCUMGCWMB.com.starcat.app.direct
```

只读核对：

```bash
curl -fsSL 'https://starcat.ink/.well-known/apple-app-site-association' \
  | jq '.applinks.details'
```

2026-07-21 已验证样本 `studio`：已登记到 Team，生成 `com.starcat.app.direct` 的 Mac Development Profile（有效期至 2027-07-21），`StarcatDirect` 签名构建和 `codesign --verify --deep --strict` 通过，最终 App 包含 `applinks:starcat.ink`。该日期只作为本次验收记录。

## 8. `Configs/Secrets.xcconfig`

该文件被 `.gitignore` 排除，但会通过 `Configs/Build.xcconfig` 注入 Debug/Release 构建。最小模板：

```bash
cp Configs/Secrets.xcconfig.template Configs/Secrets.xcconfig
chmod 600 Configs/Secrets.xcconfig
```

开发签名至少需要：

```xcconfig
DEVELOPMENT_TEAM = 8WCUMGCWMB
CODE_SIGN_IDENTITY = Apple Development
```

完整发布还应补齐现有生产值，包括：

- `STARCAT_SPARKLE_PUBLIC_ED_KEY`。
- `STARCAT_OAUTH_CLIENT_SECRET`。
- `STARCAT_PRODUCTION_API_KEY_*`。
- `STARCAT_LICENSE_API_TEST_*` / `STARCAT_LICENSE_API_LIVE_*`。
- `STARCAT_APTABASE_APP_KEY`。

不要在终端、聊天、issue 或文档里打印真实值。推荐直接通过 SSH 复制已有 `Secrets.xcconfig`；如果支持服务 `.env` 已迁移，可以运行 `make setup-production-api-keys` 补齐该脚本负责的 production API keys，但其余字段仍需核对。

检查“是否填写”而不输出值：

```bash
./scripts/setup-macos-development.sh --check
```

## 9. Sparkle EdDSA：必须迁移同一私钥

### 9.1 为什么不能在新 Mac 重新生成

已发布 Direct 版本内置了既有 `SUPublicEDKey`。新更新的 appcast 必须由对应私钥签名。如果新 Mac 生成另一组 EdDSA key，旧版 Starcat 将不能验证新更新。

因此新 Mac 的允许动作只有：

- 从原 Mac 导出既有私钥。
- 在新 Mac 导入同一私钥。
- 用 `generate_keys -p` 只读查询，并与 `STARCAT_SPARKLE_PUBLIC_ED_KEY` 比对。

不要在确认私钥存在前直接无参数运行 `generate_keys`；私钥缺失时，无参数模式可能生成新 key。

### 9.2 原 Mac 导出

先找到当前 Sparkle 工具：

```bash
SPARKLE_TOOL="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys' \
  -type f | head -1)"

"$SPARKLE_TOOL" -p
"$SPARKLE_TOOL" -x "$HOME/sparkle-private-key"
chmod 600 "$HOME/sparkle-private-key"
```

`-x` 输出的是等价于密码的敏感私钥材料，不能提交 Git。

### 9.3 新 Mac 导入

先生成工程并解析 Direct 的 SPM 依赖：

```bash
xcodegen generate
xcodebuild \
  -resolvePackageDependencies \
  -project Starcat.xcodeproj \
  -scheme StarcatDirect
```

找到新 Mac 的工具并导入：

```bash
SPARKLE_TOOL="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys' \
  -type f | head -1)"

"$SPARKLE_TOOL" -f /安全路径/sparkle-private-key
"$SPARKLE_TOOL" -p
```

导入后：

```bash
./scripts/setup-macos-development.sh --check
```

只有出现“Keychain 私钥与 `STARCAT_SPARKLE_PUBLIC_ED_KEY` 匹配”才算通过。导入完成后，把导出文件移入加密存储或离线介质，不要长期留在 Starcat 根目录。

## 10. Apple notarization

Starcat 当前默认 profile 名：

```text
starcat-notary
```

每台 Mac 单独配置。推荐在新 Mac 的 GUI 登录会话中打开 Terminal 执行：

```bash
xcrun notarytool store-credentials starcat-notary \
  --apple-id "你的 Apple ID 邮箱" \
  --team-id "8WCUMGCWMB"
```

故意不传 `--password`。`notarytool` 会安全提示输入 App-specific password，避免密码进入 shell history 或进程列表。

验证：

```bash
xcrun notarytool history --keychain-profile starcat-notary
```

可能结果：

- 返回历史或 `No submission history`：凭据有效。
- `No Keychain password item found`：profile 未创建或名称错误。
- `keychainLocked`：当前会话无法解锁默认 Keychain；在 GUI Terminal 重试，不要把登录密码写进脚本。
- Apple 认证错误：重新创建 App-specific password，然后覆盖同名 profile。

App Store 版不需要额外 notarization；App Store Connect 的上传流程包含相应安全检查。Direct 的公开 DMG 才走 `Developer ID + notarytool + staple`。

## 11. SSH、Git 与发布服务器

正式 Direct 发布会：

- 创建并 push Git tag。
- 通过 SSH/rsync 连接 `aliyun2`。
- 上传 DMG、SHA256、appcast 和站点资源。

验证 GitHub：

```bash
ssh -T git@github.com
```

GitHub 成功认证时仍会返回“does not provide shell access”，这是正常行为。

验证发布服务器：

```bash
ssh -o BatchMode=yes -o ConnectTimeout=8 aliyun2 true
```

迁移 `~/.ssh/config` 和私钥后，确保：

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/config ~/.ssh/<private-key>
chmod 644 ~/.ssh/<private-key>.pub
```

不要把 `~/.ssh` 放入 Starcat 仓库。新 Mac 首次连接时人工核对 host fingerprint，不能为了省事全局关闭 `StrictHostKeyChecking`。

## 12. Git ignored 但构建必需的资产

### 12.1 `codebase.bin`

`Starcat/Resources/Codebase/codebase.bin` 体积较大且不进 Git，但 App Store/Direct 包都需要。全量复制后验证：

```bash
test -x Starcat/Resources/Codebase/codebase.bin
file Starcat/Resources/Codebase/codebase.bin
```

缺失时重新下载：

```bash
./scripts/fetch-codebase-binary.sh
```

下载脚本会执行 SHA-256 校验并设置执行权限。

### 12.2 `supports/starcat-pro`

Direct Release 构建从该独立仓库读取双语 changelog：

```bash
test -d supports/starcat-pro/.git
```

缺失时只克隆需要的仓库：

```bash
git clone https://github.com/starcat-app/starcat-pro.git supports/starcat-pro
```

不要把它强行加入 Starcat 主仓库。`supports/clone-all.sh` 会处理整个 supports 生态，范围更大；只为客户端发版准备环境时，不需要自动克隆全部项目。

## 13. 分阶段验收

### 13.1 纯环境审计

```bash
./scripts/setup-macos-development.sh --check
```

目标：

```text
开发环境：READY
打包 / 分发环境：READY
```

### 13.2 生成工程与解析依赖

```bash
xcodegen generate
xcodebuild \
  -resolvePackageDependencies \
  -project Starcat.xcodeproj \
  -scheme StarcatDirect
```

### 13.3 检查两个渠道的 Build Settings

```bash
xcodebuild -project Starcat.xcodeproj -scheme Starcat -showBuildSettings \
  | rg 'PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM|CODE_SIGN_IDENTITY|STARCAT_DISTRIBUTION'

xcodebuild -project Starcat.xcodeproj -scheme StarcatDirect -showBuildSettings \
  | rg 'PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM|CODE_SIGN_IDENTITY|STARCAT_DISTRIBUTION'
```

预期：

| Scheme | Bundle ID | Distribution |
|---|---|---|
| `Starcat` | `com.starcat.app.store` | `appstore` |
| `StarcatDirect` | `com.starcat.app.direct` | `direct` |

### 13.4 Universal Links 开发签名验收

在每台新 Mac 上人工执行一次：

```bash
xcodegen generate

xcodebuild \
  -project Starcat.xcodeproj \
  -scheme StarcatDirect \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData-DirectProvisioning \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build
```

验证并启动签名产物：

```bash
APP="build/DerivedData-DirectProvisioning/Build/Products/Debug/Starcat.app"

codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements :- "$APP" 2>/dev/null | plutil -p -
open "$APP"
```

从 Codex、Mail、备忘录等外部应用点击测试链接：

```text
https://starcat.ink/r/swiftlang/swift?v=1&rid=44838949
```

验收标准：Starcat 自动激活并定位 `swiftlang/swift`。不要仅在浏览器地址栏粘贴 URL 作为唯一验收；如果仍进入 Chrome，继续排查 Universal Link 用户偏好、App 安装路径、AASA 缓存与 LaunchServices 注册。

### 13.5 Debug 验收

跑测前先完全退出 Xcode IDE，避免与 `xcodebuild test` 抢占 `testmanagerd`：

```bash
make test
```

两个 UI 渠道分别人工运行：

```bash
make run-appstore
make run-direct
```

验证：

- App Store Debug 有 sandbox entitlement。
- Direct Debug 没有 sandbox entitlement。
- Direct 包含 Sparkle，菜单“检查更新...”可用。
- App Store 不出现 Sparkle/Direct 授权入口。

### 13.6 App Store archive 验收（不上传）

```bash
make package-appstore
```

产物：

```text
dist/appstore/Starcat-AppStore.xcarchive
```

脚本会打开 Organizer，但不会自动上传。确认 archive 渠道检查全部通过后，上传仍按 `SOP-App-Store-首次上架流程.md` 人工执行。

### 13.7 Direct 本地 DMG 验收（不公证、不上传）

```bash
make package-direct VERSION=<测试版本>
```

该命令会生成本地 DMG，但不会提交 Apple Notary，也不会上传。它仍会用当前 Direct identity 重签 App、Sparkle 嵌套组件、`codebase.bin` 和 DMG。

### 13.8 Direct 公证验收（会上传 Apple Notary）

只有前面全部通过，并明确要验证公证时才执行：

```bash
make package-direct-notarized VERSION=<测试版本>
```

这是外部状态变更：会把 DMG 提交 Apple Notary。环境准备脚本绝不代跑。

### 13.9 正式发布

```bash
make release-direct VERSION=<正式版本>
```

这是正式发布入口，会涉及 tag、上传和线上文件更新。不要把它当作环境验证命令；执行前阅读：

- `SOP-双渠道签名与发布.md`。
- `Direct 打包教程.md`。
- `SOP-手动发布命令清单.md`。

## 14. 常见故障

### Xcode 已登录，但 `security find-identity` 只有 Developer ID

账号登录与本地 identity 是两回事。到 Xcode → Settings → Accounts → Team → Manage Certificates，创建允许的新 Development/Distribution identity，或从原 Mac 导入 `.p12`。

### `xcodegen: command not found`

```bash
eval "$(/opt/homebrew/bin/brew shellenv)"
brew install xcodegen
```

如果新 Terminal 又找不到，按 Homebrew 安装器提示把 `brew shellenv` 写入 `~/.zprofile`。

### `create-dmg 未安装`

```bash
brew install create-dmg
```

### `No signing certificate "Apple Distribution" found`

确认 identity 同时包含证书和 private key：

```bash
security find-identity -v -p codesigning
```

只下载 `.cer` 不够；导入原 Mac 的 `.p12`，或让 Xcode 创建新 identity。

### SSH 构建在 `CodeSign` 阶段报 `errSecInternalComponent`

如果 `security find-identity` 能看到 Development identity，Xcode 也已选中正确的 Development Profile，但给 App 或内嵌 Framework 签名时出现 `errSecInternalComponent`，通常不是 provisioning 或源码问题，而是 SSH 会话不能弹出 Keychain 私钥授权。

在目标 Mac 的图形界面中打开 Terminal，重新执行 §8.2 的 Development Provisioning 构建；若 macOS 弹出 `codesign` 访问私钥的提示，核对请求进程后选择“始终允许”。不要把 login Keychain 密码发给 Codex，也不要把密码写进 SSH 命令。若本机 Terminal 仍失败，再到 Keychain Access 的“My Certificates”确认目标证书下能展开 private key，并检查该私钥的 Access Control。

### `keychainLocked`

先在新 Mac 的 GUI 会话登录并打开 Keychain Access/Terminal。不要在 SSH 命令参数中传 macOS 登录密码。自动化/CI 需要单独的临时 keychain 设计，不属于当前个人双 Mac 手工发布流程。

### Sparkle `generate_keys -p` 失败

可能是：

- Keychain 被锁定。
- 私钥没有导入。
- 当前工具没有访问 Keychain 的权限。

回到原 Mac 导出同一私钥，再用 `-f` 导入。不要无参数运行工具生成新 key。

### Sparkle 私钥与配置公钥不匹配

这是发布 NO-GO。不要把新公钥写入 `Secrets.xcconfig` 来“修复”；旧版用户仍持有旧公钥。应删除错误导入的 Keychain item，再导入原发布私钥。任何 key rotation 都必须另立升级方案。

### Direct Release 报缺少 changelog

确认独立仓库存在：

```bash
git -C supports/starcat-pro status
test -f supports/starcat-pro/CHANGELOG.md
test -f supports/starcat-pro/CHANGELOG-ZH.md
```

### App Store archive 包含 Sparkle

说明走错 scheme/target 或项目配置漂移。App Store 只能构建 `Starcat`；Sparkle 只能属于 `StarcatDirect`。

### Universal Link 仍进入 Chrome

先确认签名产物包含 `applinks:starcat.ink`，再确认线上 AASA 同时授权两个 Bundle ID。两项都正确时，继续检查：

- 当前启动/安装的是刚刚签名的 `Starcat.app`，不是旧副本。
- 链接是从 Codex、Mail、备忘录等外部应用点击，而不是只在浏览器地址栏输入。
- 用户是否曾选择“在浏览器中打开”并形成 Universal Link 偏好。
- AASA 缓存与 LaunchServices 是否仍指向旧安装路径。

不要通过重复开关 Apple Developer 后台 capability 解决单机偏好或安装路径问题。

## 15. 最终检查清单

### 开发 READY

- [ ] Apple Silicon，macOS 15+。
- [ ] 完整 Xcode，`xcode-select` 指向 Xcode.app。
- [ ] Xcode license / first launch 完成。
- [ ] Xcode 登录 Team `8WCUMGCWMB`。
- [ ] Homebrew、XcodeGen 可用。
- [ ] `Configs/Secrets.xcconfig` 存在且权限 `600`。
- [ ] Apple Development identity 可用。
- [ ] `codebase.bin` 存在且可执行。
- [ ] `xcodegen generate` 成功。
- [ ] SPM 依赖解析成功。
- [ ] 当前 Mac 已登记到 Apple Developer Team，并生成 `com.starcat.app.direct` Development Profile。
- [ ] Direct 签名 App 包含 `com.apple.developer.associated-domains = applinks:starcat.ink`。
- [ ] 外部点击 `/r/*` 测试链接可以激活 Starcat 并定位仓库。
- [ ] `make test` 成功。
- [ ] App Store / Direct Debug 分别人工运行成功。

### 发布 READY

- [ ] Apple Distribution identity 可用。
- [ ] Developer ID Application identity 可用。
- [ ] `create-dmg` 可用。
- [ ] `supports/starcat-pro` 独立仓库存在。
- [ ] `Secrets.xcconfig` 的生产值完整。
- [ ] Sparkle 私钥已导入，且与项目公钥匹配。
- [ ] `starcat-notary` profile 有效。
- [ ] GitHub SSH 已认证。
- [ ] `aliyun2` SSH 可连接。
- [ ] `make package-appstore` 本地 archive 通过。
- [ ] `make package-direct VERSION=<测试版本>` 本地 DMG 通过。
- [ ] 公证与正式发布仅在明确需要时人工执行。

## 16. 官方参考

- [Apple：Synchronizing code signing identities with your developer account](https://developer.apple.com/documentation/Xcode/sharing-your-teams-signing-certificates)
- [Apple：Certificates overview](https://developer.apple.com/help/account/create-certificates/certificates-overview)
- [Apple：Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- [Apple：Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple：Import and export keychain items](https://support.apple.com/guide/keychain-access/kyca35961/mac)
- [Sparkle：Documentation / EdDSA key transfer](https://sparkle-project.org/documentation/)
- [Homebrew：Installation](https://docs.brew.sh/Installation)
- [XcodeGen：README](https://github.com/yonaskolb/XcodeGen)
- [create-dmg：README](https://github.com/create-dmg/create-dmg)
