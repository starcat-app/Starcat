# 关注关系图谱离线渲染资源

这是 App 内 WKWebView 的渲染层，不是独立网站，不发起 GitHub API 请求。
凭据、图合并、路径、分页和缓存均由原生 Swift 层持有。

## 2D 渲染

`force-graph 1.52.0` 使用 Canvas 绘制，`d3-force-3d 3.0.6` 仅执行二维力计算与碰撞检测。
不包含 Three.js、WebGL、透视相机或旋转控制。平移缩放在同一原生模型会话内恢复。
`bezier-js 6.1.4` 上游未提供独立 LICENSE 文件，`notices/` 保留该固定版本的原始作者与 MIT 声明及 MIT 条款，构建时一并打包。

## 重建

```bash
cd resources/follow-graph
npm ci
npm run build
npm test
```

`package-lock.json` 锁定直接与传递依赖。构建结果及完整第三方许可证随 App
离线打包，不依赖运行时 CDN。更新依赖时同步维护 AboutDependency 和许可证清单。

头像仅从 `avatars.githubusercontent.com` 加载，失败使用本地首字母占位。
Swift 与页面只交换白名单消息；页面不持有 Token，也不能打开外部链接。
