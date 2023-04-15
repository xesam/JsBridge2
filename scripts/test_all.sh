#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

RESULTS=()
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

run_test() {
    local label="$1"
    local script="$2"
    echo -e "\n${CYAN}━━━ $label ━━━${NC}"
    if "$SCRIPT_DIR/$script"; then
        echo -e "${GREEN}[PASS] $label${NC}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        local rc=$?
        if [ $rc -eq 0 ]; then
            echo -e "${GREEN}[SKIP] $label${NC}"
            SKIP_COUNT=$((SKIP_COUNT + 1))
        else
            echo -e "${RED}[FAIL] $label (exit $rc)${NC}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    fi
}

run_test "Android"              test_android.sh
run_test "iOS"                  test_ios.sh
run_test "Flutter"              test_flutter.sh
run_test "HarmonyOS"            test_hm.sh

echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Results: ${GREEN}$PASS_COUNT passed${NC}  ${RED}$FAIL_COUNT failed${NC}  $SKIP_COUNT skipped"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
