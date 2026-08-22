---
name: starcat-weekly-import
description: 从新闻摘要、项目清单、文章或其他批量文本中联网甄别并识别真实 GitHub 仓库，搜索和核验 owner/repo，向用户展示证据并在明确确认后，通过 starcat-api 的 Weekly 服务批量写入受控人工来源。未明确说明测试时，固定使用生产服务 https://starcat-api.fly.dev，并从 supports/starcat-api/.env 的 WEEKLY_ADMIN_API_KEYS 读取管理员 Key。用户提到 AI 情报采集、从新闻标题找 GitHub 项目、从文本找 GitHub 地址、批量录入 Starcat Weekly、解析项目清单或补全缺失仓库链接时使用。
---

# Starcat Weekly 情报采集

把非结构化文本转换为经核验的 GitHub `owner/repo` 列表，并在用户确认后一次性提交。当前默认分类是 `ai_intelligence`；分类必须来自服务端允许人工录入的固定来源目录，禁止自行创造分类。

## 硬性边界

- 先解析、搜索、核验和展示候选，得到用户明确确认后才能调用写接口。
- 写入前调用 `GET /internal/sources?manual_import=true`，只使用响应中 `enabled=true` 且 `manual_import_enabled=true` 的来源。
- 未指定分类时使用 `ai_intelligence`。如果用户指定的分类不在允许列表中，停止提交并解释原因。
- 只提交确定为 GitHub 仓库的 `owner/repo`；组织主页、用户主页、GitHub Topics、Issue、Release、文件路径和搜索页都不是仓库。
- 新闻标题是检索线索，不是仓库名：对于没有显式 GitHub URL 的每一条输入，必须联网定位发布主体和实际项目；不要要求用户自行补链接，也不要按标题字面猜测仓库。
- 仅提交与新闻主体直接对应的官方仓库。若新闻是闭源产品、云服务、论文、仅在 Hugging Face/Civitai 发布的模型或硬件发布，而没有该主体的官方 GitHub 仓库，记为“未找到”；不得用同名第三方实现、上游项目、配套节点或辅助工具替代。
- 一个输入批次最多提交 200 个仓库。批内按小写 `owner/repo` 去重，但保留用户原文标题和来源链接。
- 用户未明确说明“测试”时，一律固定使用生产服务 `https://starcat-api.fly.dev`，并通过 `X-SC-Svc: weekly` 路由到 Weekly，不得接受或推断其他 Base URL。
- 生产 Admin Key 只从 `supports/starcat-api/.env` 的 `WEEKLY_ADMIN_API_KEYS` 读取；多值时使用第一个非空 Key。不得要求用户导出生产 Key，也不得在 Skill、命令或输出中显示 Key。
- 只有用户明确说明“测试”时才使用 `--test`，此时才允许通过 `--base-url` / `STARCAT_WEEKLY_BASE_URL` 和 `STARCAT_WEEKLY_ADMIN_KEY` 注入测试配置。
- POST 只代表持久化入队成功，不代表 GitHub 数据已补全；拿到 `batch_id` 后必须轮询批次终态。

## 工作流

### 1. 提取显式仓库

从文本中优先提取：

- `https://github.com/{owner}/{repo}`；
- `github.com/{owner}/{repo}`；
- 独立出现且上下文明确的 `{owner}/{repo}`。

规范化时移除 `.git`、结尾 `/`、query、fragment，以及仓库后面的 `/issues`、`/releases`、`/tree/...` 等路径，只保留前两个 path segment。

### 2. 联网甄别新闻并搜索缺失地址

把没有显式 GitHub URL 的条目视为新闻线索，逐条联网检索。先确认新闻提及的是开源项目、产品/服务、论文、模型还是硬件，再定位其发布方及实际项目；不要假设新闻标题与仓库名相同。搜索式优先使用：

```text
"项目名" GitHub
"项目名" 官方 GitHub
"公司名" "项目名" GitHub
```

优先级依次为官方组织仓库、项目官网链接的 GitHub、维护者公开仓库。名称相似但证据不足时标记为“待确认”，不要猜测并提交。

### 3. 核验真实性

每个候选至少检查：

1. GitHub 仓库页面真实存在，且 canonical 地址与候选一致；
2. 仓库 README、描述、官网或发布者与输入文本指向同一项目；
3. 不是 fork 冒充上游、镜像、占位仓库或同名无关项目；
4. 仓库与新闻主体直接对应；新闻仅提及模型权重、论文、云服务或产品时，不得以同作者的配套节点、示例、上游或第三方实现替代。
5. 新闻描述的是闭源产品、论文或模型但没有官方 GitHub 仓库时，明确记为“未找到”，不要用第三方实现代替。

### 4. 展示并请求确认

提交前给出紧凑表格：原始条目、规范化 `owner/repo`、GitHub URL、核验结论、依据。把“已确认”“待确认”“未找到”分开；只把“已确认”加入拟提交列表。

明确询问用户是否提交该列表到指定来源。用户修改列表后重新展示最终集合；不得把之前被排除的候选带回。

### 5. 发现来源能力

阅读 [references/api-contract.md](references/api-contract.md)，调用：

```text
GET /internal/sources?manual_import=true
Authorization: Bearer <从 supports/starcat-api/.env 的 WEEKLY_ADMIN_API_KEYS 读取>
X-SC-Svc: weekly
```

确认目标来源仍允许人工录入。服务端返回为空或不含目标来源时停止。

### 6. 批量提交并轮询

生成唯一且可复用的 `idempotency_key`，一次 POST 完整列表。输入未提供 key 时，脚本按规范化 payload 生成稳定内容指纹，因此 dry-run、正式提交和超时重放保持一致。可用脚本先做本地校验，再经 `--confirm` 真正提交：

```bash
python3 .claude/skills/starcat-weekly-import/scripts/submit_import.py \
  --input /tmp/starcat-weekly-import.json

python3 .claude/skills/starcat-weekly-import/scripts/submit_import.py \
  --input /tmp/starcat-weekly-import.json \
  --confirm --poll
```

第一条命令默认仅校验并打印 payload，不访问网络。第二条命令固定调用 `https://starcat-api.fly.dev`，携带 `X-SC-Svc: weekly`，并从 `supports/starcat-api/.env` 读取 `WEEKLY_ADMIN_API_KEYS`，检查来源能力、提交并轮询。

只有用户明确要求测试时，才使用测试模式：

```bash
STARCAT_WEEKLY_BASE_URL="http://127.0.0.1:5003" \
STARCAT_WEEKLY_ADMIN_KEY="test-key" \
python3 .claude/skills/starcat-weekly-import/scripts/submit_import.py \
  --test \
  --input /tmp/starcat-weekly-import.json \
  --confirm --poll
```

不得在非测试任务中添加 `--test`，也不得用测试环境变量覆盖生产地址或生产 Key。

最终报告 `batch_id`、总数、成功数、剔除数和失败原因；`success` 或 `partial_success` 是终态，`failed` 需要原样报告，不要自动换仓库重投。

## 输出要求

- 区分“文本提取结果”和“实际入库结果”。
- 对未找到仓库的新闻给出清晰结论，并说明其属于产品/服务、论文、模型权重、硬件或证据不足中的哪一种；这不是错误。
- 提供 GitHub 可点击链接，但不要输出 Admin Key、完整 Authorization header 或服务端秘密配置。
- 大批量文本按原始顺序编号，方便用户逐项核对。
