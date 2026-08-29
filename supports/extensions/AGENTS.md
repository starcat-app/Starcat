# AGENTS.md

本文档是 `supports/extensions/` 的唯一 AI 协作规范源。

## 项目与仓库边界

- `starcat-chrome-plugin`：Chrome / Chromium WebExtension。
- `starcat-safari-plugin`：Safari WebExtension。

两个目录都是独立 Git 仓库，拥有各自的 remote、分支、CI 和发布边界。修改前必须在
目标仓库执行 `git status -sb`，并读取目标仓库根 `AGENTS.md`；禁止把插件改动加入
Starcat 主仓库提交。

## 技术与安全边界

- 两端均使用 WebExtension Manifest V3 与原生 JavaScript、HTML、CSS，不需要构建步骤。
- Chrome 使用 `chrome.*`；Safari 使用 `globalThis.browser || globalThis.chrome` 兼容层。
- 插件只能通过 loopback `/plugin/v1/*` 与 Starcat macOS Companion API 通信。
- Safari content script 必须经 `src/background/background.js` 访问本地 API，以适配更严格的 CORS。
- 禁止绕过 Companion API 直连 GitHub、Starcat 云端、AI Provider 或读取本地数据库。

## 双端同步铁律

修改任一端的功能、manifest 权限、content script、共享 API helper、CSS、popup 或
options page 时，必须检查并同步另一端；只有任务明确限定单浏览器时才允许差异。

## 验证与发布

- `manifest.json` 使用 `python3 -m json.tool` 校验。
- 所有 JavaScript 使用 `node --check` 校验，并执行目标仓库 README/CI 规定的检查。
- 未经 dong4j 明确授权，禁止打包、push tag、创建 GitHub Release、上传 Chrome Web Store
  或提交 App Store Connect。
- 两端商店材料仍处于 No-Go 时，不得把临时扩展或源码 ZIP 表述为正式发布产物。
