#!/usr/bin/env bash
# 验收用例编号一致性校验。
#
# 校验五件事：
#   1. 各端实现的用例编号 ⊆ docs/09-conformance.md §3 登记的编号（无未登记编号）
#   2. 各端之间的编号集合一致（无单端漂移）
#   3. 文档 §3 登记的编号 ⊆ 各端实际实现编号的并集（已登记的编号均有实现，可由
#      INSTRUMENTED_ONLY 例外豁免；不解析 §4 覆盖表）
#   4. 文档 §6.2 自称的「当前最大编号」与 §3 登记表实际最大一致（旁陈述数字的防线）
#   5. 四端 JS client cases 副本之间编号集合一致（deploy.mjs 的归一化互比为内容
#      正本防线，此处为脚本级防线，覆盖 pnpm 缺失 SKIP 时内容防线缺位的窗口）
#
# 退出码：0 = PASS，1 = FAIL。
#
# 合法例外（不计入"无实现"警告）：属 instrumented 层的用例——需真机/Robolectric
# 环境，不在四端纯 JVM 基线内。新增例外必须有 docs/09-conformance.md §3 登记表
# 覆盖层列（及所属分节引言）的登记。
# C47 已实现于 Android host 层（PendingChannelRequestsTest），可被 android_ids 提取，
# 故无需列入例外。C59（JS MessagePort 采纳校验投递来源）同理：代码侧断言已并入
# JS conformance cases 的 C40/C41 内联断言，可被 jsclient_ids 提取，无需例外。
# 此处保留 C42 与 C58（iOS 主 frame 隔离）：属宿主 instrumented 层（需 Robolectric/
# 真机 WebView 与 WKWebView 环境，四端纯 JVM 基线与 swift 基线无法构造），
# 登记见 docs/09-conformance.md §3「Transport 信道建立」与「建链安全边界用例」
# 两节的覆盖层列及引言。
INSTRUMENTED_ONLY="C42 C58"
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

DOC="docs/09-conformance.md"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ ! -f "$DOC" ]; then
    echo -e "${RED}$DOC not found${NC}"
    exit 1
fi

# ── 登记集合：文档 §3 表格中的用例编号（表格行以 | Cxx 开头）──
registered() {
    grep -oE '^\| C[0-9]{2}[a-z]?' "$DOC" | sed 's/^| //' | sort -u
}

# 归一化：C04B -> C04b（后缀统一小写；BSD sed 无 \L，用显式映射）
normalize() {
    sed -E -e 's/^(C[0-9]{2})A$/\1a/' -e 's/^(C[0-9]{2})B$/\1b/' \
           -e 's/^(C[0-9]{2})C$/\1c/' -e 's/^(C[0-9]{2})D$/\1d/' | sort -u
}

# ── Native core 实现的编号，按文件名模式提取测试标识 ──
# Android:  public void c45_policyChain_... / C04b_...
android_ids() {
    grep -rhoE '\b[Cc][0-9]{2}[A-Za-z]?_[A-Za-z0-9_]+' \
        js_bridge_android/js-bridge-core/src/test/ 2>/dev/null \
        | sed 's/_.*//' | tr 'a-z' 'A-Z' | normalize
}
# iOS:      func testC45_policyChain_...
ios_ids() {
    grep -rhoE 'func test(C[0-9]{2}[a-z]?)_' \
        js_bridge_ios/js-bridge-core-swift/Tests/ 2>/dev/null \
        | grep -oE 'C[0-9]{2}[a-z]?' | normalize
}
# Flutter:  test('C45_policyChain_...')
flutter_ids() {
    grep -rhoE "'(C[0-9]{2}[a-z]?)_[A-Za-z0-9_]+'" \
        js_bridge_flutter/packages/js_bridge_core/test/ 2>/dev/null \
        | grep -oE 'C[0-9]{2}[a-z]?' | normalize
}
# HarmonyOS: it('C45_policyChain_...', 0, ...)
harmony_ids() {
    grep -rhoE "'(C[0-9]{2}[a-z]?)_[A-Za-z0-9_]+'" \
        js_bridge_harmony/js-bridge-core/src/test/ 2>/dev/null \
        | grep -oE 'C[0-9]{2}[a-z]?' | normalize
}

