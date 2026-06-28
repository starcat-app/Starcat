# Starcat GitHub 项目分析与外部文档服务集成讨论记录

> 生成时间：2026-06-10  
> 主题：Starcat 如何集成 GitHub 项目分析、外部文档站索引探测、本地代码分析、Repomix 上下文生成，以及 codewiki-mcp 逆向方案。

---

# 1. 背景问题

用户希望在 Starcat 中集成一些 GitHub 项目分析相关能力。最初讨论到很多开源项目都可以分析 GitHub 项目，但它们通常需要先拉取源码，再使用 AI 工具进行分析。

用户设想：

1. Starcat 当前并没有拉取源码。
2. 如果用户点击“项目分析”入口按钮：
   - 弹出日志框；
   - 通过滚动日志展示执行流程；
   - 第一步拉取项目源码到临时目录；
   - 使用集成好的分析服务开始分析；
   - 分析完成后展示结果；
   - 如果结果是本地启动的 Web 服务，则点击后在浏览器查看。
3. 希望先查有哪些 GitHub 项目分析开源项目，并选一个最合适的做 PoC。

---

# 2. 第一轮方案：错误地混淆了产品类型

最初把 CodeWiki、DeepWiki 这类“项目文档生成服务”和 CodeGraphContext 这类“代码分析工具”混在一起，推荐了 CodeWiki 作为 PoC。

当时的错误理解是：

- CodeWiki 可以本地运行；
- Starcat 点击按钮后 clone 源码；
- 运行 CodeWiki；
- 生成 `docs/index.html`；
- 打开结果。

但用户指出这个理解不对。

---

# 3. 用户纠正后的产品分类

用户明确指出：

> CodeWiki 这类和 CodeGraphContext 这类是两类产品：
>
> - 一类是为项目生成文档；
> - 一类是代码分析。

用户的真实想法：

## 3.1 CodeWiki / DeepWiki / Zread 类

这类服务应该直接使用外部服务。

Starcat 只需要：

1. 查询这些服务是否已经索引了用户 Star 的项目；
2. 如果已经索引，则在 Starcat 的 repo 上展示跳转按钮；
3. Starcat 不做 clone；
4. Starcat 不做源码分析；
5. Starcat 不生成文档；
6. 后端负责检测与返回跳转链接。

也就是：

```text
Starcat repo
→ 后端查询外部服务是否有索引
→ 有索引则返回跳转链接
→ Starcat 展示按钮
```

## 3.2 CodeGraphContext 类

CodeGraphContext 才是本地集成能力。

它应该走：

```text
点击分析
→ clone 仓库到本地
→ 本地分析
→ 本地查看结果
```

如果 CodeGraphContext 有公开 API，可以研究是否直接使用；但更倾向于集成到 Starcat 中，全部走本地。

## 3.3 Repomix 类

Repomix 又是第三类。

之前因为没有考虑清楚本地 clone 逻辑，所以没有接入。

现在如果为了 CodeGraphContext 必须做本地 clone，那么 Repomix 也可以接入，用来为 Starcat 的 AI 功能提供更多上下文。

---

# 4. 三类能力的总体方案

Starcat 中围绕 GitHub Repo 的增强能力应该分成三条线。

## 4.1 外部文档站跳转能力

面向：

```text
CodeWiki
DeepWiki
Zread
Google Code Wiki
智谱类服务
Google 类服务
```

Starcat 的角色：

```text
查询是否已索引
展示入口
点击跳转
```

Starcat 不做：

```text
clone
生成文档
分析源码
```

这类能力可以称为：

```text
External Repository Docs Discovery
```

## 4.2 本地代码分析能力

面向：

```text
CodeGraphContext
CodeGraph
其他代码图谱分析工具
```

Starcat 的角色：

```text
clone 源码
运行本地分析工具
展示实时日志
保存分析结果
打开本地结果
```

这才是本地集成重点。

## 4.3 LLM 上下文生成能力

面向：

```text
Repomix
Gitingest
其他 repo-to-context 工具
```

Starcat 的角色：

