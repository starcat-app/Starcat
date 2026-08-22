# README 详情页视频播放方案

> 状态：实现完成，待人工验收
> 日期：2026-08-22
> 关联：[GitHub Issue #107](https://github.com/starcat-app/Starcat/issues/107)
> 范围：Starcat macOS 客户端所有复用 `ReadmeWebView` 的仓库 README 详情页

## 1. 问题与根因

Starcat 通过 GitHub README HTML API 获取已经渲染的 HTML，并把 `rendered_html` 长期缓存到本地数据库。GitHub 上传的视频会被渲染为带原生 controls 的 `<video src="...">`，但 `src` 指向短时效签名地址。该地址在 README 缓存仍然有效时已经可能过期，导致视频无法加载。

因此，本功能不能只调整 WKWebView 播放开关。完整修复必须同时处理视频地址持久化、WebView 播放策略和页面销毁时的媒体生命周期。

## 2. 方案结论

继续复用现有 `NSViewRepresentable + WKWebView`，不引入 `AVPlayer`、第三方播放器或新的媒体状态模型。

实现分为三层：

1. IO 层把 GitHub 短时效视频地址转换为稳定 attachment URL，再写入 README 缓存。
2. WebView 层使用 HTML5 原生 controls，并明确要求用户手势后才能播放。
3. 生命周期层在切换 README 或销毁 WebView 时主动暂停媒体并停止加载。

## 3. 支持范围

首期支持：

- GitHub README HTML API 输出的 `<video src="...">`。
- GitHub `user-attachments` 上传的 MP4、WebM 等 WebKit 可解码格式。
- 使用 HTTPS 直链、且能由 WebKit 直接解码的 HTML5 视频。
- 原生播放、暂停、进度拖动、音量与全屏 controls。

首期不支持：

- YouTube、B 站、Vimeo 等 iframe 或脚本播放器。
- DRM、转码、离线下载和视频文件本地缓存。
- 自动播放。
- 向 WKWebView 子资源请求注入 GitHub OAuth token。

不支持的第三方视频链接继续走现有 `linkActivated -> NSWorkspace.open`，在系统浏览器打开。

## 4. 视频地址规范化

扩展现有 `ReadmeAssetURLRewriter`，保留图片规则并增加 `<video src>` 处理。

### 4.1 GitHub attachment

GitHub HTML API 返回的短时效地址具有以下特征：

- host 为 `private-user-images.githubusercontent.com`。
- path 的文件名包含标准 UUID。
- query 中包含短时效签名参数。

从 path 提取 UUID 后，转换为稳定地址：

```text
https://github.com/user-attachments/assets/<UUID>
```

稳定地址由 GitHub 在请求时重新重定向到当前有效的媒体资源，避免把过期签名长期保存在 `rendered_html`。

### 4.2 保守规则

- UUID 无法可靠提取时保持原地址，不猜测、不截断。
- 普通 HTTPS 视频地址保持原样。
- 图片 URL 继续执行现有相对路径和 raw URL 修复规则。
- 不处理 iframe、script 和 object。

### 4.3 旧缓存修复

`ReadmeAPI` 已在 cache hit、200、304、Trending promote 和无条件刷新路径调用 `ReadmeAssetURLRewriter`。视频规则加入同一入口后，旧缓存会在读取或刷新时惰性修复并重新落库，不新增数据库字段或 migration。

## 5. WebView 播放策略

macOS 的 WKWebView 默认在页面内承载 HTML5 视频；macOS SDK 不提供 iOS 侧的 `allowsInlineMediaPlayback`。这里只显式要求媒体必须由用户手势启动：

```swift
config.mediaTypesRequiringUserActionForPlayback = .all
```

app-owned `WKUserScript` 在 document end 统一规范视频节点：

- 移除 `autoplay`。
- 设置 `autoplay = false`。
- 显示 `controls`。
- 设置 `preload="metadata"`，避免 README 首屏下载全部视频。
- 设置 `playsinline`，明确保留 HTML5 页内播放语义。

页面自己的脚本仍由 CSP `script-src 'none'` 禁止。CSP 显式增加 `media-src https:`，不放开第三方脚本、iframe 或 object。

视频 CSS 只负责布局：最大宽度不超过 README 正文，保持原始宽高比，使用与现有图片一致的克制圆角。播放器 controls 使用 WebKit 原生样式，不新增 SwiftUI 覆盖层。

## 6. 生命周期

切换仓库或重新加载 README 前：

1. 调用 `pauseAllMediaPlayback`。
2. 再执行现有 `loadHTMLString` 流程。

销毁 `ReadmeWebContentView` 时：

1. 调用 `pauseAllMediaPlayback`。
2. 调用 `stopLoading`，终止未完成的媒体请求。
3. 清理现有 script message handlers 和 Mermaid task。

这套处理覆盖主详情页、探索/活动等复用详情页，以及独立 README 窗口，不在各调用方重复维护播放状态。

## 7. 安全与隐私边界

- 页面脚本继续禁用，只有 Starcat 自己注入的 WKUserScript 可以执行。
- 仅允许 HTTPS 媒体，不主动降级到 HTTP。
- 不向媒体请求附加 OAuth token、API Key 或其他本地凭据。
- 不记录完整签名 URL、query 或媒体内容到业务日志。
- 不新增第三方依赖，不扩大 App Sandbox entitlement。

## 8. 测试与验收

### 8.1 自动化测试

- `ReadmeAssetURLRewriterTests`：覆盖签名 URL 转稳定 attachment URL、UUID 解析失败保持原样、普通 HTTPS 视频不改写和图片规则回归。
- `ReadmeAPINetworkTests`：覆盖 cache hit 修复旧视频地址并重新落库，以及 304 路径不保留过期地址。
- `ReadmeWebViewTests`：覆盖视频 CSS、CSP、controls、禁止 autoplay 和现有图片/Mermaid/翻译脚本不回退。
- 定向测试通过后运行完整 `StarcatTests`。

### 8.2 人工验收

- 主详情页与独立 README 窗口均可播放、暂停和拖动进度。
- 浅色、深色模式下播放器宽度、圆角和正文布局正常。
- README 首屏不自动播放，也不一次性预加载全部视频内容。
- 切换仓库后旧视频立即停止。
- 关闭独立窗口后不残留声音或媒体请求。
- 不支持的第三方视频链接仍在系统浏览器打开。

## 9. 预计文件范围

- `Starcat/Core/Network/GitHubAPI/ReadmeAssetURLRewriter.swift`
- `Starcat/Core/Network/GitHubAPI/ReadmeAPI.swift`，仅同步必要注释
- `Starcat/Shared/Components/ReadmeWebView.swift`
- `StarcatTests/ReadmeAssetURLRewriterTests.swift`
- `StarcatTests/ReadmeAPINetworkTests.swift`
- `StarcatTests/ReadmeWebViewTests.swift`

不修改数据库 schema，不新增依赖，不改 `docs/功能实现总览.md`。
