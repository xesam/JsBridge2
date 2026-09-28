#!/usr/bin/env bash
# JS 客户端 conformance（四端副本逐一运行，C14–C16, C19–C27, C31, C32, C39, C40, C41, C50, C57, C63；另 C59 以代码侧断言并入 C40/C41）。
# 依赖 WebAssets 已通过 pnpm sync 同步到四端（先运行 scripts/test_web_assets.sh）。
# 退出码约定：0 = PASS，125 = SKIP（WebAssets 未同步 / 无 node 环境），其余 = FAIL。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SKIP_RC=125

if ! command -v node >/dev/null 2>&1; then
    echo -e "${YELLOW}node not found — JS conformance requires Node.js.${NC}"
    echo -e "Skipping JS client conformance."
    exit "$SKIP_RC"
fi

CASES=(
    "Android:js_bridge_android/js-bridge-example/src/test/js/bridge-client-conformance.cases.js:js_bridge_android/js-bridge-example/src/main/assets/web/jsbridge-sdk.js"
    "iOS:js_bridge_ios/js-bridge-example/tests/js/bridge-client-conformance.cases.js:js_bridge_ios/js-bridge-example/WebAssets/jsbridge-sdk.js"
    "Flutter:js_bridge_flutter/tests/js/bridge-client-conformance.cases.js:js_bridge_flutter/assets/web/jsbridge-sdk.js"
    "HarmonyOS:js_bridge_harmony/tests/js/bridge-client-conformance.cases.js:js_bridge_harmony/js-bridge-example/entry/src/main/resources/rawfile/web/jsbridge-sdk.js"
)

FAILED=0

for entry in "${CASES[@]}"; do
    label="${entry%%:*}"
    rest="${entry#*:}"
    cases_file="${rest%%:*}"
    sdk_file="${rest#*:}"

    echo -e "\n${YELLOW}=== JS conformance ($label) ===${NC}"

    if [ ! -f "$PROJECT_ROOT/$cases_file" ]; then
        echo -e "${RED}cases file not found: $cases_file${NC}"
        FAILED=1
        continue
    fi
    if [ ! -f "$PROJECT_ROOT/$sdk_file" ]; then
        echo -e "${YELLOW}SDK bundle not found at $sdk_file${NC}"
        echo -e "${YELLOW}WebAssets not synced — run scripts/test_web_assets.sh first (cd web-assets && pnpm sync).${NC}"
        exit "$SKIP_RC"
    fi

    if node "$PROJECT_ROOT/$cases_file"; then
        echo -e "${GREEN}JS conformance ($label) PASSED${NC}"
    else
        echo -e "${RED}JS conformance ($label) FAILED${NC}"
        FAILED=1
    fi
done

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi
