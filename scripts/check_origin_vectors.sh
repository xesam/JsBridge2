#!/usr/bin/env bash
# 校验四端 C54 测试内嵌的 origin 归一化向量集（ORIGIN_VECTORS:BEGIN/END 标记块）
# 与正本 docs/origin-normalizer-vectors.json 完全一致（docs/03 §9 细则 5 的程序化防线）。
#
# 用法：scripts/check_origin_vectors.sh
# 退出码：0 = PASS，125 = SKIP（python3 缺失），其余 = FAIL（向量漂移 / 标记块缺失）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CANONICAL="$REPO_ROOT/docs/origin-normalizer-vectors.json"

TEST_FILES=(
    "$REPO_ROOT/js_bridge_android/js-bridge-core/src/test/java/io/github/xesam/android/bridge/conformance/ConformanceCoreBaselineTest.java"
    "$REPO_ROOT/js_bridge_ios/js-bridge-core-swift/Tests/BridgeCoreTests/ConformanceCoreBaselineTests.swift"
    "$REPO_ROOT/js_bridge_flutter/packages/js_bridge_core/test/conformance_core_baseline_test.dart"
    "$REPO_ROOT/js_bridge_harmony/js-bridge-core/src/test/ConformanceCoreBaseline.test.ets"
)

if ! command -v python3 >/dev/null 2>&1; then
    echo "[SKIP] python3 不可用，无法校验 origin 向量一致性"
    exit 125
fi

python3 - "$CANONICAL" "${TEST_FILES[@]}" <<'PY'
import json
import re
import sys

canonical_path = sys.argv[1]
test_paths = sys.argv[2:]

with open(canonical_path, encoding="utf-8") as f:
    vectors = json.load(f)["vectors"]

# 正本向量 → 归一化形态（与平台内嵌 v() 行同样的引号/空白归一化）
def canon_pair(pair):
    return tuple(re.sub(r"\s+", "", p) for p in pair)

expected = [canon_pair(p) for p in vectors]

# 从标记块提取 v("input", "expected") / v('input', 'expected') 行
block_re = re.compile(r"ORIGIN_VECTORS:BEGIN(.*?)ORIGIN_VECTORS:END", re.S)
vec_re = re.compile(r"\bv\(\s*(['\"])(.*?)\1\s*,\s*(['\"])(.*?)\3\s*\)")

failures = []
for path in test_paths:
    with open(path, encoding="utf-8") as f:
        content = f.read()
    m = block_re.search(content)
    if not m:
        failures.append(f"{path}: 缺少 ORIGIN_VECTORS:BEGIN/END 标记块")
        continue
    found = [(re.sub(r"\s+", "", a), re.sub(r"\s+", "", b))
             for _, a, _, b in vec_re.findall(m.group(1))]
    if found != expected:
        for i, (got, want) in enumerate(zip(found, expected)):
            if got != want:
                failures.append(f"{path}: 向量 #{i + 1} 内嵌 {got} != 正本 {want}")
                break
        else:
            failures.append(f"{path}: 向量数 {len(found)} != 正本 {len(expected)}")

if failures:
    print("[FAIL] origin 归一化向量四端一致性校验未通过：")
    for f in failures:
        print(f"  - {f}")
    print("修改 docs/origin-normalizer-vectors.json 后必须四端 C54 测试同改并重跑本脚本。")
    sys.exit(1)

print(f"[PASS] origin 归一化向量四端一致（{len(expected)} 条向量 × {len(test_paths)} 端）")
PY