# ── JS client 用例编号（共享 cases 文件，四端各一份副本）──
# 四份副本编号取代数并集参与校验 1/3；校验 5 对各副本互比防其单端漂移。
JS_CASES=(
    "js_bridge_android/js-bridge-example/src/test/js/bridge-client-conformance.cases.js"
    "js_bridge_ios/js-bridge-example/tests/js/bridge-client-conformance.cases.js"
    "js_bridge_flutter/tests/js/bridge-client-conformance.cases.js"
    "js_bridge_harmony/tests/js/bridge-client-conformance.cases.js"
)

js_copy_ids() {
    # 注意：token 级提取（注释/登记说明中的编号同样计入），与实现无关；
    # 副本内容一致性由 deploy.mjs 归一化互比保证。
    grep -rhoE "\bC[0-9]{2}[a-z]?\b" "$1" 2>/dev/null | normalize
}

jsclient_ids() {
    for f in "${JS_CASES[@]}"; do
        js_copy_ids "$f"
    done | sort -u
}

FAIL=0

REG="$(registered)"
echo -e "${YELLOW}=== 已登记用例 ===${NC}"
echo "  $(echo "$REG" | tr '\n' ' ')"
echo

echo -e "${YELLOW}=== 各端实现编号 ===${NC}"
A="$(android_ids)"; I="$(ios_ids)"; F="$(flutter_ids)"; H="$(harmony_ids)"; J="$(jsclient_ids)"
echo "  Android  : $(echo "$A" | tr '\n' ' ')"
echo "  iOS      : $(echo "$I" | tr '\n' ' ')"
echo "  Flutter  : $(echo "$F" | tr '\n' ' ')"
echo "  HarmonyOS: $(echo "$H" | tr '\n' ' ')"
echo "  JS client: $(echo "$J" | tr '\n' ' ')"
echo

echo -e "${YELLOW}=== 校验 1：无未登记编号（实现 ⊆ 登记）===${NC}"
for pair in "Android:$A" "iOS:$I" "Flutter:$F" "HarmonyOS:$H" "JS client:$J"; do
    label="${pair%%:*}"; ids="${pair#*:}"
    extra="$(comm -23 <(echo "$ids") <(echo "$REG") | tr '\n' ' ' | sed 's/ *$//')"
    if [ -n "$extra" ]; then
        echo -e "  ${RED}✗ $label 使用未登记编号: $extra${NC}"
        FAIL=1
    else
        echo -e "  ${GREEN}✓ $label${NC}"
    fi
done
echo

echo -e "${YELLOW}=== 校验 2：四端 Native core 编号一致 ===${NC}"
# 已在 docs/09-conformance.md §4 登记为已知缺口的编号，差异仅提示不算失败。
# C47（bind 前通道请求暂存）为 Android 专有：iOS 走 resident 通道（无 pull 请求窗口），
# Flutter/HarmonyOS 走宿主注入函数（无 requestBridgeChannel 入口），三端不存在等价竞态。
KNOWN_GAPS="C47"
check_pair() {
    local label="$1" a="$2" b="$3"
    local id raw real=""
    raw="$(comm -3 <(echo "$a") <(echo "$b") | tr -d '\t' | grep -v '^$' | sort -u)"
    if [ -z "$raw" ]; then
        echo -e "  ${GREEN}✓ $label${NC}"
        return
    fi
    for id in $raw; do
        case " $KNOWN_GAPS " in
            *" $id "*) echo -e "    ${YELLOW}∘ $id 属已登记缺口（docs/09-conformance.md §4），跳过${NC}" ;;
            *) real="$real $id" ;;
        esac
    done
    real="${real# }"
    if [ -n "$real" ]; then
        echo -e "  ${RED}✗ $label: $real${NC}"
        FAIL=1
    else
        echo -e "  ${GREEN}✓ ${label}（差异仅为已登记缺口）${NC}"
    fi
}
check_pair "Android vs iOS" "$A" "$I"
check_pair "Android vs Flutter" "$A" "$F"
check_pair "Android vs HarmonyOS" "$A" "$H"
echo

