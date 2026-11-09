#!/bin/bash
#
# 为 Starcat Direct 安装固定版本的 DeepSeek Harness 外部 Runtime。
#
# Runtime 安装在用户的 Application Support 中，不复制进 Starcat.app 或 DMG。
# 脚本同时安装 Starcat 专用的 sdk-minimal 无 Shell Cordis patch，避免未授权的 bash/PTY 工具
# 以及首次运行时由 pty.node 触发的 Gatekeeper 拦截。

set -euo pipefail

readonly runtime_version="0.2.1rc2"
readonly wheel_url="https://files.pythonhosted.org/packages/10/99/723905c63929056e05494e8a659bc8eb9adf671ee6712fb4316930b97ac8/deepseek_harness_runtime_bin-0.2.1rc2-py3-none-macosx_14_0_arm64.whl"
readonly wheel_sha256="96a173abd14141d5328a78791b69729cbfe22fa3e9daf1dc2600d0daa4d6bb28"
readonly script_dir="$(cd "$(dirname "$0")" && pwd)"
readonly source_config="${script_dir}/../resources/deepseek-harness/starcat.cordis.yml"
readonly install_root="${STARCAT_DEEPSEEK_RUNTIME_ROOT:-${HOME}/Library/Application Support/Starcat/Runtimes/deepseek-harness-${runtime_version}}"
readonly venv_dir="${install_root}/venv"
readonly installed_config="${install_root}/starcat.cordis.yml"
readonly bundle_id="${STARCAT_BUNDLE_ID:-com.starcat.app.direct}"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "error: DeepSeek Harness ${runtime_version} only supports macOS arm64." >&2
  exit 1
fi

case "${bundle_id}" in
  com.starcat.app.direct | com.starcat.app.direct.debug) ;;
  *)
    echo "error: Unsupported Starcat bundle ID: ${bundle_id}" >&2
    exit 1
    ;;
esac

python_command="${STARCAT_PYTHON:-}"
if [[ -z "${python_command}" ]]; then
  for candidate in python3.12 python3.11 python3.10 python3; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      python_command="$(command -v "${candidate}")"
      break
    fi
  done
fi
if [[ -z "${python_command}" || ! -x "${python_command}" ]]; then
  echo "error: Python 3.10 or newer is required." >&2
  exit 1
fi

python_version="$("${python_command}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
python_major="${python_version%%.*}"
python_minor="${python_version##*.}"
if (( python_major != 3 || python_minor < 10 )); then
  echo "error: Python 3.10 or newer is required; found ${python_version}." >&2
  exit 1
fi

mkdir -p "${install_root}"
if [[ ! -x "${venv_dir}/bin/python" ]]; then
  "${python_command}" -m venv "${venv_dir}"
fi
"${venv_dir}/bin/python" -m pip install \
  --disable-pip-version-check \
  --only-binary=:all: \
  --pre \
  --upgrade \
  "deepseek-harness-runtime-bin @ ${wheel_url}#sha256=${wheel_sha256}"

runtime_path="$("${venv_dir}/bin/python" -c 'from deepseek_harness_runtime import bundled_runtime_path; print(bundled_runtime_path())')"
if [[ -f "${source_config}" ]]; then
  install -m 0644 "${source_config}" "${installed_config}"
else
  # Release 用户通常只下载这一份脚本，因此必须自带与仓库资源一致的安全配置。
  # 这里故意不启用 bash/subprocess，所有业务工具仍由 Starcat 的临时 MCP Bridge 授权。
  cat > "${installed_config}" <<'CORDIS_CONFIG'
# Starcat Direct: sdk-minimal 的无本地工具补丁
- id: llm-deepseek
  disabled: true
- id: subprocess
  disabled: true
- id: pty
  disabled: true
- id: terminal-bash
  disabled: true
- id: terminal-pwsh
  disabled: true
- id: persistent-bash
  disabled: true
- id: persistent-pwsh
  disabled: true
- id: tool-fs
  disabled: true
- id: tool-working-directory
  disabled: true
- id: system-prompt
  config:
    includeHarnessIdentity: false
    includeRuntimeContext: false
    personaPrefix: You are a helpful assistant using only the tools supplied by Starcat.
CORDIS_CONFIG
  chmod 0644 "${installed_config}"
fi

# PyPI wheel 里的 Mach-O 已带 ad-hoc 签名。这里只移除下载链可能附加的 quarantine，
# 且严格限定到官方 wheel 的三个 carrier 文件，不改写用户其它缓存或程序。
for executable in "${runtime_path}" "${runtime_path}-rg" "${runtime_path}-spawn-helper"; do
  chmod 0755 "${executable}"
  xattr -d com.apple.quarantine "${executable}" 2>/dev/null || true
  if ! codesign --verify --strict "${executable}" 2>/dev/null; then
    echo "error: Runtime code signature is invalid: ${executable}" >&2
    exit 1
  fi
done

# PyPI 版本遵循 PEP 440，CLI 遵循 SemVer；两者不能直接逐字比较。
reported_version="$("${runtime_path}" --version)"
if [[ "${reported_version}" != "0.2.1-rc.2" ]]; then
  echo "error: Unexpected DeepSeek Harness version: ${reported_version}" >&2
  exit 1
fi

# 正式版和 Debug 版共用产品配置键，只通过 bundle ID 区分 UserDefaults domain。
# 这样从 DMG 安装的 Starcat Direct 无需再手工复制脚本输出中的路径。
defaults write "${bundle_id}" AgentRuntimeDeepSeekHarnessExecutablePath -string "${runtime_path}"
defaults write "${bundle_id}" AgentRuntimeDeepSeekHarnessCordisConfigPath -string "${installed_config}"

echo
echo "DeepSeek Harness ${runtime_version} installed for Starcat Direct."
echo "Runtime executable: ${runtime_path}"
echo "Cordis config:      ${installed_config}"
echo "Starcat bundle ID:  ${bundle_id}"
echo
echo "Starcat Direct has been configured. Restart the app before using DeepSeek Harness."
echo "Provider and model: select a verified Starcat AI Provider in Agent Workspace."
