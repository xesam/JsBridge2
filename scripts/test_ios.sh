#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=== iOS: js-bridge-core-swift tests ===${NC}"

PKG_PATH="$PROJECT_ROOT/js_bridge_ios/js-bridge-core-swift"
if [ ! -d "$PKG_PATH" ]; then
    echo -e "${RED}iOS Swift package not found at $PKG_PATH${NC}"
    exit 1
fi

swift test --package-path "$PKG_PATH"

if [ "${PIPESTATUS[0]}" -eq 0 ]; then
    echo -e "${GREEN}iOS tests PASSED${NC}"
else
    echo -e "${RED}iOS tests FAILED${NC}"
    exit 1
fi
