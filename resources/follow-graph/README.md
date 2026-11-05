# 关注关系图谱离线渲染资源

这是 App 内 WKWebView 的渲染层，不是独立网站，不发起 GitHub API 请求。
凭据、图合并、路径、分页和缓存均由原生 Swift 层持有。
渲染器在点击时用当前已加载边即时计算同规则路径，避免等待 UI 回传时缺少第一跳。

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

## 展示动画与测试

- 选中路径使用统一相位的流水光带，额外帧任务仅在需要时运行。
- `progressive-reveal.mjs` 按关系层级逐步放出头像；缓存和网络批次共享队列，
  大图逐渐加速，实际显示数量经带 revision 的 progress 消息交回原生。
- Reduce Motion 直接完成入场并保留静态路径；后台暂停、关闭释放全部展示任务。
- `npm test` 覆盖真实渲染入口和纯队列；Canvas 组件 API 使用替身，
  不等同于真实 WebKit 点击或帧率 / 外观验收。
