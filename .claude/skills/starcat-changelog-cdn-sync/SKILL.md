---
name: starcat-changelog-cdn-sync
description: >
  在修改主仓库 CHANGELOG-ZH.md 后，把本地相对路径截图转为 WebP、经 PicList 上传到
  cdn.dong4j.site，替换为 CDN 地址，再把图片与中文条目改动同步到另外 3 份更新日志，
  最后只删除本次已成功上传的临时 PNG/WebP。用户提到 changelog 截图上传 CDN、同步四份
  更新日志、CHANGELOG-ZH 本地图片、PicList 上传更新说明图时使用。
---

# Starcat Changelog CDN 同步

以主仓库 **`CHANGELOG-ZH.md` 为唯一编辑源**，把「本地临时截图 + 中文条目改动」收口到
四份正式更新日志，并清理临时媒体文件。

## 四份文件

| 角色 | 路径 |
|------|------|
| **源（只从此处开始）** | `CHANGELOG-ZH.md` |
| App Store 英文 | `CHANGELOG.md` |
| Direct 中文 | `supports/starcat-pro/CHANGELOG-ZH.md` |
| Direct 英文 | `supports/starcat-pro/CHANGELOG.md` |

遵守 `docs/5-规范/Changelog-更新规范.md`：渠道专属条目只留在对应渠道；公共功能四份语义对齐。

## 硬性边界

1. **必须等 dong4j 明确触发本 skill / 说「开干」后才改文件**；讨论阶段只读。
2. **作用域只限最新版本段**：`CHANGELOG-ZH.md` 里从上往下第一个 `## X.Y.Z`（或
   `## X.Y.Z-待发布`）到下一个 `## ` 之前；更旧版本一律不动。
3. **只处理相对路径本地图**，形如：
   - `./CHANGELOG-ZH/xxx.png`
   - `./CHANGELOG-ZH/xxx.webp`
   - `./CHANGELOG/xxx.png`（若出现）
4. **已是 `https://cdn.dong4j.site/...` 的图不要重复上传**，除非用户明确要求换图。
5. **PicList 必须已在跑**：内置 Server `http://127.0.0.1:36677`；当前图床应为腾讯云
   `tcyun`，path `source/image/`，customUrl `https://cdn.dong4j.site`。
6. **CDN `HEAD`/`GET` 返回 200 之前，禁止删除任何本地临时文件**。
7. **删除白名单极严**（见 Step 5）；禁止清空整个目录、禁止删未引用文件、禁止删 CDN
   上已有但本次未处理的历史资源。
8. **不要 git commit / push**，除非用户另行要求。
9. **不要改** `supports/starcat-site/direct/changelog*.html`，不要跑官网生成脚本。

## 触发方式

dong4j 通常流程：

1. 先手改主仓库 `CHANGELOG-ZH.md`（可含本地 `./CHANGELOG-ZH/*.png` 与中文描述改动）；
2. 再调用本 skill（或说「同步 changelog 图到 CDN」）。

Agent 不要在用户未改 ZH 时主动发明截图或条目。

### 动手前清单（强制）

在改任何文件之前，先在回复里列出：

1. 将转换 / 上传的本地图路径；
2. 将替换成的预期 CDN URL（basename 可知时）；
3. 将同步文案的短标题（中 ↔ 英）；
4. 将删除的临时文件（若已能预判）；
5. 将跳过的渠道专属条目。

- 若本轮用户已明确说「开干 / 改吧 / GO / 动手 / 实施」→ 列出后**直接执行**，无需再等一轮。
- 若仅讨论或只说「看看」→ 只列清单，等确认后再改。

## 前置检查

```bash
# PicList 内置 Server
curl -fsS http://127.0.0.1:36677/ >/dev/null

# WebP 转换
which cwebp

# 源文件存在
test -f CHANGELOG-ZH.md
```

若 PicList 未监听 36677：停下来让用户打开 PicList（启用内置 Server），不要改用其它上传通道，
除非用户明确授权。

---

## Step 1 — 扫描源文件中的本地图

**只扫最新版本段**（第一个 `## X.Y.Z` … 下一 `## ` 之前），在其中找出：

```markdown
![alt](./CHANGELOG-ZH/name.png)
![alt](./CHANGELOG-ZH/name.webp)
```

记录清单：`相对路径 → 绝对路径 → 所属短标题（bullet 冒号前）`。

若没有本地相对路径图，跳过 Step 2–3 的上传，仍可做 Step 4 的文案同步（同样只限最新版本段）。

---

## Step 2 — PNG → WebP

对清单中每个 `.png`：

```bash
cwebp -q 80 "CHANGELOG-ZH/foo.png" -o "CHANGELOG-ZH/foo.webp"
```

- 输出与 PNG 同目录、同 basename、扩展名 `.webp`。
- 已是 `.webp` 的本地相对路径图：跳过转换，直接进入上传。
- 转换失败：停止该文件后续步骤，报告错误，不要半替换 CDN。

把「待上传文件」记为对应 `.webp` 的绝对路径。

---

## Step 3 — PicList 上传并改写源文件

对每个待上传 WebP：

```bash
curl -sS -X POST 'http://127.0.0.1:36677/upload' \
  -H 'Content-Type: application/json' \
  --data-binary "{\"list\":[\"/ABS/PATH/TO/file.webp\"]}"
```

