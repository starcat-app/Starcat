# 分发渠道专项 Checklist

> 创建：2026-07-04
> 状态：已完成首期实现
> 需求入口：`docs/2-产品/需求讨论/分发渠道.md`
> 正式方案：`docs/2-产品/需求讨论/正式方案/分发渠道正式方案.md`
> 详细设计：`docs/3-设计/详细设计/41-分发渠道详细设计.md`

---

## 1. 文档与决策

- [x] 分发渠道需求讨论入口落档 — `docs/2-产品/需求讨论/分发渠道.md` — 2026-07-04
  > 实现：将 App Store、Direct、Sparkle、双打包脚本和教程需求收敛到分发渠道主线。
- [x] 分发渠道正式方案落档 — `docs/2-产品/需求讨论/正式方案/分发渠道正式方案.md` — 2026-07-04
  > 实现：明确 Sparkle 只进入 Direct build，App Store build 完全不包含 Sparkle。
- [x] 分发渠道详细设计落档 — `docs/3-设计/详细设计/41-分发渠道详细设计.md` — 2026-07-04
  > 实现：定义 target/scheme、Info.plist、entitlements、appcast 和打包脚本设计。
- [x] 初始 appcast 静态文件落档 — `pages/appcast.xml` — 2026-07-04
  > 实现：提供可部署的空 Sparkle feed，避免真实 DMG 签名前发布错误更新。

---

## 2. 渠道基础

- [x] `DistributionChannel` — `Starcat/Core/Distribution/DistributionChannel.swift` — 2026-07-04
  > 实现：通过 `STARCAT_DISTRIBUTION` 显式注入渠道，非法或缺省值保守回退 App Store。
- [x] App Store target / scheme — `project.yml` — 2026-07-04
  > 实现：保留 `Starcat` 作为 App Store 构建入口，不链接 Sparkle。
- [x] Direct target / scheme — `project.yml` — 2026-07-04
  > 实现：新增 `StarcatDirect` target/scheme，使用独立 bundle id 和 Direct entitlements。
- [x] App Store / Direct Info.plist 渠道注入 — `project.yml` — 2026-07-04
  > 实现：两个渠道都写入 `STARCAT_DISTRIBUTION`，Direct 额外写入 Sparkle appcast 配置。
- [x] 渠道读取单测 — `StarcatTests/DistributionChannelTests.swift` — 2026-07-04
  > 实现：覆盖缺省、Direct 大小写/空白归一化、非法值回退。
- [x] 渠道能力门控 — `Starcat/Core/Distribution/DistributionGate.swift` — 2026-07-10
  > 实现：新增 `DistributionGate` 区分构建渠道能力和 Pro 权益；App Store 拒绝 Direct-only 能力，Direct 统一放行。
- [x] 渠道能力门控规范 — `docs/5-规范/分发渠道能力门控规范.md` — 2026-07-10
  > 实现：单独沉淀 Direct-only 功能写法、禁止写法和新增能力 checklist，详细设计只保留引用。

---

## 3. Sparkle

- [x] Sparkle SPM 只接入 Direct target — `project.yml` — 2026-07-04
  > 实现：`Sparkle` 只在 `StarcatDirect.dependencies` 中声明，App Store 产物无 Sparkle framework。
- [x] Direct entitlements 与 App Store sandbox 分离 — `Starcat/StarcatDirect.entitlements` — 2026-07-04
  > 实现：Direct 版使用独立 entitlement 文件且不启用 App Sandbox，App Store 版继续使用 `Starcat.entitlements`。
- [x] Direct Info.plist 注入 `SUFeedURL` — `Starcat/Generated/Info.direct.generated.plist` — 2026-07-04
  > 实现：Direct appcast 指向 `https://starcat.ink/appcast.xml`。
- [x] Direct Info.plist 注入 `SUPublicEDKey` — `Configs/Build.xcconfig` — 2026-07-04
  > 实现：公钥通过 `STARCAT_SPARKLE_PUBLIC_ED_KEY` 注入，默认空值时不启动 updater。
- [x] `DirectUpdateController` — `Starcat/Core/Updates/DirectUpdateController.swift` — 2026-07-04
  > 实现：Direct + 公钥已配置时才创建 `SPUStandardUpdaterController`。
- [x] Direct-only `Check for Updates...` 菜单 — `Starcat/App/StarcatApp.swift` — 2026-07-04
  > 实现：仅 Direct 渠道展示检查更新入口，未配置公钥时按钮禁用。
- [x] About 开源致谢登记 Sparkle — `Starcat/Features/About/AboutView.swift` — 2026-07-04
  > 实现：按开源致谢同步规则登记 Sparkle MIT 许可。

---

## 4. 打包脚本

- [x] `scripts/package-appstore.sh` — `scripts/package-appstore.sh` — 2026-07-04
  > 实现：生成 App Store archive，并检查产物不包含 Sparkle。
- [x] `scripts/package-direct.sh` — `scripts/package-direct.sh` — 2026-07-04
  > 实现：构建 Direct Release、生成 DMG/SHA256，并支持可选 notarization 和 appcast。
- [x] App Store 产物自检 — `scripts/package-appstore.sh` — 2026-07-04
  > 实现：脚本检查 `STARCAT_DISTRIBUTION=appstore`、无 Sparkle 文件和动态链接。
- [x] Direct 产物自检 — `scripts/package-direct.sh` — 2026-07-04
  > 实现：脚本检查 `STARCAT_DISTRIBUTION=direct` 且包含 Sparkle framework。
- [x] Sparkle appcast 生成流程 — `scripts/package-direct.sh` — 2026-07-04
  > 实现：`STARCAT_GENERATE_APPCAST=1` 时调用 Sparkle `generate_appcast` 更新 `pages/appcast.xml`。
- [x] DMG notarization / staple 流程 — `scripts/package-direct.sh` — 2026-07-04
  > 实现：`STARCAT_NOTARIZE=1` 时执行 `notarytool submit --wait`、`stapler staple` 与 `spctl` 校验。

---

## 5. 打包教程

- [x] `docs/6-发版与上架/App Store 打包教程.md` — `docs/6-发版与上架/App Store 打包教程.md` — 2026-07-04
  > 实现：覆盖前置条件、脚本产物、上传 App Store Connect 和渠道自检。
- [x] `docs/6-发版与上架/Direct 打包教程.md` — `docs/6-发版与上架/Direct 打包教程.md` — 2026-07-04
  > 实现：覆盖 Sparkle 公钥、DMG、notarization、appcast 和更新验证。
