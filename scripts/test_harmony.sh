#!/usr/bin/env bash
# 退出码约定：0 = PASS，125 = SKIP（无 DevEco SDK），其余 = FAIL。
# 设备在线时执行完整真机测试（hypium 全量基线）；无设备时退化为 assembleHap 编译验证。
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
HDC="${DEVECO_SDK_HOME}/default/openharmony/toolchains/hdc"
HARMONY_EXAMPLE="$PROJECT_ROOT/js_bridge_harmony/js-bridge-example"
HARMONY_CORE="$PROJECT_ROOT/js_bridge_harmony/js-bridge-core"

if [ ! -f "$HVIGOR" ]; then
    echo -e "${YELLOW}DevEco SDK not found at $DEVECO_SDK_HOME${NC}"
    echo -e "${YELLOW}HarmonyOS tests require DevEco Studio.${NC}"
    echo -e "Set DEVECO_SDK_HOME or install DevEco Studio to run."
    echo -e "Skipping HarmonyOS tests."
    exit 125
fi

export DEVECO_SDK_HOME

if [ ! -d "$HARMONY_EXAMPLE" ]; then
    echo -e "${RED}HarmonyOS example project not found at $HARMONY_EXAMPLE${NC}"
    exit 1
fi

# ── 步骤 1：同步核心测试到 ohosTest（HAR src/test 不参与打包，须以副本接入消费方 runner；
#    import 重写为 HAR 包名；与四端 bridge-client-conformance.cases.js 同款单源多副本模式）──
CORE_TEST_DIR="$HARMONY_EXAMPLE/entry/src/ohosTest/ets/test/core"
mkdir -p "$CORE_TEST_DIR"
for f in ConformanceCoreBaseline SessionServiceTest PolicyGroupsTest; do
    sed "s|from '../../Index'|from '@xesam/js_bridge_core'|" \
        "$HARMONY_CORE/src/test/$f.test.ets" > "$CORE_TEST_DIR/$f.test.ets"
done
echo -e "${GREEN}core test suites synced to entry/src/ohosTest/ets/test/core/${NC}"

# ── 步骤 2：构建（主 HAP + ohosTest HAP）──
cd "$HARMONY_EXAMPLE"
HVIGOR_CMD=("$DEVECO_NODE" "$HVIGOR" --no-daemon)

"${HVIGOR_CMD[@]}" assembleHap --mode module -p product=default
"${HVIGOR_CMD[@]}" assembleHap --mode module -p module=entry@ohosTest -p product=default

if [ ! -f "$HDC" ]; then
    echo -e "${YELLOW}hdc not found; build-only validation passed.${NC}"
    exit 0
fi

# ── 步骤 3：设备在线则执行真机 hypium 测试 ──
if [ -z "$("$HDC" list targets | grep -v '^\[Empty\]' | grep -v '^$')" ]; then
    echo -e "${YELLOW}no HarmonyOS device attached; build-only validation passed.${NC}"
    exit 0
fi

"$HDC" install -r "$HARMONY_EXAMPLE/entry/build/default/outputs/default/entry-default-signed.hap"
"$HDC" install -r "$HARMONY_EXAMPLE/entry/build/default/outputs/ohosTest/entry-ohosTest-signed.hap"

TEST_LOG="$(mktemp -t hos_test.XXXXXX.log)"
trap 'rm -f "$TEST_LOG"' EXIT
"$HDC" shell aa test -b io.github.xesam.example.bridge -m entry_test \
    -s unittest OpenHarmonyTestRunner -s timeout 30000 > "$TEST_LOG" 2>&1 || true

echo -e "---- test output (failures, if any) ----"
grep "stream=" "$TEST_LOG" | grep -v "stream=$" || true
echo -e "-----------------------------------------"

RESULT="$(grep -o 'Tests run: [0-9]*, Failure: [0-9]*, Error: [0-9]*, Pass: [0-9]*' "$TEST_LOG" | tail -1)"
echo -e "${YELLOW}result: ${RESULT}${NC}"

if echo "$RESULT" | grep -q 'Failure: 0, Error: 0'; then
    echo -e "${GREEN}HarmonyOS device tests PASSED${NC}"
    exit 0
else
    echo -e "${RED}HarmonyOS device tests FAILED${NC}"
    exit 1
fi
