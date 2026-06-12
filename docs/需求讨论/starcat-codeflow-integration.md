# Starcat 集成 CodeFlow 方案

> 本文档取代原 CodeGraphContext 方案。目标是保留最短链路：clone 仓库，点击一次，在默认浏览器直接看到代码可视化结果。

## 1. 最终链路

```text
用户点击「代码图谱」
        ↓
/usr/bin/git clone --depth=1（目录存在则跳过）
        ↓
Starcat 扫描仓库中的受支持文本源码
        ↓
把源码注入内置 CodeFlow HTML
        ↓
默认浏览器打开生成页
        ↓
CodeFlow 自动分析并展示图谱
```

用户不需要：

- 安装或配置 CodeGraphContext；
- 在 CodeFlow 页面再次选择本地目录；
- 输入刚 clone 的项目路径；
- 使用 MCP、WebView 或本地服务。

## 2. 为什么必须修改 CodeFlow

CodeFlow 原版通过 `showDirectoryPicker()` 或 `<input webkitdirectory>` 获取本地文件。浏览器安全模型要求该操作由用户手势触发，网页不能根据 URL 参数直接读取任意本地路径。

因此不能简单执行：

```text
open index.html?path=/path/to/repo
```

这类路径参数不会获得目录读取权限。

Starcat 的处理方式是不让浏览器读取路径：由 Starcat 自己读取 clone 目录，把文件路径和文本内容编码成 JSON，再注入 CodeFlow 页面。CodeFlow 启动后把注入数据恢复成浏览器 `File[]`，继续调用原版 `readLocalFolderFromFiles` 完成分析。

## 3. 本地目录

仓库缓存：

```text
~/Library/Application Support/Starcat/repos/github.com/<owner>/<repo>/
```

生成页面：

```text
~/Library/Application Support/Starcat/codeflow/<owner>/<repo>/index.html
```

仓库目录存在时直接复用，不做 fetch、pull、分支判断或更新检测。

## 4. CodeFlow 改造

内置资源：

```text
Starcat/Resources/CodeFlow/codeflow.html
```

固定上游提交：

```text
51ab9708841e14258bebfb5fb326e8b37782d193
```

Starcat 只增加一个注入协议：

```js
window.__STARCAT_CODEFLOW_PROJECT_BASE64__ = "...";
```

页面启动后：

1. Base64 解码 JSON；
2. 为每个源码文件构造浏览器 `File`；
3. 设置 `webkitRelativePath`；
4. 自动调用 `readLocalFolderFromFiles`；
5. 直接进入 CodeFlow 图谱页面。

其余分析器、依赖识别、图谱渲染和导出逻辑保持上游实现。

## 5. 文件筛选

Starcat 只注入 CodeFlow 支持的源码和 Markdown 文本，并跳过：

- `.git`、`.build`、`build`、`dist`；
- `DerivedData`、`node_modules`、`Pods`、`vendor`；
- 隐藏文件和 package descendants；
- 单文件超过 1 MB 的文件；
- 非 UTF-8 文本。

当前总文本上限为 50 MB，超过后停止并提示，避免生成过大的 HTML 导致浏览器内存失控。

## 6. UI

详情页保留「代码图谱」按钮。点击后弹出三步面板：

1. 拉取仓库；
2. 准备 CodeFlow 页面；
3. 浏览器打开。

支持取消、失败重试和重新打开。CodeFlow 不再出现在设置页，因为没有任何用户配置项。

## 7. 明确不做

- 不嵌入 WKWebView；
- 不运行本地 HTTP Server；
- 不通过路径参数绕过浏览器权限；
- 不做仓库更新、分支管理和任务持久化；
- 首版不支持私有仓库；
- 不改 CodeFlow 的分析算法和图谱 UI。

## 8. 开源合规

CodeFlow 上游仓库 README 声明 MIT，但固定提交中没有 `LICENSE` 文件。Starcat 保留完整上游 README，并在 `STARCAT-INTEGRATION.md`、About Credits 中如实记录来源、提交和许可证现状，不伪造不存在的版权行。

## 9. 验收标准

- [ ] 公开仓库首次点击后完成 shallow clone；
- [ ] 已 clone 仓库再次点击时跳过 clone；
- [ ] 默认浏览器自动打开生成的 CodeFlow 页面；
- [ ] 页面无需点击 Open Folder 或输入路径；
- [ ] 页面加载后自动开始分析并展示图谱；
- [ ] 设置页不再出现 CGC / CodeFlow 路径配置；
- [ ] 私有仓库不展示代码图谱入口；
- [ ] 超过 50 MB 时给出明确错误，不生成超大页面。
