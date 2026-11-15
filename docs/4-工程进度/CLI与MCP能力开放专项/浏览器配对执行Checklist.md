# 浏览器配对执行 Checklist

> 状态：B1 与 Chrome 可选 CLI 通道已实施，真实浏览器与原生分发组合待验收
> 工作区：`../Starcat-cli-browser-access`，App / Chrome / Safari / CLI 各自独立 worktree
> 子方案：[浏览器免输Key配对与自动发现子方案.md](浏览器免输Key配对与自动发现子方案.md)

## 执行批次

- [x] BROWSER-01 创建隔离工作区，核对 Companion、MCP 和两端插件基线与权限
- [x] BROWSER-02 120 秒 / 六位码 / 256 bit 秘密 / Origin / 单次领取 / 终态契约已实施
- [x] BROWSER-03 独立 Companion Keychain 与 scope，保留全局 Key 和 MCP 邀请
- [x] BROWSER-04 discover / 配对 / revoke-current 与设备 SSE 终止已实现并有 App 单测
- [x] BROWSER-05 App 核对 / 名称 / 访问时间 / rename / revoke 已实现；19 key × 17 语言，译文 needs_review
- [x] BROWSER-06 双端稳定配对页与有限发现已实现；真实 Profile / 后台生命周期仍待验收
- [x] BROWSER-07 手工 Key、高级地址、旧 5001 和离线仅本地清除已保留，VM 有控制流证据
- [ ] BROWSER-08 验证 Native Messaging / Safari 原生宿主与两渠道矩阵，按可行结果接入 CLI
- [x] BROWSER-09 App 配对单测及 26 项双端 VM 覆盖终态、来源、隔离、保存失败及多实例明确选择；脚本为 `scripts/test-browser-pairing.mjs`，不冒充真实 Profile
- [x] BROWSER-10 双端全部 JS / manifest、App 定向单测与双渠道构建通过，真实浏览器 / Profile / 签名验收门禁已单列

## 验证记录

六位码仅用于人工核对；发现不等于认证；设备撤销必须同时覆盖新请求与现有事件连接。未验证的沙盒、浏览器配置隔离与分发行为不标记完成。

详见[平台矩阵与交付记录](验证与交付记录.md)。BROWSER-08 保留未完成：Chrome host 已有 Go / VM 证据，Safari 无原生宿主，签名安装未验收。BROWSER-10 的本地检查已完成；真实 GUI 与发布没有授权，不推断已验收。
