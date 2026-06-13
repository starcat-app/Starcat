# Starcat 集成 CodeFlow 方案

> 本文档取代 CodeGraphContext 与 Git clone 方案。最终目标：点击一次，在默认浏览器直接看到代码可视化结果。

## 1. 最终链路

```text
用户点击「代码图谱」
        ↓
URLSession 请求 GitHub /repos/{owner}/{repo}/zipball
        ↓
ZIP 缓存到 Starcat 应用容器（已有则跳过下载）
        ↓
把 ZIP Base64 注入内置 CodeFlow HTML
        ↓
默认浏览器打开生成页
        ↓
CodeFlow 使用 JSZip 自动解压、分析并展示图谱
```

用户不需要安装 Git、CodeGraphContext 或解压工具，也不需要在 CodeFlow 页面选择目录、ZIP 或输入路径。

## 2. 为什么不用 Git

Mac App Store 要求 App Sandbox。沙箱中的 `/usr/bin/git clone` 会间接调用 `xcrun`，实际报错：

```text
xcrun: error: cannot be used within an App Sandbox.
```

这不是 Git 路径或权限位问题，继续配置用户 Git 环境也无法解决。因此仓库获取改成标准 HTTPS：

```http
GET https://api.github.com/repos/{owner}/{repo}/zipball
Accept: application/vnd.github+json
Authorization: Bearer <GitHub OAuth token>
```

公开仓库在无 token 时也能下载；登录态优先带现有 GitHub OAuth token，提高 API rate limit。GitHub 重定向到 archive host 时，URLSession 按跨域安全策略不转发 Authorization。

## 3. 为什么不在 Swift 中解压

CodeFlow 原版已经内置 JSZip 和 `readZipArchive`。Starcat 若再引入 ZIPFoundation 或调用 `/usr/bin/unzip`，只会增加依赖和 Sandbox 风险。

因此 Starcat 只负责下载、缓存和注入 ZIP；浏览器页面把 Base64 恢复成 `File(type: application/zip)`，直接复用 CodeFlow 原版 ZIP 分析链。

## 4. 本地缓存

ZIP 缓存：

```text
~/Library/Application Support/Starcat/archives/github.com/<owner>/<repo>.zip
```

生成页面：

```text
~/Library/Application Support/Starcat/codeflow/<owner>/<repo>/index.html
```

ZIP 已存在时直接复用，不判断分支、commit 或远端更新。当前 ZIP 上限 100 MB，避免下载和生成页面占用过多内存。

## 5. CodeFlow 改造

内置资源：

```text
Starcat/Resources/CodeFlow/codeflow.html
```

固定上游提交：

```text
51ab9708841e14258bebfb5fb326e8b37782d193
```

Starcat 增加一个 ZIP 注入协议：

```js
window.__STARCAT_CODEFLOW_ZIP_BASE64__ = "...";
```

页面启动后自动：

1. Base64 解码 ZIP；
2. 构造浏览器 ZIP `File`；
3. 调用上游 `readZipArchive`；
4. JSZip 解压并过滤代码文件；
5. 分析并展示图谱。

Starcat 注入模式跳过 CodeFlow 的大 ZIP二次确认框，确保打开后无需再次点击。分析器、依赖识别、图谱渲染和导出逻辑保持上游实现。

## 6. UI

详情页「代码图谱」面板显示三步：

1. 下载仓库 ZIP；
2. 准备 CodeFlow 页面；
3. 浏览器打开。

支持取消、失败重试和重新打开。设置页没有 Git、CGC 或 CodeFlow 配置项。

## 7. 明确不做

- 不执行 Git、xcrun 或 unzip；
- 不嵌入 WKWebView；
- 不运行本地 HTTP Server；
- 不通过路径参数绕过浏览器权限；
- 不判断分支和远端更新；
- 首版不支持私有仓库；
- 不改 CodeFlow 分析算法和图谱 UI。

## 8. 开源合规

CodeFlow 上游 README 声明 MIT，但固定提交中没有 `LICENSE` 文件。Starcat 保留上游 README，并在 `STARCAT-INTEGRATION.md` 与 About Credits 中如实记录来源和许可证现状。

## 9. 验收标准

- [ ] 沙箱中不调用 Git / xcrun；
- [ ] 首次点击通过 GitHub API 下载 ZIP；
- [ ] ZIP 已存在时跳过网络下载；
- [ ] 默认浏览器自动打开生成的 CodeFlow 页面；
- [ ] 页面不要求选择目录或 ZIP；
- [ ] 页面自动解压、分析并展示图谱；
- [ ] HTTP 错误、空 ZIP、超过 100 MB 均显示明确错误；
- [ ] 私有仓库不展示代码图谱入口。
