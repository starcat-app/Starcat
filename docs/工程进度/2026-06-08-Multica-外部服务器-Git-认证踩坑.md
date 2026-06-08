# Multica 接入外部服务器协作：私有仓库 Git 认证踩坑

> 创建日期：2026-06-08
> 状态：**已解决，方案沉淀**
> 影响范围：所有运行 `multica daemon` 的远端 / 外部 mac，需要拉取 GitHub 私有仓库
> 关联任务：[MUL-176](https://multica.ai) — Activity Weekly 分类后端服务

---

## 1. 背景

### 1.1 协作架构

dong4j 在多台 mac 上分布式跑 `multica daemon`，由云端 Multica 平台把任务派发到不同
Mac 上的 agent（cursor / claude / gemini / codex / openclaw）执行。每个任务运行前，
daemon 会按 project resources 自动 `git clone --bare` 对应仓库到本地缓存（`~/multica_workspaces/.repos/...`），再生成 worktree 给 agent 工作。

这套机制对**公开仓库无感**：直接 HTTPS clone 不需要凭证。但**私有仓库**会立刻暴露
"daemon 进程怎么拿到 GitHub 凭证"这个问题。

### 1.2 现象

在某台新装机的外部 mac 上执行 `multica repo checkout https://github.com/dong4j/Starcat`
（Starcat 是私有仓库）返回：

```
Error: checkout failed: repo is configured but not synced
```

但**同一个 Multica 工作区，同样的私有仓库**，在 dong4j 自己日常使用的另一台 mac 上
完全正常 checkout —— 而那台 mac **没有任何额外 multica 环境变量配置**。

### 1.3 用户视角的疑问

> "我在另一台 mac 上都能正常拉取（私有状态下），也没有在 multica 中配置过环境变量，
> 是不是因为当前执行任务的 mac 缺少什么配置？"

**结论先行**：是的，问题不在 multica，在底层 git。两台 mac 的差异是 git credential
helper 配置（隐式状态）不同。

---

## 2. 排查

### 2.1 直接证据：daemon 日志

`~/.multica/daemon.log` 里有非常清晰的一条 ERR：

```
02:41:41.558 ERR repo cache: clone failed
   url=https://github.com/dong4j/Starcat
   error="git clone --bare: fatal: could not read Username for 'https://github.com':
          terminal prompts disabled: exit status 128"
```

翻译：daemon 用 `git clone --bare <Starcat>` 拉私有仓库时，git 想交互式问"你是谁？"，
但 daemon 是非交互后台进程，`GIT_TERMINAL_PROMPT=0`（或等效设置）禁掉了 prompt，
git 没办法继续，直接退出。

**根因不是 multica 自己的鉴权机制，是 git 在这台机器上没有任何可用凭证。**

### 2.2 这台 mac 的真实状态

| 检查项 | 命令 | 结果 |
|---|---|---|
| 全局 git 配置 | `git config --global -l` | `fatal: unable to read config file '/Users/dong4j/.gitconfig'` —— **文件不存在** |
| credential helper | `git config --global credential.helper` | 未设置 |
| `~/.netrc` | `ls ~/.netrc` | 不存在 |
| `url.<X>.insteadOf` token 注入 | `git config --global --get-regexp 'url\..*\.insteadof'` | 空 |
| Keychain `github.com` 凭证 | `security find-internet-password -s github.com` | 没找到 |
| Apple Git 自带 `osxkeychain` helper | `ls /Library/Developer/CommandLineTools/usr/libexec/git-core/git-credential-*` | **存在但未启用** |

**结论**：系统 git（Apple Git 2.50.1 from Xcode Command Line Tools）的 helper
**完全可用但完全没启用**，所以遇到任何需要凭证的 HTTPS git 操作都会立刻失败。

### 2.3 那台"为什么不用配也能用"的 mac

历史路径还原：

1. dong4j 在那台 mac 上手动 `git push` 过某个 GitHub 私有仓库（任意一个）
2. macOS 默认配置下 Apple Git 会引导启用 `osxkeychain` helper，第一次输入 token 后
   自动把 `(github.com, dong4j, <PAT>)` 写进系统 Keychain
3. 之后**任何** git 进程（包括 multica daemon、CI script）拉私有仓库时，
   `osxkeychain` helper 透明返回 token，不需要任何交互

→ 看起来"什么都没配"，其实早就配过了；只是配置存在 Keychain 里而不是 `~/.gitconfig`，
所以肉眼看不到。

---

## 3. 解决方案对比

| 方案 | 简介 | 一次性投入 | 长期成本 | 推荐度 |
|---|---|---|---|---|
| A：`gh auth setup-git` | 让 `gh` CLI 充当 git credential helper | 1 行命令 | 依赖 `GITHUB_TOKEN` env var + 装着 `gh` | ⭐⭐ |
| **B：`osxkeychain` helper + 手动 clone 一次** | 启用 macOS 内置 helper，token 存 Keychain | 3 行命令 + 输入一次 PAT | 零依赖，永久生效 | **⭐⭐⭐⭐⭐ 已采用** |
| C：`url.insteadOf` 注入 token | 在 `~/.gitconfig` 里写 token 重写 URL | 1 行命令 | token 明文落盘，安全风险 | ⭐ |

### 3.1 为什么是方案 B

- **零运行时依赖**：不依赖 env var，不依赖 `gh`，不依赖 multica 自身
- **与平台原生机制一致**：跟 dong4j 另一台 mac 是同一套机制，行为可预期
- **token 加密保护**：macOS Keychain 加密存储，比明文写 `~/.gitconfig` 安全
- **覆盖所有 git 客户端**：Xcode、command-line git、IDE 插件、daemon 全部受益

---

## 4. 方案 B 落地步骤

### 4.1 配置

```bash
# 1. 启用 osxkeychain helper（写入 ~/.gitconfig，自动创建文件）
git config --global credential.helper osxkeychain

# 2. 手动 clone 一次任意私有仓库，触发交互式 token 输入
#    git 会弹出系统对话框（或终端问）让你输 username + password
#    username: GitHub 用户名（如 dong4j）
#    password: 一个具备 repo scope 的 Personal Access Token（不是登录密码！）
git clone https://github.com/dong4j/Starcat /tmp/_test_clone

# 3. 验证 token 已存进 Keychain
security find-internet-password -s github.com
# 预期能看到一条 "class: inet" 记录

# 4. 重启 daemon 让其加载新的 git 行为（重要！daemon 进程已经在跑，
#    虽然 git 配置是动态读的，但保险起见 restart）
multica daemon restart

# 5. 清掉测试克隆
/bin/rm -rf /tmp/_test_clone
```

### 4.2 PAT 来源

GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
→ Generate new token (classic)。

最小权限集：

- `repo`（**必须**，覆盖 contents + pull request + 自管 repo 全部）
- `workflow`（可选，如果 daemon 要触发 GH Actions）

注意 fine-grained tokens 也可以，但要确保对**所有需要 multica 拉取的私有仓库**都
显式授权 `Contents: Read & Write`，否则只对授权过的 repo 子集有效。

### 4.3 验证已生效

**第一层 —— 模拟 daemon 的非交互 clone**：

```bash
GIT_TERMINAL_PROMPT=0 git clone --bare https://github.com/dong4j/Starcat /tmp/_test
echo "EXIT=$?"
# 预期：成功，EXIT=0
# 失败：EXIT=128 + "could not read Username" → 回到 4.1 第 2 步重新触发 token 输入
```

**第二层 —— `multica repo checkout` 端到端**：

```bash
multica repo checkout https://github.com/dong4j/Starcat
# 预期：返回 worktree 路径，无 error
```

**第三层 —— daemon 日志**：

```bash
tail -30 ~/.multica/daemon.log | grep -iE 'starcat|clone|fetch'
# 预期：看到 "INF repo cache: fetching" 或 "INF repo checkout: worktree created"
# 反例：看到 "ERR repo cache: clone failed" + "could not read Username" → 没生效
```

---

## 5. 常见踩坑提示

### 5.1 已经踩过的坑

- **临时把私有仓库改 public 来绕过**：能用但不可持续，外部协作者会看到不该看的代码，
  且每次切换 visibility 需要 owner 权限干预。本任务最初就走了这条弯路。
- **以为是 multica 自身缺鉴权配置**：multica 没有任何独立 GitHub 鉴权机制，
  完全依赖底层 git，所以"在 multica 里配 env"这条路线根本不存在。

### 5.2 后续容易再次踩到的坑

- **token 过期**：GitHub classic PAT 默认 30 天过期。过期后下一次 daemon `git fetch`
  会同样报"could not read Username"。修复：重新跑一次 `git clone <private>`，
  输入新 PAT，Keychain 自动覆盖旧条目。
- **token scope 不够**：如果新建的私有仓库不在 PAT 的可见范围（fine-grained token），
  会得到 `Repository not found` 错误而不是凭证错误，注意区分。
- **多账号场景**：`osxkeychain` 按 `(host, user)` 缓存。如果同一台 mac 同时需要
  GitHub 个人账号和 work org 账号，要么用不同 host alias（`github.com` vs
  `github-work.com` + SSH config），要么走 `GIT_CONFIG_COUNT` env var 的高级用法。
- **CI / 容器内运行 daemon**：osxkeychain 是 macOS 专属，Linux 容器不可用，
  CI 场景请改用 `GITHUB_TOKEN` env var + `url.insteadOf` 注入（方案 C 的容器版）。
- **远端调试 daemon**：daemon 是后台进程，重启后才会显式重载凭证 helper 状态，
  调试时养成 `multica daemon restart` 的习惯。

---

## 6. 决策记录（ADR-lite）

- **决策**：所有运行 `multica daemon` 的 mac 必须启用 `git-credential-osxkeychain`
  helper，并在 Keychain 中预存有效的 GitHub PAT。
- **替代方案被拒理由**：
  - 方案 A（gh helper）依赖 `gh` 二进制 + `GITHUB_TOKEN` env var，多一层运行时依赖；
  - 方案 C（`url.insteadOf` token 注入）安全性差，token 明文写 `~/.gitconfig`。
- **回滚策略**：从 Keychain 删除 github.com 条目 + `git config --global --unset credential.helper`，
  系统回到无凭证状态（私有仓库再次不可用）。
- **后续行动**：所有新接入 multica 的 mac 装机时把 4.1 节当作 checklist 的一项。

---

## 附：调试速查命令

```bash
# 查 daemon 日志最近的 clone / fetch / error
tail -200 ~/.multica/daemon.log | grep -iE 'clone|fetch|error|err '

# 查所有 multica 维护的 bare 缓存
ls ~/multica_workspaces/.repos/*/

# 强制清掉某仓库的 bare 缓存（触发下次 multica repo checkout 重新 clone）
/bin/rm -rf ~/multica_workspaces/.repos/<workspace-id>/github.com+<owner>+<repo>.git

# 验证 git 能否非交互拿到凭证
GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/<owner>/<private-repo> HEAD

# 显示 Keychain 里 github.com 凭证（不显示 password）
security find-internet-password -s github.com

# 把 github.com 凭证从 Keychain 删干净
security delete-internet-password -s github.com
```
