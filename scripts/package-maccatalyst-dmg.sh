#!/bin/bash
set -euo pipefail

echo "📦 打包 Mac DMG（Mac Catalyst）..."

# 配置变量（可通过环境变量覆盖）
SCHEME="${SCHEME:-AudiobookPlayer}"
WORKSPACE="${WORKSPACE:-AudiobookPlayer.xcworkspace}"
CONFIG="${CONFIG:-Release}"
APP_NAME="${APP_NAME:-AudiobookPlayer}"
BUILD_ROOT="${BUILD_ROOT:-$PWD/build/maccatalyst}"
DERIVED="$BUILD_ROOT/DerivedData"
STAGE="$BUILD_ROOT/stage"
OUT_DMG="${OUT_DMG:-$PWD/${APP_NAME}-macOS.dmg}"
CLEAN="${CLEAN:-0}"  # 设置 CLEAN=1 来清理旧的构建文件（默认保留用于快速增量构建）

# 检查 xcodebuild
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "❌ 未找到 xcodebuild，请安装/打开 Xcode（首次运行以完成安装）"
  exit 1
fi

# 检查是否启用 Mac Catalyst（仅提示，不强制）
PBPX="AudiobookPlayer.xcodeproj/project.pbxproj"
if [[ -f "$PBPX" ]]; then
  if ! grep -q "SUPPORTS_MACCATALYST" "$PBPX"; then
    echo "⚠️ 检测到当前项目可能未启用 Mac Catalyst。请在 Xcode 中执行："
    echo "   1) 选择 Target: ${SCHEME}"
    echo "   2) Signing & Capabilities → 勾选 'Supports Mac Catalyst'"
    echo "   3) General → Deployment Info → 勾选 'Mac' 并设置最低 macOS 版本"
    echo "   4) 若使用到 iOS 特有 API，请在代码中加条件编译或替代方案"
    echo "完成后再次运行本脚本。"
  fi
else
  echo "⚠️ 未找到 ${PBPX}，将直接尝试构建..."
fi

# 准备目录
if [[ $CLEAN -eq 1 ]]; then
  echo "🧹 清理旧的构建文件..."
  rm -rf "$BUILD_ROOT"
else
  echo "📝 使用增量构建（设置 CLEAN=1 ./script.sh 来执行干净构建）"
fi
mkdir -p "$DERIVED" "$STAGE"

