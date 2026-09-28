#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=== Android: js-bridge-core tests ===${NC}"
cd "$PROJECT_ROOT/js_bridge_android"

if [ ! -f gradlew ]; then
    echo -e "${RED}gradlew not found — is this an Android project?${NC}"
    exit 1
fi

chmod +x gradlew 2>/dev/null || true
# set -e 下 `if cmd` 不再整脚本即退——FAILED 分支可达
if ./gradlew :js-bridge-core:test; then
    echo -e "${GREEN}Android tests PASSED${NC}"
else
    echo -e "${RED}Android tests FAILED${NC}"
    exit 1
fi
