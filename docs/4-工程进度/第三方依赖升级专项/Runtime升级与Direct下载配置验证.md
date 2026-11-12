# Runtime 升级与 Direct 下载配置验证

> 状态：实现与本机验证记录；dong4j 于 2026-11-11 确认专项验收通过
> 核对日期：2026-11-09
> 关联：GitHub starcat-app/Starcat#193

> 状态补记（2026-11-12）：第“待验收与回退”节保留 2026-11-09 当时的未覆盖项，不能继续据此把整个专项标为未验收。用户确认不等于补做了 Intel、最低系统、分发产物或 App Store 内嵌二进制升级；各项证据仍以下文实际记录为准，远端 Issue 状态本轮未核对。

## 范围与版本

本记录接续[首批依赖审计](依赖审计与验证记录.md)，更新其中 Runtime 候选尚未验证的阶段结论。dong4j 已明确授权升级三项外部 Runtime 并增加 Direct 设置页的「下载并配置」入口

| Direct 可选组件 | 固定发布版本 | 实际 `--version` | 本轮真实验证架构 |
| --- | --- | --- | --- |
| Codex App Server | rust-v0.167.0 | codex-app-server 0.167.0 | macOS arm64 |
| DeepSeek Harness Runtime | PyPI 0.2.1rc2 | 0.2.1-rc.2 | macOS arm64 |
| CodebaseMemory | v0.12.1 | codebase-memory-mcp 0.12.1 | macOS arm64 |

DeepSeek 仍为预发布版本。Codex 与 CodebaseMemory 清单包含 Intel 资产及哈希，但本轮未执行 Intel 二进制；DeepSeek 的产品入口仍只对 arm64 开放

升级通过 Direct 的可选安装实现，不替换用户全局工具、不改当前 Agent 的 MCP 配置、不覆盖旧安装或真实索引。App Store 不提供下载入口，其内嵌 CodebaseMemory 保持 0.8.1；本记录不表示该渠道内嵌二进制已升级

## 设置页与运行契约

- 三项设置区域均提供右对齐的下载操作、进度、取消和结果；安装期间禁用该区域的路径编辑及检测操作
- 从固定官方 URL 下载，验证 SHA-256，保留完整归档资源，验证可执行权限、签名、实际版本与 stdio `initialize`
- 每次安装写入 `~/Library/Application Support/Starcat/Runtimes/` 下的独立版本目录，成功且未取消后才配置路径；失败清理暂存目录并保留已有配置
- Codex 配置完整包目录，保留 App Server、两个 Host、rg、manifest 与资源树；不只下载单一可执行文件
- DeepSeek 同时配置程序与 Cordis patch，使用 `sdk-minimal`、每轮独立 `DSH_HOME`，显式禁用原生 Shell、PTY 和文件工具，仅通过 Starcat MCP 提供业务工具；旧 carrier 路径提示下载升级
- CodebaseMemory 成功后通过现有 resolver 保存选择；提示首次索引重建和旧版会话冲突。0.12 起 `list_projects` 显式使用 `--format json`，旧版本保持原命令
- 不自动切换当前 Agent backend，不保存或替换模型凭据；About 补充 Codex 与 DeepSeek 的许可证归因

主要实现位于 `RuntimeDownloadInstaller.swift`、`RuntimeDownloadButton.swift`、三项设置卡片、`DeepSeekHarnessAdapter.swift`、`DeepSeekHarnessRuntime.swift` 和 `CodebaseMemoryRunner.swift`

## 固定资产身份

以下均为归档 SHA-256，不与解压后二进制哈希混用

| 资产 | SHA-256 |
| --- | --- |
| codex-app-server-package-aarch64-apple-darwin.tar.gz | d9c8a3efdaa422fc2bc7d7bef65cdb9cc04bfbb818a36bbf3ecb70a71ee755eb |
| codex-app-server-package-x86_64-apple-darwin.tar.gz | 392255425f0afe44fad86b7f51b23ecb7a507f8c08c5e5ee616e543de6f9d0db |
| deepseek_harness_runtime_bin-0.2.1rc2-py3-none-macosx_14_0_arm64.whl | 96a173abd14141d5328a78791b69729cbfe22fa3e9daf1dc2600d0daa4d6bb28 |
| codebase-memory-mcp-ui-darwin-arm64.tar.gz | 9bfcbe38414b47969a3e1d1c1999f5357409387c86fa3d24221b5458267660d2 |
| codebase-memory-mcp-ui-darwin-amd64.tar.gz | ca6e64397a8ae80cec898a8205a6aa16750ac798acc05a0c3ed983837944a581 |

URL 与对应哈希固定在生产 `DownloadableRuntime.asset`。DeepSeek 包内 manifest 和协议 `serverInfo` 的版本与发布号不同，身份采用官方归档哈希及实际 CLI 版本，不凭握手版本判断升级成功

