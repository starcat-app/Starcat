# CodebaseMemory 上游 Provenance

本目录的 `codebase` 二进制由 Starcat 从
[DeusData/codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp)
打包进 App。

---

## 许可

MIT License © DeusData

```
MIT License

Copyright (c) 2025 DeusData

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 重命名说明

上游二进制名 `codebase-memory-mcp` → Starcat 内统一改名为 `codebase`：
- 短名，避免和"项目代码库(codebase)"语义混淆
- 与 `starcat` / `starcat-mcp-stdio` 等其他 Starcat 自有二进制风格一致 — 不加文件扩展名

---

## 完整性验证

每次重新生成时用 `scripts/fetch-codebase-binary.sh` 自动执行：

1. 从 GitHub releases 下载 `codebase-memory-mcp-darwin-arm64.tar.gz` + `checksums.txt`
2. `sha256sum -c --strict` 校验
3. 解压 → 重命名 `codebase` → `chmod 0755`
4. 自动写入 `STARCAT-INTEGRATION.md`（版本号 + SHA-256 + 更新时间）

上游 release 同时提供 SLSA Level 3 + Sigstore cosign 签名，可供独立验证：

```bash
# 若本地安装了 cosign CLI
cosign verify-blob \
  --bundle checksums.txt.bundle \
  --certificate-identity-regexp 'https://github.com/DeusData/.*' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  checksums.txt
```

cosign 验证**非 Starcat 构建流程必须步骤**，SHA-256 校验已足够。

---

## 已知约束

- App 内调用走 `Process` spawn，**只 spawn container 内 `.bin/codebase` 副本**（沙盒限制 + App Store 审核要求"不下载可执行文件"）
- 不修改上游二进制，纯打包
- `CBM_CACHE_DIR` 环境变量重定向到 container 内 `/Library/Caches/`，不走 `~/.cache`
- **禁用** `update` 子命令（不调用、不暴露、不过桥）—— 版本升级跟随 Starcat 主应用通过 App Store 更新
- **禁止** 通过网络下载二进制更新自身

---

## 上游 App Store 审核说明（供 Review Notes 复用）

> "应用内包含一个纯本地运行的、用于构建代码结构知识图谱的静态 C 二进制组件。
> 该组件 100% 在本地沙盒内运行，不依赖任何外部 LLM，不向外传输任何代码数据。"

---

*本文件随 `scripts/fetch-codebase-binary.sh` 自动拷贝到 Resources/Codebase/，手动编辑请留注释。*
