#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=== HarmonyOS: js-bridge-core tests ===${NC}"

DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}"
DEVECO_NODE="${DEVECO_SDK_HOME%/sdk}/tools/node/bin/node"
HVIGOR="${DEVECO_SDK_HOME%/sdk}/tools/hvigor/bin/hvigorw.js"
HM_EXAMPLE="$PROJECT_ROOT/js_bridge_hm/js-bridge-example"

if [ ! -f "$HVIGOR" ]; then
    echo -e "${YELLOW}DevEco SDK not found at $DEVECO_SDK_HOME${NC}"
    echo -e "${YELLOW}HarmonyOS tests require DevEco Studio.${NC}"
    echo -e "Set DEVECO_SDK_HOME or install DevEco Studio to run."
    echo -e "Skipping HarmonyOS tests."
    exit 0
fi

if [ ! -d "$HM_EXAMPLE" ]; then
    echo -e "${RED}HarmonyOS example project not found at $HM_EXAMPLE${NC}"
    exit 1
fi

cd "$HM_EXAMPLE"
DEVECO_SDK_HOME="$DEVECO_SDK_HOME" "$DEVECO_NODE" "$HVIGOR" assembleHap --mode module -p product=default --no-daemon

if [ "${PIPESTATUS[0]}" -eq 0 ]; then
    echo -e "${GREEN}HarmonyOS build PASSED${NC}"
else
    echo -e "${RED}HarmonyOS build FAILED${NC}"
    exit 1
fi
