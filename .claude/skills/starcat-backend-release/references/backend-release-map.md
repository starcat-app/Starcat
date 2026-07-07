# 后端 API 发布地图

## 项目类型

| 项目 | 脚本形态 | 风险点 |
|---|---|---|
| `starcat-sharing-api` | 共享完整 deploy 脚本 | PR/merge/tag/Actions/Fly 全链路 |
| `starcat-trending-api` | 共享完整 deploy 脚本 | 同上 |
| `starcat-weekly-api` | 共享完整 deploy 脚本 | 同上 |
| `starcat-wiki-api` | 共享完整 deploy 脚本 | 同上 |
| `starcat-recommend-api` | 简化脚本 | 本地 Go 测试、vet、build 后 tag + push |
| `starcat-discovery-api` | 简化脚本 | 直接 fly deploy，不创建 PR/tag |

## 共享完整 deploy 流程

适用：sharing、trending、weekly、wiki。

命令：

```bash
cd supports/starcat-trending-api
./scripts/deploy.sh --dry-run v1.1.0
./scripts/deploy.sh v1.1.0
```

流程：

1. 校验版本号 `vX.Y.Z`；
2. 确认在 git 仓库，且当前分支不是 main/master；
3. 确认工作区干净，且没有未跟踪文件；
4. 检查当前分支未推送 commit；
5. 检查本地和 origin 都没有目标 tag；
6. 检查目标 tag 高于最新已有 tag；
7. 检查 `gh` 已认证；
8. 推送当前分支；
9. 创建 PR 到 main；
10. merge PR，保留 dev 历史；
11. checkout main 并 pull；
12. 在 merge commit 上创建 annotated tag；
13. push tag，触发 GitHub Actions 和 Fly deploy。

关键约束：

- tag 必须指向 main 的 merge commit，而不是 dev tip。
- main/master 上禁止运行。
- 不能 squash merge。
- dry-run 仍会执行前 1 到 7 步只读校验；7 个副作用命令只 echo。
- 脚本失败不会自动关闭已创建 PR，需要手动处理。

## recommend 发布脚本

命令：

```bash
cd supports/starcat-recommend-api
./scripts/deploy.sh v1.1.0
```

流程：

1. 要求版本号非空；
2. `go test ./...`；
3. `go test -race ./...`；
4. `go vet ./...`；
5. `go build ./...`；
6. `git tag <version>`；
7. `git push origin <version>`。

注意：这个脚本没有 dry-run、没有 PR、没有远端 tag 冲突检查。执行前必须手动检查工作区、分支和 tag。

## discovery 发布脚本

命令：

```bash
cd supports/starcat-discovery-api
./scripts/deploy.sh v1.1.0
```

流程：

- 要求版本号非空；
- 执行 `fly deploy -a starcat-discovery-api --build-arg VERSION="$VERSION"`。

注意：这个脚本直接部署 Fly，不创建 tag，不跑测试。执行前必须先确认是否符合当前发布策略。

## 只读检查清单

```bash
git status --short
git branch --show-current
git tag --list 'v*' --sort=-v:refname | head
git ls-remote --tags origin 'refs/tags/vX.Y.Z'
gh auth status
```

## 失败恢复

| 失败点 | 处理 |
|---|---|
| main/master 上运行 | 切到 dev 或 feature 分支后重跑 |
| 工作区不干净 | 提交、stash 或清理后重跑 |
| tag 已存在 | 换更高版本号；不要自动删远端 tag |
| gh 未认证 | 让用户执行 `gh auth login` |
| PR 创建后失败 | 手动查看或关闭 PR，再决定是否重跑 |
| tag push 后 Actions 失败 | 修复代码后使用新版本号重新发布，避免重写已发布 tag |
