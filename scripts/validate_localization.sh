#!/bin/bash
# Validate Localizable.xcstrings file integrity

set -e

XCSTRINGS="AudiobookPlayer/Localizable.xcstrings"

echo "🔍 Validating $XCSTRINGS..."

# Check file exists
if [ ! -f "$XCSTRINGS" ]; then
    echo "❌ ERROR: File not found: $XCSTRINGS"
    exit 1
fi

# Check file type
FILE_TYPE=$(file "$XCSTRINGS" | grep -o "JSON data" || echo "NOT_JSON")
if [ "$FILE_TYPE" != "JSON data" ]; then
    echo "❌ ERROR: File is not JSON format (might be binary plist)"
    echo "   Run: git checkout HEAD -- $XCSTRINGS"
    exit 1
fi

# Validate JSON and structure
python3 << 'PYEOF'
import json
import sys

try:
    with open('AudiobookPlayer/Localizable.xcstrings') as f:
        data = json.load(f)

    # Check required fields
    version = data.get('version')
    source_lang = data.get('sourceLanguage')
    strings = data.get('strings', {})

    if not version:
        print("❌ ERROR: Missing 'version' field")
        sys.exit(1)

    if version != "1.0":
        print(f"⚠️  WARNING: Unexpected version: {version} (expected '1.0')")

    if source_lang != "en":
        print(f"⚠️  WARNING: Unexpected sourceLanguage: {source_lang} (expected 'en')")

    # Count AI tab keys
    ai_keys = [k for k in strings.keys() if k.startswith('ai_tab')]

    print(f"✅ Version: {version}")
    print(f"✅ Total keys: {len(strings)}")
    print(f"✅ AI tab keys: {len(ai_keys)}")

    if len(ai_keys) != 37:
        print(f"⚠️  WARNING: Expected 37 AI tab keys, found {len(ai_keys)}")
        print(f"   Run: python3 scripts/add_ai_tab_keys.py")
        sys.exit(1)

    print("\n✅ Validation passed!")

except json.JSONDecodeError as e:
    print(f"❌ ERROR: Invalid JSON: {e}")
    sys.exit(1)
except Exception as e:
    print(f"❌ ERROR: {e}")
    sys.exit(1)
PYEOF
