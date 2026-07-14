#!/bin/bash
# package-maccatalyst-dmg.sh — Build Mac Catalyst .app, package into styled DMG, sign & notarize.
#
# Industry-standard approach: pre-built .DS_Store template (no AppleScript, no hacks).
# Create the template once: mount a DMG, arrange icons in Finder, copy .DS_Store to
# scripts/assets/maccatalyst-dmg.ds_store. The script uses it automatically.
#
# Usage:
#   ./scripts/package-maccatalyst-dmg.sh                    # build + DMG
#   SIGN=1 NOTARIZE=1 ./scripts/package-maccatalyst-dmg.sh  # + sign & notarize
#
# Required for signing/notarization:
#   - APPLE_DEVELOPER_ID: "Developer ID Application: Your Name (TEAMID)"
#   - APPLE_TEAM_ID:      your 10-char team ID
#   - APPLE_API_KEY_ID:   App Store Connect API key ID
#   - APPLE_API_ISSUER:   App Store Connect issuer UUID
#   - APPLE_API_KEY_PATH: path to .p8 private key
#
# Environment variables (all optional, sensible defaults):
#   SCHEME, WORKSPACE, CONFIG, APP_NAME, BUILD_ROOT, OUT_DMG, CLEAN
set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
SCHEME="${SCHEME:-AudiobookPlayer}"
PROJECT="${PROJECT:-AudiobookPlayer.xcodeproj}"
WORKSPACE="${WORKSPACE:-AudiobookPlayer.xcworkspace}"
CONFIG="${CONFIG:-Release}"
APP_NAME="${APP_NAME:-AudiobookPlayer}"
BUILD_ROOT="${BUILD_ROOT:-$PWD/build/maccatalyst}"
DERIVED="$BUILD_ROOT/DerivedData"
STAGE="$BUILD_ROOT/stage"
OUT_DMG="${OUT_DMG:-$PWD/${APP_NAME}-macOS.dmg}"
CLEAN="${CLEAN:-0}"
DS_STORE_TEMPLATE="${DS_STORE_TEMPLATE:-$PWD/scripts/assets/maccatalyst-dmg.ds_store}"
SIGN="${SIGN:-0}"
NOTARIZE="${NOTARIZE:-0}"
DMG_MOUNT="/tmp/${APP_NAME}-dmg-mount"

# ── Helpers ──────────────────────────────────────────────────────────────────
_script_dir() { cd "$(dirname "$0")" && pwd; }

_section()  { echo ""; echo "▶ $*"; echo ""; }
_ok()       { echo "  ✅ $*"; }
_warn()     { echo "  ⚠️  $*"; }
_fail()     { echo "  ❌ $*"; exit 1; }

# ── Prerequisites ────────────────────────────────────────────────────────────
_section "Checking prerequisites"

command -v xcodebuild >/dev/null 2>&1 || _fail "xcodebuild not found — install Xcode CLI tools"

# ── Clean ────────────────────────────────────────────────────────────────────
if [[ $CLEAN -eq 1 ]]; then
  _section "Cleaning build artifacts"
  rm -rf "$BUILD_ROOT"
else
  _ok "Using incremental build (CLEAN=1 for fresh build)"
fi
mkdir -p "$DERIVED" "$STAGE"

