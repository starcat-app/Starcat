# Agent Skill 目录与标识来源

这些路径用于识别用户级安装位置，工作区专属目录不自动写入用户主目录。来源于
[Vercel Skills](https://github.com/vercel-labs/skills/blob/b716f9dc2ba36b6aa8f0080615e5a3a6caeac63b/src/agents.ts)
提交 `b716f9dc2ba36b6aa8f0080615e5a3a6caeac63b`；实际工具、目录覆盖及检测规则在
`RepoSkillAgentCatalog.swift` 中维护。通用目录是 `~/.agents/skills`，与之共用目录的
工具只执行一次磁盘操作。Vercel Skills 的 MIT 许可副本见 `VercelSkills-LICENSE.txt`。

`Assets.xcassets/SkillAgents` 中的图标保留上游轮廓与品牌颜色：

- `@lobehub/icons-static-svg` 1.102.0（MIT）：除下列条目外的矢量图；有 `-color.svg` 时优先使用原始彩色版本，许可见 `LobeIcons-LICENSE.txt`。
- [Simple Icons](https://github.com/simple-icons/simple-icons/tree/16.37.0) 16.37.0（CC0）：Warp、Zed、Posit、Atlassian；Warp、Posit、Atlassian 的填充色取自同版本 `data/simple-icons.json` 的 `hex`，分别为 `#01A4FF`、`#447099`、`#0052CC`。
- [Augment Code](https://www.augmentcode.com/favicon.svg)、
  [Factory](https://factory.ai/favicon.svg)、[Firebender](https://firebender.com/icon.svg)、
  [Ona](https://ona.com/ona-dark-favicon.svg)、[Autohand](https://autohand.ai/favicon.svg)、
  [Continue](https://www.continue.dev/favicon.png)、
  [Lingma](https://img.alicdn.com/imgextra/i1/O1CN01BN6Jtc1lCfJNviV7H_!!6000000004783-2-tps-134-133.png)、
  [Mux](https://mux.coder.com/)：各产品公开的品牌标识，仅用于识别相应工具。
- iFlow 复用 `AIProviders/iflow.imageset` 的现有素材；没有品牌素材时优先使用本机应用图标，再使用终端占位图。

彩色标识使用 original rendering；品牌本身的单色标识使用 template rendering，跟随界面文字色适配明暗主题。Kimi 与 Qoder 的深色资源仅将上游 `currentColor` 替换为 `#F5F5F7`，保留蓝色、绿色部分及路径不变；不对品牌素材做统一染色。所有胶囊使用同一图标槽位，Command Code 额外内缩 1pt 校正铺满画布的轮廓。

品牌名称和标识均归各自所有者所有；在本面板使用不表示其与 Starcat 存在合作或背书关系。
