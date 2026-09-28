#!/bin/bash
# JsBridge2 项目清理脚本
# 清理所有构建产物、缓存和临时文件

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "🧹 开始清理 JsBridge2 项目..."
echo ""

# 统计清理前大小
echo "📊 清理前磁盘占用："
du -sh .codegraph js_bridge_ios/js-bridge-core-swift/.build js_bridge_android/.gradle 2>/dev/null || true
echo ""

# 1. 清理 CodeGraph 索引缓存 (~11M)
if [ -d ".codegraph" ]; then
  echo "🗑️  清理 CodeGraph 索引缓存..."
  rm -rf .codegraph
  echo "   ✓ .codegraph/ 已删除"
fi

# 2. 清理 iOS Swift 构建缓存 (~295M)
if [ -d "js_bridge_ios/js-bridge-core-swift/.build" ]; then
  echo "🗑️  清理 iOS Swift 构建缓存..."
  rm -rf js_bridge_ios/js-bridge-core-swift/.build
  echo "   ✓ js_bridge_ios/js-bridge-core-swift/.build/ 已删除"
fi

# 3. 清理 Android Gradle 缓存 (~2.4M)
if [ -d "js_bridge_android/.gradle" ]; then
  echo "🗑️  清理 Android Gradle 缓存..."
  rm -rf js_bridge_android/.gradle
  echo "   ✓ js_bridge_android/.gradle/ 已删除"
fi

# 4. 清理各平台 build 目录
echo "🗑️  清理各平台 build 目录..."
CLEANED_BUILDS=0

# Android
for dir in js_bridge_android/js-bridge-core/build js_bridge_android/js-bridge-example/build; do
  if [ -d "$dir" ]; then
    rm -rf "$dir"
    echo "   ✓ $dir"
    CLEANED_BUILDS=$((CLEANED_BUILDS + 1))
  fi
done

# Flutter
for dir in js_bridge_flutter/build js_bridge_flutter/packages/js_bridge_core/build; do
  if [ -d "$dir" ]; then
    rm -rf "$dir"
    echo "   ✓ $dir"
    CLEANED_BUILDS=$((CLEANED_BUILDS + 1))
  fi
done

# HarmonyOS
for dir in js_bridge_harmony/js-bridge-core/build js_bridge_harmony/js-bridge-example/entry/build; do
  if [ -d "$dir" ]; then
    rm -rf "$dir"
    echo "   ✓ $dir"
    CLEANED_BUILDS=$((CLEANED_BUILDS + 1))
  fi
done

if [ $CLEANED_BUILDS -eq 0 ]; then
  echo "   ℹ️  没有找到 build 目录"
fi

# 5. 清理 HarmonyOS .hvigor 缓存
echo "🗑️  清理 HarmonyOS .hvigor 缓存..."
CLEANED_HVIGOR=0
for dir in js_bridge_harmony/js-bridge-core/.hvigor js_bridge_harmony/js-bridge-example/.hvigor; do
  if [ -d "$dir" ]; then
    rm -rf "$dir"
    echo "   ✓ $dir"
    CLEANED_HVIGOR=$((CLEANED_HVIGOR + 1))
  fi
done

if [ $CLEANED_HVIGOR -eq 0 ]; then
  echo "   ℹ️  没有找到 .hvigor 目录"
fi

# 6. 清理日志文件
echo "🗑️  清理日志文件..."
find . -name "*.log" -type f \( -path "*/.codegraph/*" -o -path "*/build/*" \) -delete 2>/dev/null || true
echo "   ✓ 日志文件已清理"

# 7. 清理 macOS 系统文件
echo "🗑️  清理 .DS_Store 文件..."
find . -name ".DS_Store" -type f -delete 2>/dev/null || true
echo "   ✓ .DS_Store 文件已清理"

echo ""
echo "✅ 清理完成！"
echo ""
echo "💡 提示："
echo "   • 构建缓存已清理，下次构建会稍慢"
echo "   • CodeGraph 索引会在下次使用时自动重建"
echo "   • 如需重建 WebAssets，运行：cd web-assets && pnpm sync"
