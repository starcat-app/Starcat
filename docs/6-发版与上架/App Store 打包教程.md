# App Store 打包教程

> 适用渠道：Mac App Store / TestFlight  
> 对应脚本：`scripts/package-appstore.sh`  
> 构建目标：`Starcat`  
> Bundle ID：`com.starcat.app.store`
> 完整首次上架流程：`docs/6-发版与上架/SOP-App-Store-首次上架流程.md`

## 1. 前置条件

- 已配置 Apple Developer Team 和 App Store 签名证书。
- Xcode 已登录对应 Apple ID。
- `project.yml` 已同步：`xcodegen generate`。
- 当前工作区已完成 commit，避免 archive 版本号和源码不一致。

## 2. 一键生成 archive

```bash
./scripts/package-appstore.sh
```

脚本会生成：

```text
dist/appstore/Starcat-AppStore.xcarchive
dist/appstore/xcodebuild-appstore.log
```

脚本内置检查：

- `STARCAT_DISTRIBUTION == appstore`
- archive 中不存在 `Sparkle.framework`
- 主程序和 debug dylib 不链接 Sparkle

Automatic Signing 的 archive 是中间产物，允许保留 Apple Development 签名和开发
provisioning profile。Xcode 会在 App Store export / Organizer Distribute 阶段统一换成
Distribution 签名，不能把 archive 的签名直接当作最终上传包签名。

## 3. 本地导出最终 pkg（不上传）

需要完成最终签名核验、但暂不上传时运行：

```bash
STARCAT_DEVELOPMENT_TEAM=8WCUMGCWMB \
STARCAT_APPSTORE_EXPORT=1 \
STARCAT_APPSTORE_ALLOW_PROVISIONING_UPDATES=1 \
STARCAT_APPSTORE_SKIP_OPEN=1 \
./scripts/package-appstore.sh
```

产物为 `dist/appstore/export/Starcat.pkg`。脚本固定使用 `destination=export`，并解包验证：

- Installer 使用 Mac Installer Distribution 证书。
- 主 App、Widget 与 `codebase.bin` 全部使用 Apple Distribution。
- 主 App 与 Widget 使用 Store provisioning profile，且不包含开发设备。
- 最终 App 通过 `codesign --verify --deep --strict`。

## 4. 上传 App Store Connect

推荐用 Xcode Organizer：

1. Xcode -> Window -> Organizer。
2. 选择 `Starcat-AppStore.xcarchive`。
3. Validate App。
4. Distribute App -> App Store Connect。

如果走 CI，可复用脚本的本地 export 模式；上传仍是独立授权动作，不能把
`destination=export` 改成 `upload` 后自动执行。

## 5. 上架前检查

- App Store 版本不展示“检查更新”菜单。
- App Store 版本不出现授权码、外部支付、官网购买入口。
- About 页可展示通用开源致谢；实际二进制不应包含 Sparkle。
- App Store Connect 内订阅商品、隐私标签和审核备注按 `docs/6-发版与上架/v1-上架信息准备.md` 填写。

## 6. 常见问题

### Archive 失败

先看：

```bash
tail -80 dist/appstore/xcodebuild-appstore.log
```

常见原因是本机签名证书、Team、Provisioning Profile 未配置完整。

### Sparkle 检查失败

App Store target 不允许依赖 Sparkle。如果脚本报 `App Store 包包含 Sparkle 相关文件`，检查：

- `project.yml` 的 `Starcat.dependencies` 没有 `Sparkle`
- Sparkle 只在 `StarcatDirect.dependencies`
- 不要把 Direct 产物复制进 App Store archive
