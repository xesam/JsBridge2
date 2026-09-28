#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=== Flutter: js_bridge_core tests ===${NC}"

CORE_PATH="$PROJECT_ROOT/js_bridge_flutter/packages/js_bridge_core"
if [ ! -d "$CORE_PATH" ]; then
    echo -e "${RED}Flutter core package not found at $CORE_PATH${NC}"
    exit 1
fi

cd "$CORE_PATH"
# set -e 下 `if cmd` 不再整脚本即退——FAILED 分支可达
if flutter test; then
    echo -e "${GREEN}Flutter core tests PASSED${NC}"
else
    echo -e "${RED}Flutter core tests FAILED${NC}"
    exit 1
fi

echo -e "${YELLOW}=== Flutter: host app analyze ===${NC}"
cd "$PROJECT_ROOT/js_bridge_flutter"
if flutter analyze; then
    echo -e "${GREEN}Flutter analyze PASSED${NC}"
else
    echo -e "${RED}Flutter analyze FAILED${NC}"
    exit 1
fi
