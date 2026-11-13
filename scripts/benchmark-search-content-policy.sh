#!/usr/bin/env bash
#
# 独立测量 Search Center 离线策略；使用稳定工具链和临时产物，
# 不占用 App Store、Direct 或单测的 DerivedData，也不读取用户搜索数据。

set -euo pipefail

benchmark_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$benchmark_root/scripts/lib/debug-build-environment.sh"
starcat_select_stable_xcode

benchmark_dir="$(mktemp -d "${TMPDIR:-/tmp}/starcat-search-content.XXXXXX")"
trap 'rm -rf "$benchmark_dir"' EXIT
benchmark_sdk="$(xcrun --sdk macosx --show-sdk-path)"
benchmark_arch="$(uname -m)"

echo "Search content benchmark: $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.model)"
xcrun --sdk macosx swiftc \
  -O -whole-module-optimization -swift-version 6 \
  -target "${benchmark_arch}-apple-macos15.0" -sdk "$benchmark_sdk" \
  "$benchmark_root/Starcat/Features/Search/SearchContentPolicy.swift" \
  "$benchmark_root/scripts/benchmarks/SearchContentPolicyBenchmark.swift" \
  -o "$benchmark_dir/search-content-policy"
"$benchmark_dir/search-content-policy" "$benchmark_root/Starcat/Resources/SearchContentRules.json"
