# DeepSeek Harness Runtime 配置

DeepSeek Harness 只用于 **Starcat Direct Debug / macOS arm64**。Runtime 由用户安装在
`~/Library/Application Support/Starcat/Runtimes/`，不会复制进 `Starcat.app` 或 DMG。

## 1. 前置条件

- Apple Silicon Mac。
- Python 3.10 或更高版本；推荐 Python 3.12。
- 已在 Starcat「设置 → AI」中添加、连接测试并启用至少一个 Chat Provider；API Key 保存在 Keychain。

API Key 不写入 `defaults`、Cordis YAML 或仓库。Starcat 按工作台当前 Provider ID 从
Keychain 读取凭据，只通过每轮子进程环境注入；Finder 启动不需要额外导出环境变量。

## 2. 安装固定 Runtime

在 Starcat 仓库根目录执行：

```bash
./scripts/install-deepseek-harness-runtime.sh
```

脚本通过 PyPI macOS arm64 wheel 安装
`deepseek-harness-runtime-bin==0.1.1rc1`，不需要 Node，也不需要在本地编译二进制。
默认安装结果：

```text
~/Library/Application Support/Starcat/Runtimes/deepseek-harness-0.1.1rc1/
├── starcat.cordis.yml
└── venv/lib/python3.*/site-packages/deepseek_harness_runtime/runtime/
    ├── dsh-jsonrpc-agent-pkg-macos-arm64
    ├── dsh-jsonrpc-agent-pkg-macos-arm64-rg
    └── dsh-jsonrpc-agent-pkg-macos-arm64-spawn-helper
```

`starcat.cordis.yml` 不启用 Harness 自带的 `bash/subprocess`。当前 DeepSeek adapter
尚未接入 Starcat 双向 Tool Bridge，放行 Shell 会越过权限边界，并可能因动态解压
`pty.node` 触发 Gatekeeper。

## 3. 配置 Direct Debug

安装脚本会在结尾打印可直接执行的命令。默认配置如下，路径中的 `python3.*` 以脚本
实际输出为准：

```bash
defaults write com.starcat.app.direct.debug DebugExternalAgentRuntimeBackend -string deepSeekHarness
defaults write com.starcat.app.direct.debug DebugDeepSeekHarnessExecutablePath -string \
  "$HOME/Library/Application Support/Starcat/Runtimes/deepseek-harness-0.1.1rc1/venv/lib/python3.12/site-packages/deepseek_harness_runtime/runtime/dsh-jsonrpc-agent-pkg-macos-arm64"
defaults write com.starcat.app.direct.debug DebugDeepSeekHarnessCordisConfigPath -string \
  "$HOME/Library/Application Support/Starcat/Runtimes/deepseek-harness-0.1.1rc1/starcat.cordis.yml"
```

Provider 和模型不再通过 `defaults` 手工写死。启动 `StarcatDirect` 后，在 Agent 工作台按
以下顺序选择：

1. Runtime：`DeepSeek Harness`
2. Provider：Starcat「设置 → AI」中已经通过连接测试的配置
3. Model：该 Provider 下已启用的 Chat 模型
4. Reasoning：目录能明确识别为推理模型时可选；否则保留服务商默认

DeepSeek Harness JSON-RPC carrier 没有 Provider 目录接口。Starcat 会为每个 Run 生成只含
当前 endpoint、模型能力和环境变量引用的临时 `dsh-llm-pi-ai` Cordis 配置，并继续使用
临时 MCP Bridge 调用 Agent definition 允许的 Starcat 只读工具。当前目录只接入已经由
Starcat 连接测试验证的 OpenAI-compatible Provider；需要 AWS/Azure/OAuth 原生鉴权的
Harness catalog route 尚未在 Starcat UI 中单独开放。

基础 Cordis 配置故意不预加载 `dsh-llm-deepseek`。这样选择 OpenAI-compatible 的非
DeepSeek Provider 时，不会因为未配置无关的 `DEEPSEEK_API_KEY` 而在 Runtime 初始化阶段失败。

## 4. Gatekeeper 与签名

官方 wheel 中的 carrier 带 ad-hoc 签名，但不是 Starcat Developer ID 签名，也没有随
Starcat DMG 公证。安装脚本只对 wheel 的三个确定文件移除下载链可能附加的
`com.apple.quarantine`，并用 `codesign --verify --strict` 验证已有签名；不会重签名
第三方 Runtime，也不会修改整个用户缓存目录。

若看到“未打开 `pty.node`”，说明使用了 wheel 自带的默认 Cordis 配置，或误在 App
Store/Sandbox 测试宿主里启用了本地 Bash。重新运行安装脚本，并把
`DebugDeepSeekHarnessCordisConfigPath` 指向脚本生成的 `starcat.cordis.yml`。

## 5. 关闭 POC

```bash
defaults write com.starcat.app.direct.debug DebugExternalAgentRuntimeBackend -string builtinLoop
```

这只切回 Starcat 内置 Loop，不删除外部 Runtime 或 AI Provider 凭据。
