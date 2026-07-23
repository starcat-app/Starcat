# B 站（图文）

> 平台定位：**图文**（动态或多图文稿），不是视频。
> 账号已有。配图复用知乎 CDN；也可下载后上传 B 站图床。

---

## 发帖清单（发前必读）

| 点 | 说明 |
|---|---|
| 形态 | **动态多图**（快）或 **专栏图文**（长一点、可沉淀） |
| 图数量 | 建议 **3～5 张**；动态首图要能看清三栏或 RAG |
| 分区 / 标签 | `macOS` `GitHub` `效率工具` `独立开发` `RAG` `知识库` |
| 语气 | 像分享自己做的工具，别写成广告；求评论 |
| 别做 | 把规划中功能写成已上线；堆无图说明的功能清单 |

### 动态 vs 专栏

| | 动态图文 | 专栏 |
|---|---|---|
| 长度 | 短：痛点 + 3～4 能力 + CTA | 中：接近知乎答，可多分节 |
| 适合 | 先发一波收反馈 | 想长期搜到、结构完整时 |
| 建议 | **先发动态**；反响好再扩成专栏 | 可直接用下文「专栏稿」 |

---

## 动态图文（推荐先发）

### 标题 / 开头一句（动态往往无独立标题，用首句当钩子）

GitHub Stars 太多怎么办？我做了个能问答的 macOS 本地知识库。

### 正文

Stars 到一千八百多个以后，GitHub 自带列表只适合「收藏」，不适合「找回」和「理解」。我曾经为了找一个记不清名字的 Swift 剪贴板工具，在 Stars 页翻了很久。

所以做了 **Starcat**：macOS 原生（非 Electron），把 Stars 同步到本地，三栏管理、README 缓存、标签 / 笔记、全文 + 语义搜索。

最近加上的重点是 **知识库 RAG**：用自然语言问自己的收藏库，比如「我收藏的 SwiftUI 项目里哪些用了 Core Data？」——只在你入库的知识库里检索，回答带引用，而且是只读的，不会自动改你的标签和笔记。

AI 可以摘要、建议标签，但必须你确认才写入。数据默认在本机，模型走自己的 provider。

下载：https://starcat.ink  
开源：https://github.com/starcat-app

你们现在怎么管理 GitHub Stars？放着不管，还是会定期整理？

### 配图顺序（动态按序上传）

1. https://cdn.dong4j.site/source/image/zhihu-01-manage.webp — 管理主视图  
2. https://cdn.dong4j.site/source/image/zhihu-02-repo-detail.webp — 详情 / 笔记  
3. https://cdn.dong4j.site/source/image/zhihu-03-ai-suggest.webp — AI 建议  
4. https://cdn.dong4j.site/source/image/zhihu-04-rag-qa.webp — RAG 问答（重点）  
5. （可选）https://cdn.dong4j.site/source/image/zhihu-05-rag-citation.webp — 引用溯源  

---

## 专栏图文（可选加长版）

### 标题

我把 GitHub Stars 做成了能问答的本地知识库｜Starcat for macOS

### 备选标题

- GitHub Stars 太多怎么办？一个带 RAG 的 macOS 工具
- 从「以后再看」到可问答：Starcat 知识库

### 正文

#### 你 star 过的项目，后来找得回来吗？

Stars 动作太轻，几年下来却是信息负债。列表能收藏，却很难回答：「我当时为什么 star？」「哪些还在维护？」「我收藏里哪些用了 Core Data？」

#### Starcat 做什么

macOS 原生应用，把 Stars 变成本地开源项目知识库：同步、三栏管理、README 本地读、标签笔记、搜索、Release / Trending，以及需确认的 AI 摘要与标签建议。

![管理主视图](https://cdn.dong4j.site/source/image/zhihu-01-manage.webp)

![仓库详情](https://cdn.dong4j.site/source/image/zhihu-02-repo-detail.webp)

![AI 建议](https://cdn.dong4j.site/source/image/zhihu-03-ai-suggest.webp)

#### 质的区别：知识库 RAG

在 RAG 工作台用自然语言提问。检索范围是你**主动入库**的知识库，不是全部 stars，也不是全网 GitHub。本地混合检索 + 带引用的回答；RAG 只读。

![RAG 问答](https://cdn.dong4j.site/source/image/zhihu-04-rag-qa.webp)

![引用溯源](https://cdn.dong4j.site/source/image/zhihu-05-rag-citation.webp)

#### 本地优先

索引在本机，AI 用你自己的 key / Ollama。知识库和 stars 是两回事——这是信任边界，不是功能阉割。

#### 规划中（未全部上线）

整理大库、发现替代与选型、消化成周报 / 回忆搜索。原则不变：AI 建议，你确认。

#### 结尾

下载：https://starcat.ink  
组织：https://github.com/starcat-app · 反馈：`starcat-app/starcat-pro`

评论区想听：你怎么管 Stars？RAG 只搜知识库你能接受吗？

---

## 评论区引导（动态 / 专栏通用）

- 你们现在怎么管理 GitHub Stars？
- 如果 RAG 只能搜「知识库」不能搜全部 stars，能接受吗？
- 更想看我下次聊：使用技巧，还是本地 RAG 怎么做的？