成功响应形如：

```json
{ "success": true, "result": ["https://cdn.dong4j.site/source/image/file.webp"] }
```

然后：

1. 校验 `success == true` 且 URL 前缀为 `https://cdn.dong4j.site/source/image/`；
2. `curl -fsSI <cdn-url>` 确认 **HTTP 200** 且 `content-type` 含 `image`；
3. 在 **`CHANGELOG-ZH.md`** 把该图的相对路径替换为 CDN URL，例如：

```markdown
![20260730232032_p1AUnCiu](https://cdn.dong4j.site/source/image/20260730232032_p1AUnCiu.webp)
```

任一文件上传或校验失败：保留本地文件与 Markdown 相对路径，不要继续删文件。

---

## Step 4 — 同步到另外 3 份

以更新后的 `CHANGELOG-ZH.md` **最新版本段**为真相源（其它 `##` 版本禁止改）。

### 4.1 匹配规则

按 **短标题** 对齐（中文 `：` 前 / 英文 `: ` 前），例如：

| 中文短标题 | 英文短标题 |
|------------|------------|
| 我的洞察 | My Insights |
| 仓库洞察 | Repository Insights |
| macOS 桌面小组件 | macOS desktop widgets |
| 洞察聚合复用 | Shared insight aggregates |

未知短标题：根据上下文语义翻译英文短标题，并在回复里列出对照表供确认；不要静默猜错渠道。

### 4.2 同步内容

对每个公共短标题：

1. **图片行**：把 ZH 中该条下的 `![...](https://cdn.dong4j.site/...)` 同步到另外 3 份对应条目下（无则追加，有旧 CDN/旧相对路径则替换）。
2. **说明文案**：若 ZH 该条「冒号后说明」相对另外 3 份有改动：
   - Direct 中文：直接采用 ZH 新说明；
   - 两份英文：改写成语义等价的英文说明，遵守「短标题: 说明」与 Changelog 规范（禁止 `Added`/`Improved` 等分类动词开头）。

### 4.3 渠道隔离（强制）

- **App Store 专属**（如 `App Store 更新检查` / `App Store update checks`）：只出现在
  根目录 `CHANGELOG-ZH.md` / `CHANGELOG.md`，**不要**写入 `supports/starcat-pro/`。
- **Direct 专属**：只留在 `supports/starcat-pro/`，不要回写根目录 App Store 两份。
- 公共功能条目：四份都要齐。

### 4.4 不要整文件覆盖

禁止把整份 ZH 拷到 EN 或把 App Store 整份拷到 Direct。只按短标题做外科手术式更新。

---

## Step 5 — 删除本地临时图（高危，白名单）

仅删除同时满足以下条件的文件：

1. 位于 `CHANGELOG-ZH/` 或 `CHANGELOG/`（仓库根下这两个目录）；
2. 扩展名为 `.png` 或 `.webp`；
3. **本次**在 Step 1 中作为相对路径被引用，或由该 PNG 转换得到的同名 WebP；
4. 已成功上传且 Markdown 已改为 CDN；
5. CDN 校验 200 通过；
6. 四份 changelog 中 **不再** 以相对路径引用该文件。

删除前打印将删清单，删除后确认路径不存在。

### 禁止删除

- 仍被任一 changelog 相对路径引用的文件；
- 未参与本次上传的历史文件（即使同目录）；
- 仓库其它路径下的图片、Assets、screenshots、supports 下营销图；
- 任何 `.md` 文件。

可选：若目录删空后只剩 `.DS_Store`，可提醒用户，但不要主动 `rm -rf` 整个目录，除非用户明确要求。

---

## Step 6 — 回报

用中文向 dong4j 汇报：

1. 上传成功的 CDN URL 列表；
2. 改动了哪 4 个文件、哪些短标题的图/文被同步；
3. 删除了哪些临时文件；
4. 渠道专属条目是否被正确跳过；
5. 提醒：Direct 调试需重跑 `scripts/run-debug-direct.sh`（读 `supports/starcat-pro`）；
   App Store 调试读根目录两份。

---

## 常见失败

| 现象 | 处理 |
|------|------|
| `curl: Failed to connect to 127.0.0.1 port 36677` | 打开 PicList，开启内置 Server |
| `success: false` | 看 PicList 日志；检查当前图床是否为 tcyun |
| Direct 更新说明没图、App Store 有 | 用户跑的是 Direct，确认已同步 `supports/starcat-pro` 并重建 |
| 英文说明与中文不对齐 | 检查短标题映射表；补译后重跑同步段落 |
| 误删风险 | 未过 CDN 校验绝不删；只删白名单内「本次」文件 |

---

## 与其它 skill 的边界

| Skill | 关系 |
|-------|------|
| `update-changelog` | 从 git commit **生成**条目文案；本 skill **不**扫 commit |
| `starcat-release` / 官网 changelog | 本 skill **不**生成 HTML、不部署 |
| 本 skill | 只做：本地图 → WebP → PicList CDN → 四份同步 → 清临时文件 |

用户若同时要「根据 commit 写新条目」和「上传截图」，先问清顺序；默认先保证 ZH 文案与本地图就绪，再跑本 skill。
