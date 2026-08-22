# DeepSeek Harness Runtime 配置

DeepSeek Harness 只用于 **Starcat Direct Debug / macOS arm64**。Runtime 由用户安装在
`~/Library/Application Support/Starcat/Runtimes/`，不会复制进 `Starcat.app` 或 DMG。

## 1. 前置条件

- Apple Silicon Mac。
- Python 3.10 或更高版本；推荐 Python 3.12。
- 已在 Starcat「设置 → AI」中添加并启用 DeepSeek Provider，API Key 保存在 Keychain。

API Key 不写入 `defaults`、Cordis YAML 或仓库。Starcat 启动 Runtime 时优先读取显式
`DEEPSEEK_API_KEY` 环境变量；Finder 正常启动时复用已启用的 DeepSeek Provider 凭据。

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
defaults write com.starcat.app.direct.debug DebugDeepSeekHarnessProvider -string deepseek-official
defaults write com.starcat.app.direct.debug DebugDeepSeekHarnessModel -string deepseek-v4-flash
```

可选模型：

- `deepseek-v4-flash`
- `deepseek-v4-pro`

启动 `StarcatDirect` 后，Agent 工作台输入框会显示 DeepSeek 自己的模型菜单，不再显示
Starcat 内置 Loop 的 Provider / Model 选择器。

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

这只切回 Starcat 内置 Loop，不删除外部 Runtime 或 DeepSeek Provider 凭据。