```text
复用本地 clone
生成 LLM-friendly 上下文
提供给 Starcat AI 功能
支持导出和缓存
```

这部分是 Starcat AI 能力的基础设施，不等同于项目文档生成，也不等同于代码图谱分析。

---

# 5. DeepWiki / CodeWiki / Zread 外部索引查询

用户随后要求查询：

> deepwiki / codewiki 这个公开服务，有没有接口获取已索引过的项目？

讨论结论如下。

## 5.1 DeepWiki

DeepWiki 有官方 MCP，但用户后来明确表示不需要 MCP。

对 Starcat 来说，最简单的是 Web 探测。

URL 规则：

```text
https://deepwiki.com/{owner}/{repo}
```

判断方式：

```text
GET https://deepwiki.com/{owner}/{repo}
```

如果页面正确返回，并且命中一些页面特征，就认为大概率已索引。

可用特征：

```text
HTTP 200
页面 title 包含 "{owner}/{repo} | DeepWiki"
页面包含 "Last indexed"
页面包含 "Overview"
页面包含 github.com/{owner}/{repo}
```

返回示例：

```json
{
  "provider": "deepwiki",
  "name": "DeepWiki",
  "status": "indexed",
  "url": "https://deepwiki.com/owner/repo",
  "confidence": "high",
  "probeMethod": "html_fingerprint"
}
```

## 5.2 Google Code Wiki

Google Code Wiki URL 规则：

```text
https://codewiki.google/github.com/{owner}/{repo}
```

问题：

- 它更像 JS 渲染的前端应用；
- 普通 HTML 不一定包含真实内容；
- HTTP 200 不一定代表已索引；
- 没有查到官方公开 REST API；
- 可以通过非官方项目 `codewiki-mcp` 逆向 Web RPC。

简单 URL 探测只能返回：

```json
{
  "provider": "google_codewiki",
  "name": "Google Code Wiki",
  "status": "unknown",
  "url": "https://codewiki.google/github.com/owner/repo",
  "confidence": "low",
  "probeMethod": "url_probe"
}
```

更可靠的方式是逆向 Web RPC，也就是参考 codewiki-mcp。

## 5.3 Zread

Zread 的 URL 规则：

```text
https://zread.ai/{owner}/{repo}
```

它也更适合 Web 探测，而不是 MCP / CLI。

判断方式：

```text
GET https://zread.ai/{owner}/{repo}
```

可用特征：

```text
HTTP 200
页面 title 包含 "{owner}/{repo} | Zread"
页面包含 "Ask AI"
页面包含 "Source Code"
页面包含 "Overview"
```

返回示例：

```json
{
  "provider": "zread",
  "name": "Zread",
  "status": "indexed",
  "url": "https://zread.ai/owner/repo",
  "confidence": "high",
  "probeMethod": "html_fingerprint"
}
```

---

# 6. Starcat 外部文档索引后端接口设计

用户最终明确：

> 我只需要将 Starcat 中的 repo 和上面 3 个服务已索引的项目做一个查询（try open），只要正确返回就大致判断这个项目已经索引，根本用不到 MCP、CLI，也不需要 API Key。能逆向 Web 端就逆向，有开源逆向的就用。目的很简单：如果有已索引过的项目，就在 Starcat 的 repo 上展示跳转按钮。后端负责检测与返回跳转链接。

因此最终方案是：

```text
Starcat repo: owner/repo
        ↓
Starcat 后端探测 DeepWiki / Google Code Wiki / Zread
        ↓
哪个服务页面能正确返回，就认为大概率已索引
        ↓
Starcat 客户端展示跳转按钮
```

## 6.1 单 repo 查询接口

```http
GET /api/external-docs/status?repo=owner/repo
```

返回：