# Patch Pods xcconfig to remove MobileVLCKit for Mac Catalyst
# The [sdk=macosx*] conditional doesn't work for Catalyst (uses iphoneos SDK + macabi triple)
# So we directly strip VLC-related linker flags and framework search paths
echo "🔧 Patching Pods xcconfigs to exclude MobileVLCKit..."
XCCONFIG_DIR="Pods/Target Support Files/Pods-AudiobookPlayer"
for xcconfig in "$XCCONFIG_DIR"/*.xcconfig; do
  if grep -q 'MobileVLCKit' "$xcconfig"; then
    # Remove -framework "MobileVLCKit" and -framework "OpenGLES" from OTHER_LDFLAGS
    sed -i '' 's/ -framework "MobileVLCKit"//g' "$xcconfig"
    sed -i '' 's/ -framework "OpenGLES"//g' "$xcconfig"
    # Remove MobileVLCKit framework search paths
    sed -i '' 's| "${PODS_ROOT}/MobileVLCKit"||g' "$xcconfig"
    sed -i '' 's| "${PODS_XCFRAMEWORKS_BUILD_DIR}/MobileVLCKit"||g' "$xcconfig"
    # Remove MobileVLCKit module verifier flags
    sed -i '' 's| "-F${PODS_CONFIGURATION_BUILD_DIR}/MobileVLCKit"||g' "$xcconfig"
    # Remove any leftover conditional lines from Podfile post_install
    sed -i '' '/OTHER_LDFLAGS\[sdk=macosx/d' "$xcconfig"
    sed -i '' '/FRAMEWORK_SEARCH_PATHS\[sdk=macosx/d' "$xcconfig"
    sed -i '' '/Mac Catalyst: exclude MobileVLCKit/d' "$xcconfig"
    echo "  Patched: $xcconfig"
  fi
done

# Patch the frameworks embed script to skip MobileVLCKit
FRAMEWORKS_SH="$XCCONFIG_DIR/Pods-AudiobookPlayer-frameworks.sh"
if [[ -f "$FRAMEWORKS_SH" ]] && grep -q 'MobileVLCKit' "$FRAMEWORKS_SH"; then
  sed -i '' '/MobileVLCKit/d' "$FRAMEWORKS_SH"
  echo "  Patched: $FRAMEWORKS_SH"
fi

# Patch input/output xcfilelists to remove MobileVLCKit entries
for filelist in "$XCCONFIG_DIR"/*-frameworks-*.xcfilelist; do
  if [[ -f "$filelist" ]] && grep -q 'MobileVLCKit' "$filelist"; then
    sed -i '' '/MobileVLCKit/d' "$filelist"
    echo "  Patched: $filelist"
  fi
done

echo "🔨 构建 Mac Catalyst 应用（${CONFIG}）..."
set +e
xcodebuild -workspace "$WORKSPACE" \
           -scheme "$SCHEME" \
           -configuration "$CONFIG" \
           -destination 'generic/platform=macOS' \
           -derivedDataPath "$DERIVED" \
           build | tee "$BUILD_ROOT/build.log"
XCB_STATUS=$?
set -e

if [[ $XCB_STATUS -ne 0 ]]; then
  echo "❌ 构建失败。你可以使用以下命令快速筛选日志："
  echo "   grep -i error \"$BUILD_ROOT/build.log\""
  echo "   grep -i warning \"$BUILD_ROOT/build.log\""
  echo "   grep -i \"BUILD SUCCEEDED\" \"$BUILD_ROOT/build.log\""
  exit $XCB_STATUS
fi

echo "🔎 查找生成的 .app..."
APP_PATH=$(find "$DERIVED/Build/Products" -type d -name "*.app" | grep -i maccatalyst | head -n 1)
if [[ -z "$APP_PATH" ]]; then
  APP_PATH=$(find "$DERIVED/Build/Products" -type d -name "*.app" | head -n 1)
fi
if [[ -z "$APP_PATH" ]]; then
  echo "❌ 未找到构建产物 .app。请检查 $BUILD_ROOT/build.log"
  exit 1
fi
echo "✅ 找到应用: $APP_PATH"

echo "📁 准备 DMG 内容..."
DEST="$STAGE/${APP_NAME}"
mkdir -p "$DEST"
cp -R "$APP_PATH" "$DEST/"

# 提示文件
cat > "$DEST/README.txt" <<EOF
${APP_NAME} (Mac Catalyst)

打开提示：
- 双击打开 .app 运行
- 若 Gatekeeper 阻止，请右键 → 打开，或执行：
    xattr -dr com.apple.quarantine "${APP_NAME}.app"
EOF

echo "💿 创建 DMG..."
hdiutil create -volname "${APP_NAME}" \
              -srcfolder "$DEST" \
              -ov -format UDZO \
              "$OUT_DMG"

if [[ -f "$OUT_DMG" ]]; then
  echo "🎉 DMG 创建成功: $OUT_DMG"
  echo "   大小: $(du -h "$OUT_DMG" | cut -f1)"
  echo "   查看最后 20 行构建日志："
  tail -n 20 "$BUILD_ROOT/build.log" || true
else
  echo "❌ DMG 创建失败"
  exit 1
fi

echo "🔐 提示：未签名/未公证应用可能需要右键 → 打开 或移除隔离标记："
echo "    xattr -dr com.apple.quarantine \"$DEST/${APP_NAME}.app\""
echo "✅ 完成"