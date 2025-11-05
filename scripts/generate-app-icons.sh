#!/bin/bash

# generate-app-icons.sh
# Generates iOS app icons from a source image
# Usage: ./scripts/generate-app-icons.sh <source-image-path>

set -e

if [ $# -eq 0 ]; then
    echo "Error: No source image provided"
    echo "Usage: $0 <source-image-path>"
    echo "Example: $0 ~/Downloads/logo.png"
    exit 1
fi

SOURCE_IMAGE="$1"

if [ ! -f "$SOURCE_IMAGE" ]; then
    echo "Error: Source image not found: $SOURCE_IMAGE"
    exit 1
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ICON_DIR="$PROJECT_ROOT/AudiobookPlayer/Assets.xcassets/AppIcon.appiconset"

if [ ! -d "$ICON_DIR" ]; then
    echo "Error: AppIcon.appiconset directory not found: $ICON_DIR"
    exit 1
fi

echo "Generating iOS app icons from: $SOURCE_IMAGE"
echo "Output directory: $ICON_DIR"
echo ""

# iOS App Icon sizes (based on Contents.json requirements)
declare -a SIZES=(
    "40:AppIcon-40.png"      # Notification 2x (20pt)
    "58:AppIcon-58.png"      # Settings 2x (29pt)
    "60:AppIcon-60.png"      # Notification 3x (20pt)
    "80:AppIcon-80.png"      # Spotlight 2x (40pt)
    "87:AppIcon-87.png"      # Settings 3x (29pt)
    "120:AppIcon-120.png"    # Spotlight 3x (40pt)
    "152:AppIcon-152.png"    # iPad App 2x (76pt)
    "167:AppIcon-167.png"    # iPad Pro 2x (83.5pt)
    "180:AppIcon-180.png"    # iPhone App 3x (60pt)
    "1024:AppIcon-1024.png"  # App Store
)

for SIZE_DEF in "${SIZES[@]}"; do
    SIZE="${SIZE_DEF%%:*}"
    FILENAME="${SIZE_DEF##*:}"
    OUTPUT_PATH="$ICON_DIR/$FILENAME"

    echo "Generating ${SIZE}x${SIZE} → $FILENAME"
    sips -z "$SIZE" "$SIZE" "$SOURCE_IMAGE" --out "$OUTPUT_PATH" > /dev/null
done

echo ""
echo "✓ Successfully generated all app icons!"
echo ""
echo "Next steps:"
echo "1. Review the generated icons in Xcode"
echo "2. Stage changes: git add AudiobookPlayer/Assets.xcassets/AppIcon.appiconset/*.png"
echo "3. Commit: git commit -m 'Update app icon'"