## 本机验证

环境为 Apple Silicon、macOS 27.0.1、稳定版 Xcode 27.0。测试和构建在包含其他 Agent 并行改动的工作区执行，不归因到单一提交

| 检查 | 结果与边界 |
| --- | --- |
| 三项官方 arm64 归档下载 | 实际下载完成，哈希核对通过 |
| 生产安装器全链路 | 三项解包、资源布局、签名、版本及真实协议初始化通过；通过注入本地官方归档复用生产安装器，未覆盖设置页 URLSession 联网下载 |
| Codex 真实进程 turn | 本地模拟 Responses 服务下完成 initialize、thread/start、turn/start、文本流、usage、turn/completed，exit 0；不是云端模型验收 |
| DeepSeek 真实进程 turn | 本地模拟模型与 MCP 下完成工具发现、调用、结果回传、最终回答和 idle，exit 0；不是 App 内真实 Swift MCP 服务与云端模型联调 |
| DeepSeek 无本地工具 | 无 MCP 的真实 turn 中模型工具列表为空，配置补丁检查通过 |
| CodebaseMemory 真实进程 | 临时仓库索引生成 17 个节点、16 条边；列出 17 个 MCP 工具，HTTP 返回 200，进程退出 |
| 全量 Swift 测试 | 3845 tests / 435 suites 通过，1 known issue |
| 最终串行定向测试 | 45 tests / 3 suites 通过，包含最后追加的旧 DeepSeek carrier 升级提示测试 |
| 最终 Direct 与 App Store Debug 构建 | 标准 Makefile 入口均通过，仅构建与产物校验，未启动 App |
| 本地化 | 新增 10 个 key，全部 17 种语言覆盖；两个 Bundle 的 17 个 lproj 均包含新 key；英文 translated，其余 needs_review；Catalog diff 仅新增 |
| 静态检查 | `git diff --check`、脚本 `bash -n`、Catalog JSON 解析通过 |

Codebase 验证同时隔离 HOME、CBM_CACHE_DIR 和上游支持的 CBM_RUNTIME_DIR；仅隔离缓存不足以避免连接当前 0.10.8 daemon。使用短临时 rendezvous 路径，未停止当前 Agent 或替换其工具

App Store 单测 host 尝试直接访问外部 Runtime 时受到沙盒拒绝，不能把这次环境失败视为 Direct 集成通过。真实安装与协议检查改用无沙盒命令行入口，直接编译生产安装器；普通 Swift 单测不启用依赖外部 Runtime 的可选集成开关

最终增量检查曾因并行标准入口竞争同一 XcodeGen 工程导致定向测试在生成阶段失败，随后串行重跑；该次失败不是测试断言失败

## 复核入口与证据

```bash
make test TEST_ARGS="-only-testing:StarcatTests/RuntimeDownloadInstallerTests -only-testing:StarcatTests/ExternalAgentProtocolAdapterTests -only-testing:StarcatTests/ExternalAgentRuntimeHostTests"
STARCAT_RUNTIME_FIXTURE_ROOT=/tmp/starcat-runtimes-20261109 make test-runtime-downloads
make build-direct
make build-appstore
```

上述标准入口共享工程生成步骤，应串行执行。真实归档 smoke 当前只对本机 arm64 fixture 开放，归档目录须包含 `codex-app-server-package-aarch64-apple-darwin.tar.gz`、`deepseek-full.whl`、`codebase-full.tar.gz`

本机临时证据位于 `/tmp/starcat-runtimes-20261109/`，包括 `full-tests-final.log`、`final-tests-serial.log`、`final-direct.log`、`final-appstore.log`、`codex-turn-result.json`、`deepseek-mcp-turn-result.json` 和 `codebase-result.json`；临时文件不保证永久保留

## 待验收与回退

- Direct 界面真实下载、进度、取消、错误提示、长译文和路径配置后的操作
- 实际 Starcat MCP 与真实云端模型的 turn、工具、取消、超时和错误恢复
- macOS 15、Intel、干净机器以及旧用户索引重建
- App Store 内嵌 CodebaseMemory 升级属于未完成范围，不能据此关闭整个依赖专项

回退时在设置页重新选择旧 Runtime 目录或程序即可；旧安装、用户索引和凭据保持保留。若要退回旧 DeepSeek carrier，还需恢复与其匹配的旧 adapter 和配置格式，新 adapter 会明确拒绝旧 carrier

本阶段未操作 GUI，未提交、push、打包、公证、上传或发布；未写功能总览或 Changelog。GitHub #193 保持 Open，整个专项仍为 In Progress，等待剩余兼容性检查和人工验收
