# 分发渠道专项 Checklist

> 创建：2026-07-04
> 状态：待实施
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

- [ ] `DistributionChannel`
- [ ] App Store target / scheme
- [ ] Direct target / scheme
- [ ] App Store / Direct Info.plist 渠道注入
- [ ] 渠道读取单测

---

## 3. Sparkle

- [ ] Sparkle SPM 只接入 Direct target
- [ ] Direct entitlements 增加 Sparkle installer mach lookup
- [ ] Direct Info.plist 注入 `SUFeedURL`
- [ ] Direct Info.plist 注入 `SUPublicEDKey`
- [ ] `DirectUpdateController`
- [ ] Direct-only `Check for Updates...` 菜单
- [ ] About 开源致谢登记 Sparkle

---

## 4. 打包脚本

- [ ] `scripts/package-appstore.sh`
- [ ] `scripts/package-direct.sh`
- [ ] App Store 产物自检
- [ ] Direct 产物自检
- [ ] Sparkle appcast 生成流程
- [ ] DMG notarization / staple 流程

---

## 5. 打包教程

- [ ] `docs/6-发版与上架/App Store 打包教程.md`
- [ ] `docs/6-发版与上架/Direct 打包教程.md`

