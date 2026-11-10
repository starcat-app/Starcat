#!/usr/bin/env bash
#
# 使用真实官方归档执行 Direct 安装器。仅生成临时诊断可执行文件，不构建分发产物。
# Swift 源复用生产实现；运行目录与 probe daemon 均隔离，退出后回收。
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"
source "${script_dir}/lib/debug-build-environment.sh"
starcat_select_stable_xcode
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "error: these real-archive smoke fixtures are verified only on macOS arm64" >&2
  exit 1
fi
if [[ -z "${STARCAT_RUNTIME_FIXTURE_ROOT:-}" ]]; then
  echo "error: set STARCAT_RUNTIME_FIXTURE_ROOT to the verified archive directory" >&2
  exit 1
fi
work_dir="$(mktemp -d /tmp/starcat-runtime-smoke.XXXXXX)"
trap 'rm -rf "${work_dir}"' EXIT
"${DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" -parse-as-library \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$(uname -m)-apple-macosx15.0" \
  "${project_root}/Starcat/Core/Distribution/DistributionChannel.swift" \
  "${project_root}/Starcat/Features/Agents/ExternalRuntime/DeepSeekHarnessRuntime.swift" \
  "${project_root}/Starcat/Features/Settings/RuntimeDownloadInstaller.swift" \
  "${script_dir}/tests/RuntimeDownloadSmoke.swift" \
  -o "${work_dir}/RuntimeDownloadSmoke"
"${work_dir}/RuntimeDownloadSmoke" "${STARCAT_RUNTIME_FIXTURE_ROOT}"