```json
{
  "repo": "owner/repo",
  "checkedAt": "2026-06-10T12:00:00Z",
  "items": [
    {
      "provider": "deepwiki",
      "name": "DeepWiki",
      "status": "indexed",
      "url": "https://deepwiki.com/owner/repo",
      "confidence": "high",
      "probeMethod": "html_fingerprint"
    },
    {
      "provider": "zread",
      "name": "Zread",
      "status": "indexed",
      "url": "https://zread.ai/owner/repo",
      "confidence": "high",
      "probeMethod": "html_fingerprint"
    },
    {
      "provider": "google_codewiki",
      "name": "Google Code Wiki",
      "status": "unknown",
      "url": "https://codewiki.google/github.com/owner/repo",
      "confidence": "low",
      "probeMethod": "url_probe"
    }
  ]
}
```

## 6.2 批量查询接口

Starcat 的场景中，用户 Star 的 repo 很多，因此需要批量接口：

```http
POST /api/external-docs/status/batch
```

请求：

```json
{
  "repos": [
    "facebook/react",
    "openai/openai-cookbook",
    "modelcontextprotocol/modelcontextprotocol"
  ],
  "providers": [
    "deepwiki",
    "zread",
    "google_codewiki"
  ]
}
```

返回：

```json
{
  "items": [
    {
      "repo": "facebook/react",
      "providers": [
        {
          "provider": "deepwiki",
          "status": "indexed",
          "url": "https://deepwiki.com/facebook/react"
        },
        {
          "provider": "zread",
          "status": "indexed",
          "url": "https://zread.ai/facebook/react"
        }
      ]
    }
  ]
}
```

---

# 7. 状态设计

不要只用 true / false，因为 Web 逆向和页面探测容易误判。

建议状态：

```text
indexed             明确已索引
probably_indexed    大概率已索引
not_indexed         明确未索引
unknown             无法判断
error               探测失败
rate_limited        被限流
```

Starcat UI 处理：

| status | UI |
|---|---|
| `indexed` | 显示正式按钮 |
| `probably_indexed` | 显示按钮 |
| `unknown` | 显示 Try Open 或隐藏 |
| `not_indexed` | 不显示 |
| `error` | 不显示 |
| `rate_limited` | 不显示或走缓存 |

---

# 8. 缓存设计

这个功能不能每次打开 Starcat 都实时扫所有服务。

建议缓存：

```text
indexed / probably_indexed：缓存 7 天
not_indexed：缓存 1 天
unknown：缓存 6 小时
error / rate_limited：缓存 30 分钟
```

缓存表：

```sql
CREATE TABLE repo_external_doc_status (
    id BIGINT PRIMARY KEY,
    repo_full_name VARCHAR(255) NOT NULL,
    provider VARCHAR(64) NOT NULL,
    status VARCHAR(32) NOT NULL,
    url TEXT NOT NULL,
    confidence VARCHAR(32),
    probe_method VARCHAR(64),
    http_status INT,
    matched_signals TEXT,
    checked_at TIMESTAMP NOT NULL,
    expires_at TIMESTAMP NOT NULL,
    UNIQUE(repo_full_name, provider)
);
```

---

# 9. 探测器抽象

后端可以抽象为：

```java
public interface ExternalDocProvider {
    String provider();
    String buildUrl(String owner, String repo);
    ProbeResult probe(String owner, String repo);
}
```

实现：

```text
DeepWikiProvider
ZreadProvider
GoogleCodeWikiProvider
```

结果对象：

```java
public record ProbeResult(
    String provider,
    String status,
    String url,
    String confidence,
    String probeMethod,
    Integer httpStatus,
    List<String> matchedSignals
) {}
```

---

# 10. HTTP 探测细节

请求头建议：

```http
User-Agent: Mozilla/5.0 StarcatBot/1.0
Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8
Accept-Language: en-US,en;q=0.9,zh-CN;q=0.8
```

超时建议：

```text
connect timeout: 3s
read timeout: 8s
retry: 1 次
```

并发建议：

```text
单 provider 限制并发
全局限制并发
失败自动降级
```

---

# 11. codewiki-mcp 逆向原理

用户要求：

> 再细说一下 codewiki-mcp 这类项目，是如何逆向的。

结论：

codewiki-mcp 的逆向，本质不是破解，也不是跑浏览器自动化，而是复用 Web 前端已经在调用的 Google 内部 RPC 接口。

核心过程：