echo -e "${YELLOW}=== 校验 3：登记编号均已实现（登记 ⊆ 并集）===${NC}"
UNION="$(printf '%s\n%s\n%s\n%s\n%s\n' "$A" "$I" "$F" "$H" "$J" | grep -v '^$' | sort -u)"
MISSING="$(comm -23 <(echo "$REG") <(echo "$UNION") | grep -v '^$')"
REAL_MISSING=""
for id in $MISSING; do
    case " $INSTRUMENTED_ONLY " in
        *" $id "*) echo -e "    ${GREEN}∘ $id 属 instrumented 层，不计入${NC}" ;;
        *) REAL_MISSING="$REAL_MISSING $id" ;;
    esac
done
REAL_MISSING="${REAL_MISSING# }"
if [ -n "$REAL_MISSING" ]; then
    echo -e "  ${RED}✗ 已登记但无任何实现: $REAL_MISSING${NC}"
    FAIL=1
else
    echo -e "  ${GREEN}✓ 所有登记编号（除 instrumented 层）均已实现${NC}"
fi
echo

echo -e "${YELLOW}=== 校验 4：§6.2 自称最大编号与登记表一致 ===${NC}"
self_max_token="$(grep -oE '当前最大为 \*\*C[0-9]{2}[a-z]?\*\*' "$DOC" | grep -oE 'C[0-9]{2}[a-z]?' | head -1)"
if [ -z "$self_max_token" ]; then
    echo -e "  ${RED}✗ docs/09 §6.2 未按「当前最大为 **Cxx**」格式声明最大编号${NC}"
    FAIL=1
else
    self_max_num="$(echo "$self_max_token" | grep -oE '[0-9]{2}')"
    reg_max_num="$(echo "$REG" | grep -oE 'C[0-9]{2}' | grep -oE '[0-9]{2}' | sort -n | tail -1)"
    if [ "$self_max_num" != "$reg_max_num" ]; then
        echo -e "  ${RED}✗ §6.2 自称最大 $self_max_token，登记表实际最大 C$reg_max_num${NC}"
        FAIL=1
    else
        echo -e "  ${GREEN}✓ 自称最大 $self_max_token = 登记表最大 C$reg_max_num${NC}"
    fi
fi
echo

echo -e "${YELLOW}=== 校验 5：四端 JS client 副本编号一致 ===${NC}"
# deploy.mjs 的归一化互比（pnpm check）是副本内容级正本防线；此处为脚本级防线，
# 覆盖 pnpm 缺失 SKIP 时内容防线缺位的窗口（AGENTS.md 退出码约定）。
JS_COPY_MISSING=0
for f in "${JS_CASES[@]}"; do
    if [ ! -f "$f" ]; then
        echo -e "  ${RED}✗ JS client 副本缺失: $f${NC}"
        JS_COPY_MISSING=1
        FAIL=1
    fi
done
if [ "$JS_COPY_MISSING" -eq 0 ]; then
    js_first="$(js_copy_ids "${JS_CASES[0]}")"
    js_drift_failed=0
    for f in "${JS_CASES[@]:1}"; do
        js_ids="$(js_copy_ids "$f")"
        js_drift="$(comm -3 <(echo "$js_first") <(echo "$js_ids") | tr -d '\t' | grep -v '^$' | tr '\n' ' ')"
        if [ -n "${js_drift// }" ]; then
            echo -e "  ${RED}✗ $f 编号相对正本副本漂移: $js_drift${NC}"
            js_drift_failed=1
            FAIL=1
        fi
    done
    if [ "$js_drift_failed" -eq 0 ]; then
        echo -e "  ${GREEN}✓ 四副本编号一致${NC}"
    fi
fi
echo

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}编号一致性校验 PASSED${NC}"
    exit 0
else
    echo -e "${RED}编号一致性校验 FAILED${NC}"
    exit 1
fi
