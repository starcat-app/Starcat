#!/bin/bash
#
# 为 Starcat Direct 安装固定版本的 DeepSeek Harness 外部 Runtime。
#
# Runtime 安装在用户的 Application Support 中，不复制进 Starcat.app 或 DMG。
# 脚本同时安装 Starcat 专用的无 Shell Cordis 配置，避免未授权的 bash/PTY 工具
# 以及首次运行时由 pty.node 触发的 Gatekeeper 拦截。

set -euo pipefail

readonly runtime_version="0.1.1rc1"
readonly script_dir="$(cd "$(dirname "$0")" && pwd)"
readonly source_config="${script_dir}/../resources/deepseek-harness/starcat.cordis.yml"
readonly install_root="${STARCAT_DEEPSEEK_RUNTIME_ROOT:-${HOME}/Library/Application Support/Starcat/Runtimes/deepseek-harness-${runtime_version}}"
readonly venv_dir="${install_root}/venv"
readonly installed_config="${install_root}/starcat.cordis.yml"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "error: DeepSeek Harness ${runtime_version} only supports macOS arm64." >&2
  exit 1
fi

if [[ ! -f "${source_config}" ]]; then
  echo "error: Starcat Cordis config not found: ${source_config}" >&2
  exit 1
fi

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
  "deepseek-harness-runtime-bin==${runtime_version}"

runtime_path="$("${venv_dir}/bin/python" -c 'from deepseek_harness_runtime import bundled_runtime_path; print(bundled_runtime_path())')"
install -m 0644 "${source_config}" "${installed_config}"

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

echo
echo "DeepSeek Harness ${runtime_version} installed for Starcat Direct."
echo "Runtime executable: ${runtime_path}"
echo "Cordis config:      ${installed_config}"
echo
echo "Configure Starcat Direct Debug:"
echo "defaults write com.starcat.app.direct.debug DebugExternalAgentRuntimeBackend -string deepSeekHarness"
printf 'defaults write com.starcat.app.direct.debug DebugDeepSeekHarnessExecutablePath -string %q\n' "${runtime_path}"
printf 'defaults write com.starcat.app.direct.debug DebugDeepSeekHarnessCordisConfigPath -string %q\n' "${installed_config}"
echo "Provider and model: select a verified Starcat AI Provider in Agent Workspace."