```text
打开 codewiki.google 网页
→ 浏览器前端调用内部 batchexecute RPC
→ 逆向出 endpoint、rpcId、请求体格式、响应解析方式
→ 后端模拟同样的 POST 请求
→ 得到 repo 搜索 / wiki fetch / Q&A 结果
```

## 11.1 codewiki-mcp 逆向到的关键点

Google Code Wiki 使用的是 Google 内部的 batchexecute RPC：

```text
/_/BoqAngularSdlcAgentsUi/data/batchexecute
```

不是 REST，也不是 GraphQL。

它会通过 `f.req` 提交请求体。

响应有 XSSI 前缀：

```text
)]}'
```

然后在响应里解析 `wrb.fr` frame。

codewiki-mcp 目前映射了三个 RPC ID：

| 能力 | RPC ID | 用途 |
|---|---|---|
| Search | `vyWDAf` | 搜索 codewiki.google 已索引仓库 |
| Fetch | `VSX6ub` | 获取某个 repo 的 wiki 文档内容 |
| Ask | `EgIxfe` | 对某个 repo 提问 |

对 Starcat 来说，最有价值的是：

```text
Search: vyWDAf
Fetch:  VSX6ub
```

不需要 Ask。

## 11.2 Fetch RPC

访问普通页面：

```text
https://codewiki.google/github.com/openai/openai-cookbook
```

可能只能拿到前端壳。

真正有价值的是调用：

```http
POST https://codewiki.google/_/BoqAngularSdlcAgentsUi/data/batchexecute?rpcids=VSX6ub&rt=c&source-path=/github.com/openai/openai-cookbook
```

请求体大概是：

```text
f.req=<urlencoded JSON>
```

JSON 结构类似：

```json
[
  [
    [
      "VSX6ub",
      "[\"https://github.com/openai/openai-cookbook\"]",
      null,
      "generic"
    ]
  ]
]
```

对 Starcat 的用途：

```text
输入 owner/repo
→ Fetch VSX6ub
→ 如果返回 sections/pages 且 canonicalUrl 匹配 GitHub repo
→ indexed
→ 返回跳转 URL: https://codewiki.google/github.com/owner/repo
```

## 11.3 Search RPC

Search RPC：

```text
rpcId = vyWDAf
payload = [query, limit, query, 0]
sourcePath = /
```

用途：

```text
输入 owner/repo
→ search owner/repo
→ 如果结果里出现完全匹配的 fullName
→ probably_indexed / indexed
```

但搜索可能模糊匹配，因此更适合作为辅助。

推荐：

```text
Search 作为辅助
Fetch 作为确认
```

## 11.4 响应解析方式

Google batchexecute 响应不是普通 JSON。

通常类似：

```text
)]}'

[...]
[["wrb.fr","VSX6ub","<payload json string>",...]]
```

解析步骤：

```text
1. trimStart
2. 如果以 ")]}'" 开头，就去掉
3. 按行 split
4. 找出看起来像 JSON array 的行
5. JSON.parse
6. 递归查找数组节点
7. 找 node[0] === "wrb.fr" 且 node[1] 是 rpcId 的 frame
8. 取 node[2]
9. 如果 node[2] 是字符串，再 JSON.parse 一次
```

---

# 12. Google Code Wiki Provider 最小实现建议

Starcat 后端不需要完整复刻 MCP。

只需要做一个最小 GoogleCodeWikiProbe：

```text
1. 构造页面 URL
   https://codewiki.google/github.com/{owner}/{repo}

2. 调用 Fetch RPC: VSX6ub
   参数: https://github.com/{owner}/{repo}
   source-path: /github.com/{owner}/{repo}

3. 解析 batchexecute 响应

4. 判断 payload：
   - 有 repoName
   - 有 canonicalUrl
   - 有 sections/pages
   - canonicalUrl 包含 github.com/{owner}/{repo}

5. 返回 indexed + 跳转 URL
```

## 12.1 状态映射

```text
VSX6ub 成功 + 有 sections:
  indexed

VSX6ub 成功但 sections 为空:
  probably_indexed / unknown

VSX6ub 404:
  not_indexed

VSX6ub 403 / 429:
  rate_limited / unknown

VSX6ub 5xx:
  error

解析失败:
  unknown
```

