#!/usr/bin/env bash
set -euo pipefail

# codesign-adhoc.sh
# Performs ad-hoc code signing on built Mach-O binaries and App Extensions (.appex)
# Enforces Fail-Closed security: invalid or missing entitlements file halts execution.

TARGET="${1:-}"

if [[ -z "$TARGET" ]]; then
    echo "Usage: $0 <path-to-binary-or-bundle> [entitlements.plist]" >&2
    exit 1
fi

if [[ ! -e "$TARGET" ]]; then
    echo "Error: Target does not exist: $TARGET" >&2
    exit 1
fi

ENTITLEMENTS="${2:-}"

echo "[codesign] Signing $TARGET (ad-hoc)..."

CODESIGN_ARGS=(--force --sign - --options runtime)

# Only apply --deep if the target is a directory or app extension bundle
if [[ -d "$TARGET" ]]; then
    CODESIGN_ARGS+=(--deep)
fi

if [[ -n "$ENTITLEMENTS" ]]; then
    if [[ ! -f "$ENTITLEMENTS" ]]; then
        echo "Error: Specified entitlements file does not exist: $ENTITLEMENTS" >&2
        exit 1
    fi
    CODESIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
fi

codesign "${CODESIGN_ARGS[@]}" "$TARGET"

echo "[codesign] Verifying $TARGET..."
codesign --verify --verbose "$TARGET"
echo "[codesign] Successfully signed $TARGET."
