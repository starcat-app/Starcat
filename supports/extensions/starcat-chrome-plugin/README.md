# Starcat Chrome Plugin

Starcat Chrome Plugin 是 Starcat 的 GitHub 页面增强插件。它只在 GitHub repo 页面展示 Starcat 已有上下文, 不直接访问 GitHub API、Starcat 后端、OpenSSF 或 AI provider。

## 功能范围

- 在 GitHub repo 页面展示相似仓库推荐。
- 展示已收录的 Wiki 入口。
- 读取、保存 Starcat 私人笔记。
- 展示 Starcat 已缓存的 Health / OpenSSF 分数。
- 触发 Starcat App 内的 CodeFlow / Codebase 动作。

## 本地加载

1. 在 Chrome 打开 `chrome://extensions/`。
2. 开启 Developer mode。
3. 点击 Load unpacked。
4. 选择本目录: `supports/extensions/starcat-chrome-plugin`。
5. 打开插件 Options, 填入 Starcat Companion 本机服务端口和 bearer token。
6. 点击 Test Connection。

## 通信边界

插件只通过 Starcat App 暴露的本机 HTTP 服务通信:

```text
http://127.0.0.1:{port}/plugin/v1
```

所有业务请求都需要:

```text
Authorization: Bearer <companion-token>
```

Companion token 只授权本机 loopback 接口, 不等同于 GitHub token、AI key 或 Starcat 后端 API key。

## 文件说明

| 文件 | 说明 |
|---|---|
| `manifest.json` | Chrome MV3 入口声明。 |
| `LICENSE` | 开源许可证。 |
| `PRIVACY.md` | 隐私与数据边界说明。 |
| `SECURITY.md` | 安全边界与漏洞反馈说明。 |
| `CONTRIBUTING.md` | 本地开发与贡献约定。 |
| `CHANGELOG.md` | 版本变更记录。 |
| `src/shared/shared.js` | 配置读写、GitHub repo URL 解析、本机 API client。 |
| `src/options/` | 端口、token 配置与连接测试页。 |
| `src/content/` | GitHub repo 页面板注入与渲染。 |

## 验证

```bash
python3 -m json.tool supports/extensions/starcat-chrome-plugin/manifest.json >/dev/null
node --check supports/extensions/starcat-chrome-plugin/src/shared/shared.js
node --check supports/extensions/starcat-chrome-plugin/src/options/options.js
node --check supports/extensions/starcat-chrome-plugin/src/content/content-script.js
```
