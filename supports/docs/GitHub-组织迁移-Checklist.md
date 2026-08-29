# Starcat GitHub 组织迁移 Checklist

> 目标：把 Starcat 主项目、支撑项目与现有 OAuth App 从个人账号 `dong4j`
> 迁移到 GitHub 组织 [`starcat-app`](https://github.com/starcat-app)，同时保证仓库可见性、
> 用户登录、CI/CD、GitHub Packages、Homebrew 与本地开发环境连续可用。
>
> 本文档是执行清单，不代表任何步骤已经完成。执行人只能在拿到 dong4j 对应阶段的明确确认后勾选。

---

## 0. 已确认的迁移边界

### 0.1 必须保持私有

- [x] `starcat-app/Starcat` — 从 `dong4j/Starcat` 转移，迁移前后均为 **Private**。
- [x] `starcat-app/starcat-license-api` — 从 `dong4j/starcat-license-api` 转移，迁移前后均为 **Private**。
- [x] 确认整个迁移过程中没有执行任何把上述两个仓库改为 Public 的操作。

### 0.2 转移后保持公开

- [x] `starcat-app/starcat-pro`
- [x] `starcat-app/starcat-localization`
- [x] `starcat-app/homebrew-starcat`
- [x] `starcat-app/starcat-skill`
- [x] `starcat-app/starcat-chrome-plugin`
- [x] `starcat-app/starcat-safari-plugin`
- [x] `starcat-app/starcat-discovery-api`
- [x] `starcat-app/starcat-recommend-api`
- [x] `starcat-app/starcat-sharing-api`
- [x] `starcat-app/starcat-trending-api`
- [x] `starcat-app/starcat-weekly-api`
- [x] `starcat-app/starcat-wiki-api`

### 0.3 直接在组织中新建并保持公开

以下项目当前没有可直接转移的完整远端仓库。先收口本地提交，再直接在组织下创建：

- [x] `starcat-app/starcat-cli`
- [x] `starcat-app/homebrew-starcat-cli`

### 0.4 明确排除

- [x] `supports/ai-file-wall` — 不迁移、不创建组织仓库、不修改现有项目。
- [x] `ruanyf/weekly` 及其本地 clone / backup — 第三方上游仓库，不在迁移范围内。

### 0.5 OAuth App

- [x] 转移现有 OAuth App `Starcat`，禁止在组织下重新创建替代应用。
- [x] OAuth App 转移后由 `starcat-app` 持有。
- [x] Client ID 保持 `Ov23li4suXj1nNsWtHHG` 不变。
- [x] Authorization callback URL 保持 `starcat://callback` 不变。
- [x] Device Flow 保持启用。
- [x] 不生成或轮换 Client Secret。
- [x] 不点击“撤销所有用户令牌”。

---

## 1. 硬性安全规则

- [ ] 迁移期间冻结 tag、Release、GitHub Packages 发布、Homebrew 更新和生产部署。
- [ ] 未经 dong4j 当前阶段明确确认，不执行仓库 Transfer、OAuth App Transfer、visibility 修改或权限修改。
- [ ] 不执行 `scripts/package-*`、`scripts/release-*`、`deploy.sh`、`fly deploy`、notary 上传或商店上传。
- [ ] 不为旧地址创建同名占位仓库或 fork；否则 GitHub 的旧地址重定向可能永久失效。
- [ ] 不删除原仓库、目标仓库、Actions run、Package、Release、tag 或本地分支。
- [ ] 不把 `.env`、API Key、OAuth Client Secret、Fly token、签名私钥或生产数据写入文档、日志或 Git。
- [ ] 每次只处理一个仓库；完成该仓库验收后才能进入下一个。
- [ ] 任何异常立即停止当前批次，不继续执行剩余 Transfer。
- [ ] `docs/功能实现总览.md` 不在本次迁移文档修改范围内；如需登记，必须另行取得明确授权。

---

## 2. 当前基线快照（2026-07-20）

> 本节用于迁移前比对。执行时必须重新读取 GitHub 和本地状态，不能只依赖此快照。

### 2.1 GitHub 组织

- [x] `starcat-app` 组织存在，当前套餐为 GitHub Free。
- [x] 当前组织有 4 个 Public 仓库：`.github`、`starcat-cli`、`homebrew-starcat-cli`、`starcat-localization`。
- [x] 当前组织成员只有 `dong4j`，且角色为 Owner。
- [x] 当前 Base permission 为 `None`。
- [x] 当前已强制组织成员启用 2FA。
- [x] 当前禁止普通成员创建仓库和修改 repository visibility。

### 2.2 本地未收口状态

- [x] Starcat 主仓库：`dev` / `main` 与远端同步、工作树干净；本地实验分支单独写入 bundle，不擅自推送。
- [x] `starcat-pro`：工作树干净，`dev` / `main` 均已推送；仓库中无待处理 `.DS_Store`。
- [x] `starcat-skill`：链接更新提交 `b96aa7e` 已推送，本地 `dev` / `main` 与组织远端对应分支一致，upstream 正常。
- [x] `starcat-cli`：确认开发改动已完成、提交并通过验证。
- [x] `homebrew-starcat-cli`：确认首个 commit 已完成。
- [x] 其它待迁移仓库均为预期分支，且不存在未提交或未推送的重要内容。

### 2.3 GitHub 集成

- [ ] 所有现有待迁移仓库当前均未启用 GitHub Pages。
- [ ] 所有现有待迁移仓库当前均无 repository webhook。
- [ ] 所有现有待迁移仓库当前均无 deploy key。
- [ ] `starcat-wiki-api`、`starcat-sharing-api`、`starcat-weekly-api`、`starcat-trending-api` 均存在 `FLY_API_TOKEN` Repository Secret。
- [ ] `starcat-trending-api` 存在 `production` Environment。
- [ ] `starcat-recommend-api` 存在 Actions workflow，但当前没有 Repository Secret；把它作为迁移前既有状态记录，不误判为迁移丢失。
- [ ] Chrome 插件存在 Release workflow。

### 2.4 OAuth App

- [x] 当前 owner 为 `dong4j`。
- [x] 当前 App 名为 `Starcat`。
- [x] 当前已授权用户数为 6；执行迁移前重新记录实际数量。
- [x] 当前 Client ID、callback URL、Device Flow 开关与 §0.5 一致。
- [x] 当前 Homepage 为 `https://github.com/dong4j/starcat`，迁移后计划改为 `https://starcat.ink`。

---

## 3. 组织迁移前加固

> 先控制组织权限，再接收私有仓库，避免未来新增成员后自动获得不必要的访问权。

- [x] 在 `starcat-app → Settings → Member privileges` 把 Base permissions 从 `Read` 改为 `None`。
- [x] 禁止普通成员修改 repository visibility，仅允许 Organization Owner 修改。
- [x] 根据实际协作方式限制普通成员创建 Public / Private repository 的权限。
- [x] 在邀请其他成员前启用组织 2FA 要求。
- [x] 确认 `dong4j` 仍为 Organization Owner。
- [x] 确认组织允许 Owner 创建 Public 和 Private repository。
- [x] 检查 `Settings → Actions`：Actions 可用，允许的 actions 与当前 workflow 依赖相容。
- [ ] 检查第三方 GitHub App / OAuth App 的组织访问策略；记录需要重新授权的集成。
- [ ] 如需团队权限，先创建 `maintainers` / `release` 等团队，再按最小权限分配仓库。

验收：

- [x] 新增普通成员不会因为 Base permission 自动读取 `Starcat` 或 `starcat-license-api`。
- [x] 只有 Owner 或明确授权的管理员可以更改仓库可见性。

---

## 4. 仓库迁移前预检与备份

### 4.1 本地 Git 预检

每个仓库分别执行并保存结果：

```bash
git status --short
git branch --show-current
git branch -vv
git remote -v
git tag --list
git log --oneline --decorate --max-count=10
```

- [ ] 当前分支正确。
- [ ] 工作树状态已由 dong4j 确认。
- [ ] 需要迁移的 commit、branch 和 tag 均已推到 GitHub。
- [ ] 未擅自推送实验分支、临时 tag 或其他不属于迁移范围的引用。

### 4.2 GitHub 元数据快照

每个现有仓库至少记录：

- [ ] Repository ID、owner、name、visibility、default branch。
- [ ] Issues、Pull Requests、Releases、tags、stars、watchers 数量。
- [ ] Collaborators 与权限。
- [ ] Branch protection / ruleset。
- [ ] Actions workflow、Repository Secret 名称、Variables、Environments。
- [ ] GitHub Pages、custom domain、webhooks、deploy keys。
- [ ] GitHub App 安装与第三方集成。
- [ ] GitHub Packages 名称、namespace、visibility、Actions access。

> 只记录 Secret 名称，不读取或复制 Secret 值。

### 4.3 Git mirror 备份

- [ ] 选择一个明确、非仓库内部的持久化备份目录。
- [ ] 对 14 个待转移的现有仓库分别执行 mirror clone。
- [ ] 校验 mirror 中存在预期 branch 和 tag。
- [ ] 记录备份目录，不把 mirror 加入 Starcat Git。

示例（先把路径替换成明确的绝对路径）：

```bash
gh repo clone dong4j/REPOSITORY /absolute/backup/path/REPOSITORY.git -- --mirror
git -C /absolute/backup/path/REPOSITORY.git show-ref
```

### 4.4 冻结窗口

- [ ] 通知所有协作者迁移开始时间和冻结范围。
- [ ] 冻结窗口内不 merge、不 push tag、不创建 Release、不触发部署。
- [ ] 记录迁移开始时间、执行人和当前 GitHub 状态。

---

## 5. 试点迁移：`starcat-localization`

> 该仓库公开、无 Actions、无 Secrets、无 Pages，作为最低风险试点。

### 5.1 转移前

- [x] `dong4j/starcat-localization` 工作树干净；本地 `dev` / `main` 与远端对应分支均指向 `183d2d1`，当前没有 tag。
- [x] `starcat-app` 下不存在 `starcat-localization` 同名仓库。
- [x] dong4j 明确决定本试点跳过 GitHub 元数据快照与 mirror 备份，以现有本地仓库作为代码副本。
- [x] dong4j 明确确认开始试点 Transfer。

### 5.2 发起转移

优先使用 GitHub UI：

```text
dong4j/starcat-localization
→ Settings
→ Danger Zone
→ Transfer
→ New owner: starcat-app
```

也可在明确授权后使用 API：

```bash
gh api --method POST \
  repos/dong4j/starcat-localization/transfer \
  -f new_owner=starcat-app
```

- [x] Transfer 请求返回成功，Repository ID 保持为 `R_kgDOTPF2CQ`。
- [x] 已等待 `starcat-app/starcat-localization` 可访问，未并发发起下一仓库 Transfer。

### 5.3 更新本地 remote

```bash
git -C supports/starcat-localization remote set-url \
  origin https://github.com/starcat-app/starcat-localization.git

git -C supports/starcat-localization fetch origin
git -C supports/starcat-localization push --dry-run
```

- [x] `origin` 指向 `https://github.com/starcat-app/starcat-localization.git`。
- [x] `fetch` 成功。
- [x] `push --dry-run` 成功。

### 5.4 试点验收

- [x] 新 owner、Public visibility、default branch 正确。
- [x] branch、tag、commit、Issue、PR、Release、stars、watchers 与迁移前一致。
- [x] `https://github.com/dong4j/starcat-localization` 能重定向到新地址。
- [x] 旧地址下没有创建占位仓库。
- [x] 新旧 Git URL 的 `ls-remote`、本地 `fetch` 与 `push --dry-run` 正常。
- [x] 当前文档、脚本、README 与站点入口均已改为 `https://github.com/starcat-app/starcat-localization`；旧 owner 仅保留在迁移源与重定向验收记录中。
- [ ] 观察一段时间后没有权限、链接或自动化异常。
- [x] dong4j 明确确认试点通过，允许进入批量阶段。

---

## 6. 公开仓库分批迁移

> 延续试点步骤：预检 → 备份 → Transfer → remote → 单仓库验收。

### 6.1 第一批：静态内容与低自动化仓库

- [x] `starcat-pro`
- [x] `starcat-skill`
- [x] `starcat-safari-plugin`

#### 6.1.1 `starcat-skill` 验收记录

- [x] 迁移前工作树干净；`dev` / `main` 与远端均指向 `479549b`，当前没有 tag。
- [x] Repository ID 为 `R_kgDOTdTniw`，Public，默认分支为 `main`；Issue、PR、Release、stars、watchers、forks 均为 0。
- [x] 迁移前无 Actions workflow、Repository Secret、Variable、Environment、Pages、webhook、deploy key、ruleset 或 branch protection。
- [x] mirror 备份保存到 `/Users/dong4j/Developer/1.AI/ai-incubator/Starcat-GitHub-Migration-Backups/2026-07-20/starcat-skill.git`，`show-ref` 与 `git fsck --full` 校验通过。
- [x] 2026-07-20 13:49 CST 完成 `dong4j/starcat-skill` → `starcat-app/starcat-skill` Transfer；Repository ID、Public visibility、默认分支与 refs 保持不变。
- [x] 本地 `origin` 已更新为 `https://github.com/starcat-app/starcat-skill.git`，`fetch --prune` 与 `push --dry-run origin dev main` 通过。
- [x] 旧 GitHub URL 返回 301 到新地址，新旧 Git URL 的 `ls-remote` 均返回相同 `dev` / `main` refs。
- [x] Starcat 安装 Prompt、CLI / MCP 设计文档与 Skill 内 CLI 安装链接已更新为 `starcat-app` namespace。
- [x] Skill 链接更新提交 `b96aa7e` 已推送到组织仓库的 `dev` / `main`，两个分支最终 refs 一致。

#### 6.1.2 `starcat-pro` 验收记录

- [x] 迁移前工作树干净；`dev` 指向 `fee503f`，`main` 指向 `6b1d8f2`，两个分支均已推送，当前没有 tag。
- [x] Repository ID 为 `R_kgDOTPEWHg`，Public，默认分支为 `main`；Issue、PR、Release、watchers、forks 均为 0，stars 为 1。
- [x] 迁移前无 Actions workflow、Repository Secret、Variable、Environment、Pages、webhook、deploy key、ruleset 或 branch protection。
- [x] mirror 备份保存到 `/Users/dong4j/Developer/1.AI/ai-incubator/Starcat-GitHub-Migration-Backups/2026-07-20/starcat-pro.git`，`show-ref` 与 `git fsck --full` 校验通过。
- [x] 2026-07-20 14:08 CST 完成 `dong4j/starcat-pro` → `starcat-app/starcat-pro` Transfer；Repository ID、Public visibility、默认分支、stars 与迁移前 refs 保持不变。
- [x] 本地 `origin` 已更新为 `https://github.com/starcat-app/starcat-pro.git`，`fetch --prune` 与 `push --dry-run origin dev main` 通过。
- [x] 旧 GitHub URL 返回 301 到新地址，新旧 Git URL 的 `ls-remote` 均返回相同 refs。
- [x] `starcat-pro` 自身链接更新分别提交到 `dev`（`822a305`）与 `main`（`30c8b7e`），未把未发布 dev 内容带入 main。
- [x] 统一 README 推广脚本、主仓库 supports 索引与 11 个独立项目 README 已改用 `starcat-app/starcat-pro`；独立项目均按仓库分别提交到 `dev`，未触发 Release 或部署。

#### 6.1.3 `starcat-safari-plugin` 验收记录

- [x] 迁移前工作树干净；本地与远端 `dev` / `main` 均指向 `3625f40`，当前没有 tag。
- [x] Repository ID 为 `R_kgDOTKtALw`，Public，默认分支为 `main`；Issue、PR、Release、stars、watchers、forks 均为 0，Security Policy 已启用。
- [x] 迁移前无 Actions workflow、Repository Secret、Variable、Environment、Pages、webhook、deploy key、ruleset 或 branch protection。
- [x] mirror 备份保存到 `/Users/dong4j/Developer/1.AI/ai-incubator/Starcat-GitHub-Migration-Backups/2026-07-20/starcat-safari-plugin.git`，`show-ref` 与 `git fsck --full` 校验通过。
- [x] 2026-07-20 14:22 CST 完成 `dong4j/starcat-safari-plugin` → `starcat-app/starcat-safari-plugin` Transfer；Repository ID、Public visibility、默认分支与迁移前 refs 保持不变。
- [x] 本地 `origin` 已更新为 `https://github.com/starcat-app/starcat-safari-plugin.git`，`fetch --prune` 与 `push --dry-run origin dev main` 通过。
- [x] 旧 GitHub URL 返回 301 到新地址，新旧 Git URL 的 `ls-remote` 均返回相同 refs。
- [x] Safari 插件链接更新提交 `bcfd86b` 已推送到组织仓库的 `dev` / `main`，两个分支最终 refs 一致。
- [x] App 设置 / About、Direct 页面、supports 索引、clone 脚本、统一 README 推广脚本与生态 README 已改用 `starcat-app/starcat-safari-plugin`；可能触发部署的 API 仓库只更新 `dev`。

### 6.2 第二批：带 Release / 分发入口的仓库

- [x] `starcat-chrome-plugin`
- [x] `homebrew-starcat`

#### 6.2.1 `starcat-chrome-plugin` 验收记录

- [x] 迁移前工作树干净；本地与远端 `dev` / `main` 均指向 `4397866`，当前没有 tag。
- [x] Repository ID 为 `R_kgDOTKs9CA`，Public，默认分支为 `main`；stars 为 1，Issue、PR、Release、watchers、forks 均为 0，Security Policy 已启用。
- [x] 迁移前仅有一个 active Release workflow（ID `308137548`）；无 Repository Secret、Variable、Environment、Pages、webhook、deploy key、ruleset 或 branch protection。
- [x] mirror 备份保存到 `/Users/dong4j/Developer/1.AI/ai-incubator/Starcat-GitHub-Migration-Backups/2026-07-20/starcat-chrome-plugin.git`，`show-ref` 与 `git fsck --full` 校验通过。
- [x] 2026-07-20 14:36 CST 前完成 `dong4j/starcat-chrome-plugin` → `starcat-app/starcat-chrome-plugin` Transfer；Repository ID、Public visibility、默认分支、stars、workflow ID 与迁移前 refs 保持不变。
- [x] 本地 `origin` 已更新为 `https://github.com/starcat-app/starcat-chrome-plugin.git`，`fetch --prune` 与 `push --dry-run origin dev main` 通过。
- [x] 旧 GitHub URL 返回 301 到新地址，新旧 Git URL 的 `ls-remote` 均返回相同 refs。
- [x] Chrome 插件链接更新提交 `2556ef5` 已推送到组织仓库的 `dev` / `main`；Release workflow 仅由 tag 触发，本次未创建 tag，Actions 无新运行。

#### 6.2.2 `homebrew-starcat` 验收记录

- [x] 迁移前工作树干净；本地与远端 `dev` / `main` 均指向 `02c535d`，当前没有 tag。
- [x] Repository ID 为 `R_kgDOTPHbBA`，Public，默认分支为 `main`；Issue、PR、Release、stars、watchers、forks 均为 0。
- [x] 迁移前无 Actions workflow、Repository Secret、Variable、Environment、Pages、webhook、deploy key、ruleset 或 branch protection。
- [x] mirror 备份保存到 `/Users/dong4j/Developer/1.AI/ai-incubator/Starcat-GitHub-Migration-Backups/2026-07-20/homebrew-starcat.git`，`show-ref` 与 `git fsck --full` 校验通过。
- [x] 2026-07-20 14:36 CST 前完成 `dong4j/homebrew-starcat` → `starcat-app/homebrew-starcat` Transfer；Repository ID、Public visibility、默认分支与迁移前 refs 保持不变。
- [x] 本地 `origin` 已更新为 `https://github.com/starcat-app/homebrew-starcat.git`，`fetch --prune` 与 `push --dry-run origin dev main` 通过。
- [x] 旧 GitHub URL 返回 301 到新地址，新旧 Git URL 的 `ls-remote` 均返回相同 refs。
- [x] Homebrew 链接更新提交 `7414a4a` 已推送到组织仓库的 `dev` / `main`；`brew tap-info --json=v1 starcat-app/starcat` 已能正确解析 tap 名称与仓库路径。

### 6.3 第三批：API 服务

- [x] `starcat-discovery-api`
- [x] `starcat-recommend-api`
- [x] `starcat-wiki-api`
- [x] `starcat-sharing-api`
- [x] `starcat-trending-api`
- [x] `starcat-weekly-api`

#### 6.3.1 API 仓库验收记录

| 仓库 | Repository ID | 迁移前 `dev` / `main` | tags | Actions / Secret / Environment | namespace 提交 |
|---|---|---|---|---|---|
| `starcat-discovery-api` | `R_kgDOTLIgBw` | `1203291` / `1203291` | 无 | 无 workflow / 无 Secret / 无 Environment | `c5a6e5d`（`dev` / `main`） |
| `starcat-recommend-api` | `R_kgDOTLIjMQ` | `93f3cc0` / `eca3b0a` | 无 | 5 workflows / 无 Secret / 无 Environment | `0c1b78c`（仅 `dev`） |
| `starcat-wiki-api` | `R_kgDOS3Fdeg` | `116df22` / `08f1c11` | `v1.0.0`、`v1.1.0` | 5 workflows / `FLY_API_TOKEN` / 无 Environment | `abc1f36`（仅 `dev`） |
| `starcat-sharing-api` | `R_kgDOSzqE8Q` | `04de1b9` / `2b8d1a6` | `v1.0.0`、`v1.1.0`、`v1.1.1` | 5 workflows / `FLY_API_TOKEN` / 无 Environment | `dae8d5f`（仅 `dev`） |
| `starcat-trending-api` | `R_kgDOSzqDvw` | `04032c6` / `fa28510` | `v1.0.0`、`v1.1.0`、`v1.1.1` | 5 workflows / `FLY_API_TOKEN` / `production` | `39bb192`（仅 `dev`） |
| `starcat-weekly-api` | `R_kgDOSzwX_w` | `f50254e` / `d82afd7` | `v1.0.0`、`v1.1.0`、`v1.1.1` | 5 workflows / `FLY_API_TOKEN` / 无 Environment | `5468938`（仅 `dev`） |

- [x] 6 个仓库迁移前工作树干净，本地分支与远端 refs 一致；上表的 Repository ID、Public visibility、默认分支、stars、Issue / PR、workflow IDs、Secret 名称与 Environment 在 Transfer 后保持不变。
- [x] mirror 备份分别保存到 `/Users/dong4j/Developer/1.AI/ai-incubator/Starcat-GitHub-Migration-Backups/2026-07-20/REPOSITORY.git`，6 个备份的 `show-ref` 与 `git fsck --full` 校验通过。
- [x] 2026-07-20 14:48 CST 前串行完成 6 个 `dong4j/REPOSITORY` → `starcat-app/REPOSITORY` Transfer；每个旧 GitHub URL 均返回 301，新地址的 branches / tags 与备份基线一致。
- [x] 6 个本地 `origin` 均已更新为 `https://github.com/starcat-app/REPOSITORY.git`，`fetch --prune` 与 `push --dry-run origin dev main` 通过。
- [x] 6 个 Go module、absolute import、仓库内文档与全生态入口已改用 `github.com/starcat-app/*`；`go mod tidy` 通过，全部 Go 测试通过（Discovery 25、Recommend 10、Wiki 22、Sharing 9、Trending 119、Weekly 91）。
- [x] 仅无 Actions 的 `starcat-discovery-api` 同步 `dev` / `main`；其余 5 个服务的 namespace 提交仅推送 `dev`，生产 `main` refs 保持不变。
- [x] Transfer 后 GitHub 自动重建 Dependabot 任务，Sharing / Trending / Weekly 因现有 `workflow_run` 配置启动 Docker；Fly Deploy 与 Release 均 skipped，3 个 Docker run（`29722607823`、`29722582607`、`29722607044`）已在构建阶段取消，日志无 manifest push 记录，未执行生产部署。

每个仓库必须满足：

- [ ] `starcat-app/REPOSITORY` 为 Public。
- [ ] 默认分支、branch、tag、Release、Issue、PR、stars、watchers 保留。
- [ ] 本地 remote 已改为 `starcat-app`。
- [ ] old URL redirect 正常。
- [ ] Actions、Secrets 名称、Variables、Environments 与基线一致。
- [ ] 非部署 CI 可运行；未触发 Release、Package 发布或生产部署。
- [ ] 当前仓库验收完成后才开始下一个仓库。

---

## 7. 私有仓库迁移

### 7.1 `Starcat`

- [x] 主仓库所有需要保留的远端 commit、branch、tag 已推送；本地实验 refs 已单独备份。
- [x] 记录 Private visibility、协作者和权限基线。
- [x] `starcat-app` Base permission 已改为 `None`。
- [x] `starcat-app` 下不存在 `Starcat` 同名仓库。
- [x] dong4j 明确确认执行 Transfer。
- [x] 转移完成后仍为 **Private**。
- [x] `origin` 更新为 `git@github.com:starcat-app/Starcat.git`。
- [x] 私有 clone、fetch、push dry-run 正常。
- [x] 未授权组织成员无法读取仓库。
- [x] 原有协作者权限符合预期。

验收记录：

- [x] 迁移前工作树干净；`dev` 为 `c59a8d7`、`main` 为 `ded898a4`，远端分支与 `v1.0.0` tag 已记录。
- [x] Repository ID 为 `R_kgDOSrV8GA`，Private，默认分支为 `main`；唯一协作者为 `dong4j`（Admin），无 Actions workflow、Secret、Variable、Environment、Pages、webhook 或 deploy key。
- [x] 远端 mirror 保存到 `/Users/dong4j/Developer/1.AI/ai-incubator/Starcat-GitHub-Migration-Backups/2026-07-20/Starcat.git`，`fsck --full` 通过；所有本地 refs 另存为同目录 `Starcat-local-refs.bundle`，`git bundle verify` 通过。
- [x] 2026-07-20 完成 `dong4j/Starcat` → `starcat-app/Starcat` Transfer；Repository ID、Private visibility、默认分支、branches 与 tag 保持不变。
- [x] 本地 `origin` 已更新为 `git@github.com:starcat-app/Starcat.git`；新旧 Git URL 返回相同 refs，`fetch --prune` 与 `push --dry-run origin dev main` 通过。
- [x] 当前文档、脚本、Multica 项目资源与测试防泄漏断言已收口到组织 namespace；Multica 自动托管的 `GEMINI.md` 等待平台下次刷新，不手工修改托管区。

### 7.2 `starcat-license-api`

- [x] 记录 Private visibility、协作者、Secrets、部署配置和权限基线。
- [x] dong4j 明确确认执行 Transfer。
- [x] 转移完成后仍为 **Private**。
- [x] `origin` 更新为 `git@github.com:starcat-app/starcat-license-api.git`。
- [x] Fly.io app、volume、Secrets、域名和生产配置不因 GitHub owner 改变而修改。
- [x] 未执行任何 visibility change。
- [x] 未授权组织成员无法读取仓库。
- [x] 私有 clone、fetch、push dry-run 正常。

验收记录：

- [x] 迁移前工作树干净；`dev` 为 `eafde36`、`main` 为 `a7b3517`，当前没有 tag。
- [x] Repository ID 为 `R_kgDOTPIEIg`，Private，默认分支为 `main`；唯一协作者为 `dong4j`（Admin），无 Actions workflow、Secret、Variable、Environment、Pages、webhook 或 deploy key。
- [x] mirror 保存到 `/Users/dong4j/Developer/1.AI/ai-incubator/Starcat-GitHub-Migration-Backups/2026-07-20/starcat-license-api.git`，`show-ref` 与 `fsck --full` 通过。
- [x] 2026-07-20 完成 `dong4j/starcat-license-api` → `starcat-app/starcat-license-api` Transfer；Repository ID、Private visibility、默认分支和 refs 保持不变。
- [x] 本地 `origin` 已更新为 `git@github.com:starcat-app/starcat-license-api.git`；新旧 Git URL 返回相同 refs，`fetch --prune` 与 `push --dry-run origin dev main` 通过。
- [x] Go module / import 已更新为 `github.com/starcat-app/starcat-license-api`，提交 `6702378` 仅推送 `dev`；`main` 保持不变，`go test`、race、vet、build 均通过。
- [x] 未修改 Fly app、volume、Secrets、域名或生产配置；迁移后 `https://starcat-license-api.fly.dev/healthz` 返回 `ok`。

最终强制检查：

- [x] `gh repo view starcat-app/Starcat --json visibility` 返回 `PRIVATE`。
- [x] `gh repo view starcat-app/starcat-license-api --json visibility` 返回 `PRIVATE`。

---

## 8. 在组织下创建 CLI 仓库

### 8.1 `starcat-cli`

- [x] 本地开发改动已按功能边界提交。
- [x] 单测、race、vet、build 与脚本语法检查通过。
- [x] README、LICENSE、SECURITY、CONTRIBUTING、Release workflow 已收口。
- [x] 所有旧 `dong4j/starcat-cli` / `dong4j/homebrew-starcat-cli` 引用已按创建顺序处理。
- [x] 在 `starcat-app` 下创建 Public 仓库并首次 push。

```bash
gh repo create starcat-app/starcat-cli \
  --public \
  --source supports/starcat-cli \
  --remote origin \
  --push
```

### 8.2 `homebrew-starcat-cli`

- [x] 首个 commit 已完成。
- [x] Formula 生成与 audit workflow 已准备好。
- [x] 在 `starcat-app` 下创建 Public 仓库并首次 push。

```bash
gh repo create starcat-app/homebrew-starcat-cli \
  --public \
  --source supports/homebrew-starcat-cli \
  --remote origin \
  --push
```

- [ ] `brew tap starcat-app/starcat-cli` 能正确解析到 `starcat-app/homebrew-starcat-cli`。
- [x] CLI Release workflow 的 `HOMEBREW_TAP_TOKEN` 只授予目标 tap 所需权限；Fine-grained PAT 仅绑定 `starcat-app/homebrew-starcat-cli`，到期日为 2027-07-21。
- [ ] 在 2027-07-21 前轮换 `HOMEBREW_TAP_TOKEN`，轮换后只做 Secret 存在性与权限验证，不输出 Token 明文。

---

## 9. GitHub Actions、Fly.io 与 Packages

### 9.1 Actions 与 Secrets

- [ ] 仓库级 Secret 名称在迁移后仍存在，不读取 Secret 值。
- [ ] Environment 与 protection 配置仍存在。
- [x] 组织 Actions policy 允许当前使用的第三方 actions；`starcat-cli` CI 与 `homebrew-starcat-cli` Audit Formula 已成功运行。
- [ ] `GITHUB_TOKEN` 的 workflow permissions 符合最小权限原则。
- [ ] 只运行测试 / 构建类 workflow 做验证。
- [ ] 不手动触发 `fly-deploy.yml`、Release workflow 或 Package 发布 workflow。

### 9.2 Fly.io

- [ ] GitHub repository owner 变化不修改 Fly app 名称。
- [ ] GitHub repository owner 变化不修改 Fly volume、生产数据库或 Secret。
- [ ] 迁移后只做 `fly status` / health check 等只读验证。
- [ ] 如 GitHub Actions 与 Fly 需要重新绑定，只重授权，不创建新 Fly app。
- [ ] 生产部署验证必须另行取得 dong4j 明确授权。

### 9.3 GitHub Container Registry

API Docker workflow 使用 `ghcr.io/${{ github.repository }}`，转移后新镜像 namespace 将从：

```text
ghcr.io/dong4j/REPOSITORY
```

变为：

```text
ghcr.io/starcat-app/REPOSITORY
```

- [ ] 盘点 `dong4j` 账号下所有 Starcat GHCR Package、tag、visibility 和使用方。
- [ ] 记录哪些 Package 与仓库关联，哪些使用 granular permissions。
- [ ] 决定旧 namespace 的保留周期。
- [ ] 为迁移后的仓库配置 Package Actions access。
- [ ] 在明确授权后发布新 namespace 的第一份镜像。
- [ ] 更新所有部署和文档中的 image reference。
- [ ] 新镜像验证完成前不删除旧 namespace 镜像。

---

## 10. OAuth App 所有权转移

### 10.1 转移前快照

- [x] App owner：`dong4j`。
- [x] App name：`Starcat`。
- [x] Client ID：`Ov23li4suXj1nNsWtHHG`。
- [x] Callback：`starcat://callback`。
- [x] Device Flow：Enabled。
- [x] 记录现有 Client Secret 的末尾标识，不记录完整 Secret。
- [x] 记录当前已授权用户数量。
- [x] 使用一个现有登录用户验证当前正式版可正常访问 GitHub API。

### 10.2 转移

```text
https://github.com/settings/applications/3633797
→ Transfer ownership
→ New owner: starcat-app
```

- [x] dong4j 明确确认执行 OAuth App Transfer。
- [x] 发起 Transfer 后，以 Organization Owner 身份进入组织 OAuth Apps 页面。
- [x] 在 `Pending transfer requests` 中完成接收。
- [x] 未创建第二个 OAuth App。
- [x] 未生成、删除或轮换 Client Secret。
- [x] 未撤销用户授权或 token。

### 10.3 转移后验证

- [x] Owner 已变为 `starcat-app`。
- [x] Client ID 未变化。
- [x] Client Secret 末尾标识未变化。
- [x] Callback 仍为 `starcat://callback`。
- [x] Device Flow 仍为 Enabled。
- [x] 已授权用户数量没有因为转移异常归零。
- [x] Homepage 更新为 `https://starcat.ink`。
- [x] 现有已登录正式版无需重新登录，GitHub 同步正常。
- [x] 测试账号完成一次新的 Device Flow 登录。
- [x] 测试账号完成一次新的 Web Flow + `starcat://callback` 登录。
- [ ] OAuth App 转移后观察期内没有集中登录失败。

---

## 11. 旧 namespace 全面替换

> GitHub redirect 只用于兼容，不作为长期配置。替换动作按独立仓库分别提交，避免跨仓库混合 commit。

### 11.1 主仓库与 supports 运维文件

- [x] `supports/README.md`
- [x] `supports/SYNC.md`
- [x] `supports/clone-all.sh`
- [x] `supports/AGENTS.md`
- [x] `supports/.claude/CLAUDE.md`（Claude Code 配置入口，固定引用 `supports/AGENTS.md`）
- [x] `supports/scripts/sync-starcat-readme-promo.py`（核对后无旧 Private owner 引用）
- [x] 其它脚本、配置、测试、文档中的旧 owner 引用已替换或分类；迁移来源记录、旧地址防泄漏断言与自动托管快照除外。
- [x] `raw.githubusercontent.com/dong4j/starcat-pro/*` 改为组织 namespace。

### 11.2 Go module 与 import path

- [x] 每个 Go 项目的 `go.mod` module 改为 `github.com/starcat-app/REPOSITORY`。
- [x] 项目内 absolute import 同步改为新 module path。
- [x] 执行 `go mod tidy`。
- [x] 执行 `go test ./...`、`go test -race ./...`、`go vet ./...`、`go build ./...`。
- [x] 不修改 Fly app 名、数据库路径或运行时配置。

### 11.3 安装与发布链接

- [ ] Starcat 官网、下载链接、Release URL、Issue URL。
- [ ] Chrome / Safari 插件 README、Store 文案与 Review Kit。
- [x] Homebrew Cask：`brew tap starcat-app/starcat`。
- [ ] Starcat CLI：`brew tap starcat-app/starcat-cli`。
- [ ] CLI install scripts、updater、checksum 和 Release URL。
- [ ] CLI Release workflow 中 `homebrew-starcat-cli` clone 地址。
- [ ] Issue template、CONTRIBUTING、SECURITY、badge、raw image URL。

### 11.4 搜索验收

在排除 Git 历史、依赖和明确不迁移项目后执行：

```bash
rg -n --hidden --no-ignore \
  --glob '!**/.git/**' \
  --glob '!**/node_modules/**' \
  --glob '!supports/backups/**' \
  'github\.com/dong4j|raw\.githubusercontent\.com/dong4j|dong4j/(Starcat|starcat)'
```

- [ ] 每一个剩余命中均已分类：必须修改、历史说明或明确排除。
- [ ] 不误改 `ai-file-wall` 或第三方上游地址。

---

## 12. 组织首页与统一治理

- [x] 创建 Public 仓库 `starcat-app/.github`。
- [x] 新增 `profile/README.md`，说明 Starcat 产品、下载入口、支持渠道和开源项目。
- [ ] 固定最多 6 个核心公开仓库。
- [ ] 为 Public 仓库统一配置 Issues、Discussions、security policy 与贡献入口。
- [ ] 为 Private 仓库按团队授予最小权限。
- [x] 确认组织名称、头像、官网 `https://starcat.ink` 和公开联系方式正确。

---

## 13. 文档同步收尾

- [x] 更新 `supports/README.md` 的仓库数量、owner、公开 / 私有标记和 clone 示例。
- [x] 更新 `supports/SYNC.md` 的独立仓库清单与新机器 clone 流程。
- [x] 更新 `supports/clone-all.sh` 的所有 GitHub URL 和项目数量。
- [x] 更新 `supports/AGENTS.md` 中的 module path 和 clone 示例。
- [x] 更新 `docs/1-立项/开发前问题清单.md` 中“OAuth App 未注册”的过期结论，记录 OAuth App 已转移到组织。
- [x] 检查其它设计、发版、插件与 CLI 文档中的旧 owner；Multica 自动托管内容改为更新项目资源源数据。
- [x] 未修改 `docs/功能实现总览.md`；如需登记迁移完成状态，另行提交草稿并等待 dong4j 明确授权。

---

## 14. 最终验收矩阵

### 14.1 仓库

- [x] 12 个现有公开仓库全部位于 `starcat-app` 且保持 Public。
- [x] `Starcat` 位于 `starcat-app` 且保持 Private。
- [x] `starcat-license-api` 位于 `starcat-app` 且保持 Private。
- [x] `starcat-cli`、`homebrew-starcat-cli` 位于 `starcat-app` 且为 Public。
- [x] `ai-file-wall` 未发生变化。
- [x] 所有迁移仓库的 branch、tag、Release、Issue、PR 和权限符合基线。

### 14.2 本地开发

- [x] 所有迁移范围内的本地 remote 指向正确的新 owner。
- [ ] `supports/clone-all.sh` 能在新目录完成 clone dry-run / 实机抽查。
- [x] Go module、import、脚本、文档不再依赖旧 namespace；迁移记录与自动托管快照已分类。
- [x] Starcat 主项目的针对性构建 / 测试通过。
- [x] 各独立项目的针对性测试通过。

### 14.3 登录与用户影响

- [x] 已登录用户无需重新登录。
- [x] Device Flow 可创建新授权。
- [x] Web Flow + PKCE + `starcat://callback` 可创建新授权。
- [x] OAuth App Client ID、Secret、callback 和 Device Flow 配置未被迁移破坏。

### 14.4 CI/CD 与运行环境

- [ ] 非部署 CI 正常。
- [ ] Repository Secret 名称、Environment、Actions permissions 正确。
- [ ] Fly 生产 app、volume、域名和数据未发生非预期变化。
- [ ] GHCR 新旧 namespace 迁移策略已完成并验证。
- [ ] Homebrew 与插件 Release 链路通过单独授权的发布验收。

### 14.5 重定向与公开入口

- [x] 旧 GitHub 仓库 URL 仍能重定向。
- [x] 没有在 `dong4j` 下创建同名仓库破坏重定向。
- [x] 官网、README、OAuth Homepage、安装命令都指向正式入口。
- [x] `starcat-app` 组织首页可以清晰找到 Starcat 产品和核心公开项目。

---

## 15. 异常停止与回滚

- [ ] 当前仓库迁移失败时立即停止批次，保留所有日志和基线快照。
- [ ] 不通过删除仓库或强推来“重试”。
- [ ] 如果新 owner 下仓库状态异常，先核对 GitHub Transfer 状态与权限，再决定是否转回 `dong4j`。
- [ ] 回滚仓库所有权前确认旧 namespace 下没有同名仓库。
- [ ] 回滚本地 remote 时只修改 URL，不重写 branch、tag 或工作树。
- [ ] OAuth App 异常时不重建 App、不换 Client ID、不撤销全部 token；优先核对 pending transfer、owner、Secret、callback 和 Device Flow。
- [ ] GitHub Packages 与仓库 Transfer 分开处理；Package 异常不通过回滚代码仓库来解决。
- [ ] 生产服务异常时按现有 Fly 运维 SOP 处理，不创建新 app 或新 volume。

---

## 16. 完成签字

- [ ] 迁移执行记录、异常记录与验证证据已归档。
- [ ] 所有未完成项均有明确负责人和后续计划。
- [ ] dong4j 完成最终人工检查。
- [ ] dong4j 明确确认解除迁移冻结。
- [ ] 如需登记到 `docs/功能实现总览.md`，已单独获得“可以写总览 / 同步总览”授权。

完成时间：`YYYY-MM-DD HH:MM`

执行人：`________________`

最终确认：`________________`

---

## 参考资料

- [GitHub：Transferring a repository](https://docs.github.com/en/repositories/creating-and-managing-repositories/transferring-a-repository)
- [GitHub：Transferring ownership of an OAuth app](https://docs.github.com/en/apps/oauth-apps/maintaining-oauth-apps/transferring-ownership-of-an-oauth-app)
- [GitHub：Setting repository visibility](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility)
- [GitHub：About permissions for GitHub Packages](https://docs.github.com/en/packages/learn-github-packages/about-permissions-for-github-packages)
- [GitHub：Setting base permissions for an organization](https://docs.github.com/en/organizations/managing-user-access-to-your-organizations-repositories/managing-repository-roles/setting-base-permissions-for-an-organization)
