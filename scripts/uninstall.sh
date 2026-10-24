#!/usr/bin/env bash
set -euo pipefail

# uninstall.sh
# Unloads launchd service and removes kty-ntfs binaries and FSKit extension.
# Requires root privileges (run via sudo).
#
# Usage:
#   sudo ./scripts/uninstall.sh [--purge-logs]
#   PREFIX=/opt/local sudo ./scripts/uninstall.sh

if [[ $EUID -ne 0 ]]; then
    echo "Error: uninstall.sh must be run with root privileges (e.g. 'sudo ./scripts/uninstall.sh')." >&2
    exit 1
fi

PREFIX="${PREFIX:-/usr/local}"
BINDIR="${PREFIX}/bin"
APPEX_DIR="/Library/Filesystems"
LAUNCHD_DIR="/Library/LaunchDaemons"
LOG_DIR="/var/log"
SERVICE_NAME="com.knowthankyew.ntfsd"
PLIST_NAME="${SERVICE_NAME}.plist"

PURGE_LOGS=0
for arg in "$@"; do
    if [[ "$arg" == "--purge-logs" ]]; then
        PURGE_LOGS=1
    fi
done

echo "=== kty-ntfs Uninstallation ==="
echo "Install Prefix:       $PREFIX"
echo ""

# 1. Stop and unload launchd daemon
if launchctl list "$SERVICE_NAME" >/dev/null 2>&1 || [[ -f "$LAUNCHD_DIR/$PLIST_NAME" ]]; then
    echo "[uninstall] Stopping and removing $SERVICE_NAME launchd service..."
    launchctl bootout "system/$SERVICE_NAME" 2>/dev/null || launchctl unload "$LAUNCHD_DIR/$PLIST_NAME" 2>/dev/null || true
    rm -f "$LAUNCHD_DIR/$PLIST_NAME"
fi

# 2. Remove binaries
echo "[uninstall] Removing binaries from $BINDIR..."
rm -f "$BINDIR/kty-ntfs"
rm -f "$BINDIR/kty-ntfsd"

# 3. Remove FSKit App Extension bundle
echo "[uninstall] Removing FSKit extension from $APPEX_DIR..."
rm -rf "$APPEX_DIR/kty-ntfs-fs.appex"

# 4. Remove Menu Bar UI Companion App
echo "[uninstall] Removing Menu Bar UI companion from /Applications..."
rm -rf "/Applications/kty-ntfs-menu.app"

# 4. Optional log cleanup
if [[ $PURGE_LOGS -eq 1 ]]; then
    echo "[uninstall] Purging daemon logs..."
    rm -f "$LOG_DIR/kty-ntfsd.log" "$LOG_DIR/kty-ntfsd.err"
else
    echo "[uninstall] Preserving log files in $LOG_DIR (pass --purge-logs to remove)."
fi

echo ""
echo "================================================================================"
echo " SUCCESS: kty-ntfs has been completely uninstalled from this system."
echo "================================================================================"