# ── Patch Pods for Catalyst (remove MobileVLCKit) ────────────────────────────
if [[ -d "Pods/Target Support Files" ]]; then
  _section "Patching Pods xcconfigs to exclude MobileVLCKit"

  XCCONFIG_DIR="Pods/Target Support Files/Pods-AudiobookPlayer"
  for xcconfig in "$XCCONFIG_DIR"/*.xcconfig; do
    [[ -f "$xcconfig" ]] || continue
    if grep -q 'MobileVLCKit' "$xcconfig"; then
      sed -i '' \
        -e 's/ -framework "MobileVLCKit"//g' \
        -e 's/ -framework "OpenGLES"//g' \
        -e 's| "${PODS_ROOT}/MobileVLCKit"||g' \
        -e 's| "${PODS_XCFRAMEWORKS_BUILD_DIR}/MobileVLCKit"||g' \
        -e 's| "-F${PODS_CONFIGURATION_BUILD_DIR}/MobileVLCKit"||g' \
        -e '/OTHER_LDFLAGS\[sdk=macosx/d' \
        -e '/FRAMEWORK_SEARCH_PATHS\[sdk=macosx/d' \
        -e '/Mac Catalyst: exclude MobileVLCKit/d' \
        "$xcconfig"
      _ok "Patched: $xcconfig"
    fi
  done

  FRAMEWORKS_SH="$XCCONFIG_DIR/Pods-AudiobookPlayer-frameworks.sh"
  if [[ -f "$FRAMEWORKS_SH" ]] && grep -q 'MobileVLCKit' "$FRAMEWORKS_SH"; then
    sed -i '' '/MobileVLCKit/d' "$FRAMEWORKS_SH"
    _ok "Patched: $FRAMEWORKS_SH"
  fi

  for filelist in "$XCCONFIG_DIR"/*-frameworks-*.xcfilelist; do
    [[ -f "$filelist" ]] || continue
    if grep -q 'MobileVLCKit' "$filelist"; then
      sed -i '' '/MobileVLCKit/d' "$filelist"
      _ok "Patched: $filelist"
    fi
  done
fi

# ── Build ────────────────────────────────────────────────────────────────────
_section "Building Mac Catalyst app ($CONFIG)"

# Auto-detect workspace vs project
if [[ -d "$WORKSPACE" ]]; then
  BUILD_TARGET=(-workspace "$WORKSPACE")
  _ok "Using workspace: $WORKSPACE"
else
  BUILD_TARGET=(-project "$PROJECT")
  _ok "Using project: $PROJECT"
fi

# Check Catalyst destination
if xcodebuild -showdestinations -scheme "$SCHEME" "${BUILD_TARGET[@]}" 2>/dev/null | grep -q "platform:macOS"; then
  DEST="generic/platform=macOS"
else
  DEST="platform=macOS,arch=x86_64,variant=Mac Catalyst"
fi

xcodebuild "${BUILD_TARGET[@]}" \
           -scheme "$SCHEME" \
           -configuration "$CONFIG" \
           -destination "$DEST" \
           -derivedDataPath "$DERIVED" \
           -allowProvisioningUpdates \
           build | tee "$BUILD_ROOT/build.log" || {
  _fail "Build failed. Check: grep -i error $BUILD_ROOT/build.log"
}

# ── Locate .app ──────────────────────────────────────────────────────────────
APP_PATH=$(find "$DERIVED/Build/Products" -type d -name "*.app" | grep -i maccatalyst | head -n 1)
[[ -n "$APP_PATH" ]] || APP_PATH=$(find "$DERIVED/Build/Products" -type d -name "*.app" | head -n 1)
[[ -n "$APP_PATH" ]] || _fail "Could not find .app in build products"
_ok "App: $APP_PATH"

# ── Apply minimal Catalyst entitlements ────────────────────────────────────
_section "Applying minimal Catalyst entitlements"

# Xcode's dev signing injects restricted entitlements (iCloud, Siri, app-groups)
# that AMFI rejects without a provisioning profile. Re-sign with minimal set.
if [[ -f "$(_script_dir)/maccatalyst.entitlements" ]]; then
  if [[ -n "${APPLE_DEVELOPER_ID:-}" ]]; then
    SIGN_ID="$APPLE_DEVELOPER_ID"
  else
    SIGN_ID="-"  # ad-hoc signing
    _ok "Using ad-hoc signing (set APPLE_DEVELOPER_ID for Developer ID)"
  fi
  codesign --deep --force --sign "$SIGN_ID" \
    --entitlements "$(_script_dir)/maccatalyst.entitlements" \
    --options runtime \
    "$APP_PATH" 2>&1 || _fail "Re-signing failed"
  _ok "Re-signed with minimal entitlements"
fi

# ── Sign .app if Developer ID available ───────────────────────────────────────
APPLE_DEVELOPER_ID="${APPLE_DEVELOPER_ID:-}"
if [[ "$SIGN" -eq 1 || "$NOTARIZE" -eq 1 ]]; then
  if [[ -n "$APPLE_DEVELOPER_ID" ]]; then
    _section "Signing .app with Developer ID"
    codesign --deep --force --verify --verbose \
             --sign "$APPLE_DEVELOPER_ID" \
             --options runtime \
             --entitlements "$(_script_dir)/maccatalyst.entitlements" 2>/dev/null \
             "$APP_PATH" || {
      # Retry without entitlements file (many Catalyst apps don't need one)
      _warn "Entitlements file not found, signing without"
      codesign --deep --force --verify --verbose \
               --sign "$APPLE_DEVELOPER_ID" \
               --options runtime \
               "$APP_PATH"
    }
    _ok "Signed: $APP_PATH"
  else
    _warn "APPLE_DEVELOPER_ID not set — skipping code signing"
  fi
fi

# ── Stage DMG contents ───────────────────────────────────────────────────────
_section "Staging DMG contents"

rm -rf "$STAGE/${APP_NAME}"
mkdir -p "$STAGE/${APP_NAME}"

# Copy .app
cp -R "$APP_PATH" "$STAGE/${APP_NAME}/"

# Applications symlink (drag-to-install)
ln -sf /Applications "$STAGE/${APP_NAME}/Applications"

# README
cat > "$STAGE/${APP_NAME}/README.txt" <<EOF
${APP_NAME} (Mac Catalyst)

To install: drag the app icon to the Applications folder.

If Gatekeeper blocks launch:
  Right-click → Open, or run:
  xattr -dr com.apple.quarantine "${APP_NAME}.app"
EOF

_ok "Staged: $STAGE/${APP_NAME}"

# ── Create DMG ───────────────────────────────────────────────────────────────
_section "Creating DMG"

rm -f "$OUT_DMG"

hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "$STAGE/${APP_NAME}" \
  -ov -format UDZO \
  "$OUT_DMG" || _fail "hdiutil create failed"

_ok "Created: $OUT_DMG ($(du -h "$OUT_DMG" | cut -f1))"

# ── Apply .DS_Store template for Finder layout ───────────────────────────────
if [[ -f "$DS_STORE_TEMPLATE" ]]; then
  _section "Applying .DS_Store template for Finder layout"

  # Mount DMG read-write to inject .DS_Store
  mkdir -p "$DMG_MOUNT"
  hdiutil attach "$OUT_DMG" -readwrite -noverify -noautoopen -mountpoint "$DMG_MOUNT" >/dev/null || _fail "Could not mount DMG"

  cp "$DS_STORE_TEMPLATE" "$DMG_MOUNT/.DS_Store"

  # Set Finder to refresh (touching the volume forces Finder to re-read .DS_Store)
  touch "$DMG_MOUNT"

  hdiutil detach "$DMG_MOUNT" -force >/dev/null || true
  _ok "Applied DS_Store template"
else
  _warn "No .DS_Store template at $DS_STORE_TEMPLATE"
  echo ""
  echo "     To add Finder layout (icon positions, background):"
  echo "     1. Open $OUT_DMG in Finder"
  echo "     2. Arrange icons as desired (View → Show View Options → Icon View)"
  echo "     3. In Terminal: cp /Volumes/${APP_NAME}/.DS_Store scripts/assets/maccatalyst-dmg.ds_store"
  echo "     4. Re-run this script — template will be used automatically"
  echo ""
fi

# ── Sign DMG ─────────────────────────────────────────────────────────────────
if [[ "$SIGN" -eq 1 ]] && [[ -n "$APPLE_DEVELOPER_ID" ]]; then
  _section "Signing DMG"
  codesign --force --verify --verbose \
           --sign "$APPLE_DEVELOPER_ID" \
           --options runtime \
           "$OUT_DMG"
  _ok "Signed: $OUT_DMG"
fi

# ── Notarize & Staple ────────────────────────────────────────────────────────
if [[ "$NOTARIZE" -eq 1 ]]; then
  _section "Submitting for notarization"

  required_vars=(APPLE_TEAM_ID APPLE_API_KEY_ID APPLE_API_ISSUER APPLE_API_KEY_PATH)
  missing=()
  for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then missing+=("$var"); fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    _warn "Missing notarization env vars: ${missing[*]}"
  else
    xcrun notarytool submit "$OUT_DMG" \
      --team-id "$APPLE_TEAM_ID" \
      --key-id "$APPLE_API_KEY_ID" \
      --issuer "$APPLE_API_ISSUER" \
      --key "$APPLE_API_KEY_PATH" \
      --wait 2>&1 | tee "$BUILD_ROOT/notarize.log" || {
      _warn "Notarization failed. Check: $BUILD_ROOT/notarize.log"
    }

    # Staple the ticket
    if xcrun stapler validate "$OUT_DMG" 2>/dev/null; then
      _ok "Already stapled"
    else
      xcrun stapler staple "$OUT_DMG" 2>&1 && _ok "Stapled" || _warn "Staple failed"
    fi
  fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────
_section "Done"
echo "   DMG:  $OUT_DMG"
echo "   Size: $(du -h "$OUT_DMG" | cut -f1)"
echo ""

if [[ "$SIGN" -ne 1 ]] && [[ "$NOTARIZE" -ne 1 ]]; then
  echo "   💡 Tip: SIGN=1 NOTARIZE=1 ./scripts/package-maccatalyst-dmg.sh     "
  echo "          (set APPLE_DEVELOPER_ID and notarization env vars first)      "
fi

if [[ ! -f "$DS_STORE_TEMPLATE" ]]; then
  echo "   💡 Tip: open the DMG, arrange icons, then:                            "
  echo "          cp /Volumes/${APP_NAME}/.DS_Store scripts/assets/maccatalyst-dmg.ds_store"
fi

echo ""
