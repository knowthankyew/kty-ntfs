#!/usr/bin/env bash
set -euo pipefail

# codesign-adhoc.sh
# Performs code signing on built Mach-O binaries and App Extensions (.appex)
# Supports ad-hoc signing (default: "-") or a custom self-signed/Developer ID identity via KTY_CODESIGN_IDENTITY.
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
IDENTITY="${KTY_CODESIGN_IDENTITY:--}"

if [[ "$IDENTITY" == "-" ]]; then
    echo "[codesign] Signing $TARGET (ad-hoc)..."
    CODESIGN_ARGS=(--force --sign - --options runtime)
else
    echo "[codesign] Signing $TARGET (identity: $IDENTITY)..."
    # When signing with a local self-signed or Developer ID identity, use timestamp=none to prevent network timeouts during offline builds
    CODESIGN_ARGS=(--force --sign "$IDENTITY" --options runtime --timestamp=none)
fi

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