## 12.2 Provider 配置

```json
{
  "provider": "google_codewiki",
  "name": "Google Code Wiki",
  "urlPattern": "https://codewiki.google/github.com/{owner}/{repo}",
  "probe": {
    "type": "google_batchexecute",
    "endpoint": "https://codewiki.google/_/BoqAngularSdlcAgentsUi/data/batchexecute",
    "fetchRpcId": "VSX6ub",
    "searchRpcId": "vyWDAf"
  }
}
```

## 12.3 返回结果

```json
{
  "provider": "google_codewiki",
  "name": "Google Code Wiki",
  "status": "indexed",
  "url": "https://codewiki.google/github.com/openai/openai-cookbook",
  "confidence": "high",
  "probeMethod": "batchexecute_fetch",
  "matchedSignals": [
    "rpc_ok",
    "canonical_url_matched",
    "sections_non_empty"
  ]
}
```

---

# 13. 为什么不建议直接依赖 codewiki-mcp 包

codewiki-mcp 是 MCP Server，目标是给 AI Assistant 使用，提供：

```text
search
fetch
ask
```

但 Starcat 后端只需要：

```text
判断 owner/repo 是否已索引
返回跳转 URL
```

因此更建议：

```text
参考 codewiki-mcp 的逆向实现
抽取最小 batchexecute client
只实现 VSX6ub fetch probe
可选实现 vyWDAf search probe
不要引入 MCP runtime
不要暴露 Ask 功能
```

---

# 14. 风险点

## 14.1 RPC ID 可能变化

`VSX6ub`、`vyWDAf` 不是公开 API 契约，而是 Web 前端内部 RPC ID。

Google 改前端后，这些 ID 可能失效。

后端需要：

```text
provider version
health check
fallback to Try Open
报警日志
```

## 14.2 Payload 结构可能变化

即使 RPC ID 不变，返回数组结构也可能变化。

不要强依赖固定下标：

```text
payload[0][1][5]
```

而要尽量宽松判断：

```text
递归搜索 canonicalUrl
递归搜索 markdown section
递归搜索 github.com/owner/repo
```

## 14.3 频率限制

不要对用户所有 Star repo 实时扫一遍。

使用：

```text
批量任务 + 缓存
indexed 缓存 7 天
not_indexed 缓存 1 天
unknown 缓存 6 小时
rate_limited 缓存 30 分钟
```

---

# 15. 最终 Starcat 方案总结

Starcat 不应该把所有“GitHub 项目分析”混成一个功能。

应该拆成：

```text
外部文档站：查索引 + 跳转
本地代码分析：clone + 工具分析 + 本地查看
AI 上下文生成：clone + Repomix + Starcat AI 复用
```

其中：

```text
DeepWiki / Zread / Google Code Wiki = 外部文档站
CodeGraphContext / CodeGraph = 本地代码分析
Repomix / Gitingest = AI 上下文生成
```

当前用户最关心的是第一类：

```text
External Repository Docs Discovery
```

也就是：

```text
Starcat 后端根据 owner/repo 探测 DeepWiki / Google Code Wiki / Zread 是否已有公开页面
如果页面正确返回并命中特征，就返回 indexed 和跳转链接
Starcat 客户端根据后端结果展示跳转按钮
```

推荐判断方式：

```text
DeepWiki:
  URL + HTML fingerprint
  可信度高

Zread:
  URL + HTML fingerprint
  可信度高

Google Code Wiki:
  URL probe + 逆向 Web RPC
  可信度中低到高，取决于是否成功实现 VSX6ub fetch
```

最小可用版本：

```text
DeepWiki:
  GET 页面 + HTML 特征判断

Zread:
  GET 页面 + HTML 特征判断

Google Code Wiki:
  先 Try Open
  后续实现 batchexecute fetch probe
```

增强版本：

```text
Google Code Wiki:
  VSX6ub fetch repo
  成功返回 sections → indexed
  404 → not_indexed
  其他错误 → unknown
```
