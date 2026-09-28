#!/usr/bin/env bash
# 四端 + WebAssets 一键验证。
# 退出码约定：0 = PASS，125 = SKIP（环境缺失，如无 DevEco SDK / pnpm），其余 = FAIL。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

SKIP_RC=125
RESULTS=()
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

run_test() {
    local label="$1"
    local script="$2"
    echo -e "\n${CYAN}━━━ $label ━━━${NC}"
    set +e
    "$SCRIPT_DIR/$script"
    local rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        echo -e "${GREEN}[PASS] $label${NC}"
        PASS_COUNT=$((PASS_COUNT + 1))
    elif [ "$rc" -eq "$SKIP_RC" ]; then
        echo -e "${GREEN}[SKIP] $label${NC}"
        SKIP_COUNT=$((SKIP_COUNT + 1))
    else
        echo -e "${RED}[FAIL] $label (exit $rc)${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

run_test "Android"               test_android.sh
run_test "iOS"                   test_ios.sh
run_test "Flutter"               test_flutter.sh
run_test "HarmonyOS"             test_harmony.sh
run_test "WebAssets"             test_web_assets.sh
run_test "JS Client Conformance" test_js_conformance.sh
run_test "Conformance IDs"       check_conformance_ids.sh
run_test "Origin Vectors"       check_origin_vectors.sh

echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Results: ${GREEN}$PASS_COUNT passed${NC}  ${RED}$FAIL_COUNT failed${NC}  ${GREEN}$SKIP_COUNT skipped${NC}"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
