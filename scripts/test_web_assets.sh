#!/usr/bin/env bash
# WebAssets 一致性验证：构建 SDK + 同步四端 + SHA-256 校验（pnpm sync）。
# 退出码约定：0 = PASS，125 = SKIP（无 node/pnpm 环境），其余 = FAIL。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SKIP_RC=125

WEB_ASSETS="$PROJECT_ROOT/web-assets"

if ! command -v node >/dev/null 2>&1; then
    echo -e "${YELLOW}node not found — WebAssets build requires Node.js.${NC}"
    echo -e "Skipping WebAssets tests."
    exit "$SKIP_RC"
fi

if ! command -v pnpm >/dev/null 2>&1; then
    echo -e "${YELLOW}pnpm not found — WebAssets build requires pnpm (npm i -g pnpm).${NC}"
    echo -e "Skipping WebAssets tests."
    exit "$SKIP_RC"
fi

echo -e "${YELLOW}=== WebAssets: pnpm sync (build + sync + check) ===${NC}"

cd "$WEB_ASSETS"
# set -e 下 \`if cmd\` 不再整脚本即退——FAILED 分支可达
if pnpm install && pnpm sync; then
    echo -e "${GREEN}WebAssets sync PASSED${NC}"
else
    echo -e "${RED}WebAssets sync FAILED${NC}"
    exit 1
fi
