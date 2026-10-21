#!/usr/bin/env bash
set -euo pipefail

# codesign-adhoc.sh
# Performs ad-hoc code signing on built Mach-O binaries and App Extensions (.appex)

TARGET="${1:-}"

if [[ -z "$TARGET" ]]; then
    echo "Usage: $0 <path-to-binary-or-bundle> [entitlements.plist]"
    exit 1
fi

ENTITLEMENTS="${2:-}"

echo "[codesign] Signing $TARGET (ad-hoc)..."

if [[ -n "$ENTITLEMENTS" && -f "$ENTITLEMENTS" ]]; then
    codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" --options runtime "$TARGET"
else
    codesign --force --deep --sign - --options runtime "$TARGET"
fi

echo "[codesign] Verifying $TARGET..."
codesign --verify --verbose "$TARGET"
echo "[codesign] Successfully signed $TARGET."
