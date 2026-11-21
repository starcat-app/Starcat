#!/usr/bin/env bash
# 只替换 Go 测试进程的入口，保持配套仓库只读。正式客户端与 App 的真实 HTTP listener 在隔离样例上通信。
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$(pwd -P)
cli=$(cd supports/starcat-cli && pwd -P)
mkdir -p build
fixture="$root/build/tag-graph-cli-fixture"
overlay=$(mktemp)
trap 'rm -f "$overlay"' EXIT
python3 - "$cli/cmd/starcat/main.go" "$root/scripts/tests/tag-graph-cli-fixture.go" > "$overlay" <<'PY'
import json, sys
print(json.dumps({"Replace": {sys.argv[1]: sys.argv[2]}}))
PY
(cd "$cli" && go build -overlay="$overlay" -o "$fixture" ./cmd/starcat)
make test TEST_ARGS='-only-testing:StarcatTests/TagGraphTransportTests'
