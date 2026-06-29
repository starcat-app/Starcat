# V2EX

## 发帖角度

V2EX 不适合广告口吻。这里的用户会关心你为什么做、具体解决什么痛点、有没有真实截图、是不是又一个套 AI 的壳。建议发在 `/go/create` 或 `/go/programmer`,也可以根据讨论转到 `/go/macos`。

## 标题备选

- 做了一个 macOS 上的 GitHub Stars 管理和 AI 分析工具,想听听大家的建议
- GitHub Stars 越攒越乱,我做了个原生 macOS 工具来整理它
- 分享一个自己做的 GitHub repo 研究工具: Starcat

## 正文草稿

最近一直在做一个 macOS 小工具,叫 Starcat。

起因挺简单: 我自己的 GitHub Stars 已经快两千个了。刚开始 star 是收藏,后来就变成了"以后再看"的垃圾桶。真要找一个以前看过的 CLI、Swift 库、AI agent 项目,经常只能靠 GitHub 搜索和模糊记忆,效率很低。

所以 Starcat 第一版先做了几件事:

- 把 GitHub Stars 同步到本地,用三栏界面管理。
- 本地缓存 README,可以直接在 App 里阅读。
- 给 repo 加标签、笔记、阅读状态。
- 支持按语言、Smart Collections、全文搜索、语义搜索找回项目。
- 对单个 repo 做 AI 摘要、标签建议、README 翻译和对话。
- 跟踪 Release、Activity、Weekly,尽量把"项目发生了什么"放回同一个地方。

我不想把它做成另一个 GitHub 客户端。GitHub 网页已经很好,Starcat 更像是一个本地优先的开源项目知识库: 你 star 过什么、为什么 star、适不适合某个场景、后来有没有替代品,这些东西都应该能被整理和找回。

截图:

![管理视图](assets/01-manage-ungrouped.png)

![详情页](assets/02-repo-detail-readme.png)

后续想做的方向也比较明确: 不是泛 AI Chat,而是围绕 stars 库做"整理、发现、消化"三条线。

整理: 批量整理 untagged、合并相似标签、扫描重复/长期不用的 repo。
发现: 相似仓库推荐、替代品发现、技术选型报告。
消化: Stars 周报、Release 升级建议、回忆搜索、笔记草稿。

目前相似仓库推荐已经有第一版入口,后端先通过自建 `recommend-api` 中转,后续再替换成自研推荐。Agent 方向还在设计阶段,不会把未完成的东西说成已上线。

想听听大家几个问题:

1. 你们现在怎么管理 GitHub Stars?
2. "AI 摘要/标签建议"这类功能,对你是真的有用,还是更像噱头?
3. 如果做技术选型 Agent,你更希望它输出什么: 对比表、风险清单、还是可保存的调研报告?

如果你也有一堆 stars 不知道怎么处理,欢迎拍砖。
