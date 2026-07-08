# App Store 合规域名隔离改造

> 创建：2026-07-09
> 状态：待实施
> 背景：Starcat 需要同时支持 App Store 和 Direct / 非 App Store 两套分发。`starcat.ink` 当前承担 Direct 官网、下载、Sparkle appcast、Creem / License 支付等职责，不适合作为 App Store metadata 的营销 / 技术支持入口。App Store 版需要单独使用不含外部购买引导的合规页面。

---

## 1. 目标

建立 App Store 专用域名与页面：

```text
https://dong4j.app/starcat
https://dong4j.app/starcat/support
https://dong4j.app/starcat/privacy
https://dong4j.app/starcat/eula
```

这些页面用于 App Store Connect：

| 字段 | URL |
|------|-----|
| 技术支持网址 | `https://dong4j.app/starcat/support` |
| 营销网址 | `https://dong4j.app/starcat` |
| 隐私政策 | `https://dong4j.app/starcat/privacy` |
| EULA / 用户协议 | `https://dong4j.app/starcat/eula` |

---

## 2. 页面内容策略

`dong4j.app/starcat/*` 可以基于 `starcat.ink` 现有页面裁剪，但必须移除 Direct / 外部支付相关内容。

### 2.1 可以保留

- Starcat 功能介绍。
- GitHub Stars 管理、搜索、标签、笔记、Release、AI Pro 能力说明。
- App Store 版免费 / Pro 功能边界。
- Support 邮箱：`dong4j@gmail.com`。
- 隐私政策、EULA、第三方服务说明。
- App Store / StoreKit / Apple IAP 相关订阅说明。

### 2.2 必须移除

- Creem / Waffo / 其他外部支付 provider。
- Lifetime / 买断 / 官网购买按钮。
- Direct 下载 DMG。
- License Key 激活。
- Sparkle 自动更新说明。
- `https://starcat.ink/downloads/*`。
- `https://starcat.ink/appcast.xml`。
- 任何暗示用户绕过 Apple IAP 购买 Pro 的 CTA。

---

## 3. 域名职责边界

| 域名 | 职责 |
|------|------|
| `dong4j.app` | App Store 合规产品页集合，面向 Apple 审核和 App Store 用户 |
| `starcat.ink` | Starcat Direct 官网、DMG 下载、Sparkle appcast、Direct 支付和 License API 相关落地页 |

后续如果有其他 App Store 应用，继续挂在 `dong4j.app/<app-slug>` 下。

---

## 4. App 内链接改造方向

应用内域名需要按分发渠道隔离，不能继续把所有可点击链接都硬编码到 `starcat.ink`。

建议新增集中入口：

```text
AppExternalLinks
```

或：

```text
AppWebsiteLinks
```

由它根据 `DistributionChannel.current` 返回 URL：

| 链接类型 | App Store build | Direct build |
|----------|-----------------|--------------|
| product / marketing | `https://dong4j.app/starcat` | `https://starcat.ink` |
| support | `https://dong4j.app/starcat/support` | `https://starcat.ink/support` |
| privacy | `https://dong4j.app/starcat/privacy` | `https://starcat.ink/privacy` |
| eula | `https://dong4j.app/starcat/eula` | `https://starcat.ink/eula` |
| appcast | 不存在 | `https://starcat.ink/appcast.xml` |
| downloads | 不存在 | `https://starcat.ink/downloads/` |
| checkout | StoreKit only | Starcat License API / Direct checkout |

---

## 5. 需要扫描和改造的位置

后续实施前先扫描：

```bash
rg "starcat\\.ink|support|privacy|eula|appcast|downloads|checkout|license" Starcat pages docs scripts project.yml
```

重点检查：

1. About / Support / Privacy / EULA 链接。
2. Pro 设置页和 Pro 付费墙。
3. 分享卡、HTML / Markdown 导出、底部品牌链接。
4. App Store metadata 文档。
5. Direct Sparkle 配置 `SUFeedURL`。
6. Direct License / checkout / success 页面。

Direct-only 链接继续保留 `starcat.ink`；App Store 用户可见链接改为 `dong4j.app/starcat/*`。

---

## 6. 实施 Checklist

- [ ] 购买并配置 `dong4j.app` 域名。
- [ ] 部署 `https://dong4j.app/starcat`。
- [ ] 部署 `https://dong4j.app/starcat/support`。
- [ ] 部署 `https://dong4j.app/starcat/privacy`。
- [ ] 部署 `https://dong4j.app/starcat/eula`。
- [ ] 从 App Store 专用页面中移除 Direct 支付 / Lifetime / Creem / DMG 下载 / Sparkle 内容。
- [x] 新增 App 内链接集中入口 `AppWebsiteLinks`。
- [x] App Store build 链接指向 `dong4j.app/starcat/*`。
- [x] Direct build 链接继续指向 `starcat.ink/*`。
- [x] 复查分享导出内容，避免 App Store build 导出的页面引导到 Direct 购买页。
- [ ] 更新 App Store Connect：Support URL / Marketing URL / Privacy URL。
- [ ] 更新 `docs/6-发版与上架/SOP-App-Store-首次上架流程.md`。

---

## 7. 关联文档

| 文档 | 关系 |
|------|------|
| `docs/6-发版与上架/SOP-App-Store-首次上架流程.md` | App Store Connect URL 字段和审核流程 |
| `docs/6-发版与上架/SOP-双渠道签名与发布.md` | App Store / Direct 双渠道边界 |
| `docs/2-产品/需求讨论/正式方案/支付对接正式方案.md` | App Store StoreKit-only 与 Direct provider-neutral 支付边界 |
| `docs/6-发版与上架/Creem-双环境配置.md` | Direct 版 Creem / License API 配置 |

---

## 8. 变更日志

| 日期 | 变更 |
|------|------|
| 2026-07-09 | 初版：记录 `dong4j.app` App Store 专用域名与 App 内渠道域名隔离改造事项 |
