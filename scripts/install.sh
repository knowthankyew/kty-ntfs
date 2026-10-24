#!/usr/bin/env bash
set -euo pipefail

# install.sh
# Installs kty-ntfs daemon, companion CLI, FSKit extension, and launchd service on macOS.
# Requires root privileges (run via sudo).
#
# Usage:
#   sudo ./scripts/install.sh
#   PREFIX=/opt/local sudo ./scripts/install.sh

if [[ $EUID -ne 0 ]]; then
    echo "Error: install.sh must be run with root privileges (e.g. 'sudo ./scripts/install.sh')." >&2
    exit 1
fi

PREFIX="${PREFIX:-/usr/local}"
BINDIR="${PREFIX}/bin"
APPEX_DIR="/Library/Filesystems"
LAUNCHD_DIR="/Library/LaunchDaemons"
LOG_DIR="/var/log"
SERVICE_NAME="com.knowthankyew.ntfsd"
PLIST_NAME="${SERVICE_NAME}.plist"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== kty-ntfs Installation ==="
echo "Install Prefix:       $PREFIX"
echo "Binary Directory:     $BINDIR"
echo "Extension Directory:  $APPEX_DIR"
echo "Launchd Plist:        $LAUNCHD_DIR/$PLIST_NAME"
echo ""

# 1. Ensure project binaries are built
CLI_BIN="$REPO_ROOT/build/bin/kty-ntfs"
DAEMON_BIN="$REPO_ROOT/build/bin/kty-ntfsd"
APPEX_BUNDLE="$REPO_ROOT/build/bin/kty-ntfs-fs.appex"
MENU_BUNDLE="$REPO_ROOT/build/bin/kty-ntfs-menu.app"
APP_DIR="/Applications"

if [[ ! -f "$CLI_BIN" || ! -f "$DAEMON_BIN" || ! -d "$APPEX_BUNDLE" || ! -d "$MENU_BUNDLE" ]]; then
    echo "[install] Release binaries not found. Building with make all..."
    if [[ -n "${SUDO_USER:-}" ]]; then
        sudo -u "$SUDO_USER" make -C "$REPO_ROOT" all
    else
        make -C "$REPO_ROOT" all
    fi
fi

# 2. Verify codesign integrity of built binaries
echo "[install] Verifying code signatures of built artifacts..."
codesign --verify --verbose "$CLI_BIN"
codesign --verify --verbose "$DAEMON_BIN"
codesign --verify --verbose "$APPEX_BUNDLE"
codesign --verify --verbose "$MENU_BUNDLE"

# 3. Create destination directories
echo "[install] Creating target directories..."
mkdir -p "$BINDIR" "$APPEX_DIR" "$LAUNCHD_DIR" "$LOG_DIR"

# 4. Unload existing launchd daemon if currently running
if launchctl list "$SERVICE_NAME" >/dev/null 2>&1; then
    echo "[install] Stopping currently active $SERVICE_NAME service..."
    launchctl bootout "system/$SERVICE_NAME" 2>/dev/null || launchctl unload "$LAUNCHD_DIR/$PLIST_NAME" 2>/dev/null || true
    sleep 1
fi

# 5. Install binaries
echo "[install] Installing binaries to $BINDIR..."
install -m 755 "$CLI_BIN" "$BINDIR/kty-ntfs"
install -m 755 "$DAEMON_BIN" "$BINDIR/kty-ntfsd"

# 6. Install FSKit App Extension bundle
echo "[install] Installing FSKit extension bundle to $APPEX_DIR..."
rm -rf "$APPEX_DIR/kty-ntfs-fs.appex"
cp -R "$APPEX_BUNDLE" "$APPEX_DIR/kty-ntfs-fs.appex"
chown -R root:wheel "$APPEX_DIR/kty-ntfs-fs.appex"
chmod -R 755 "$APPEX_DIR/kty-ntfs-fs.appex"

# 7. Install Menu Bar UI Companion App
echo "[install] Installing Menu Bar UI companion to $APP_DIR..."
rm -rf "$APP_DIR/kty-ntfs-menu.app"
cp -R "$MENU_BUNDLE" "$APP_DIR/kty-ntfs-menu.app"
chown -R root:wheel "$APP_DIR/kty-ntfs-menu.app"
chmod -R 755 "$APP_DIR/kty-ntfs-menu.app"

# 7. Configure and install LaunchDaemon plist
echo "[install] Installing LaunchDaemon service definition..."
PLIST_SRC="$REPO_ROOT/src/daemon/$PLIST_NAME"
PLIST_DST="$LAUNCHD_DIR/$PLIST_NAME"

if [[ "$BINDIR" == "/usr/local/bin" ]]; then
    cp "$PLIST_SRC" "$PLIST_DST"
else
    # Update binary path to match custom prefix
    sed "s|/usr/local/bin/kty-ntfsd|$BINDIR/kty-ntfsd|g" "$PLIST_SRC" > "$PLIST_DST"
fi

chown root:wheel "$PLIST_DST"
chmod 644 "$PLIST_DST"

# 8. Ensure log files exist with appropriate permissions
touch "$LOG_DIR/kty-ntfsd.log" "$LOG_DIR/kty-ntfsd.err"
chmod 644 "$LOG_DIR/kty-ntfsd.log" "$LOG_DIR/kty-ntfsd.err"

# 9. Bootstrap and launch the background daemon
echo "[install] Bootstrapping $SERVICE_NAME daemon..."
launchctl bootstrap system "$PLIST_DST" 2>/dev/null || launchctl load -w "$PLIST_DST"

# 10. Health check
echo "[install] Waiting for daemon initialization..."
HEALTHY=0
for i in {1..5}; do
    sleep 1
    if "$BINDIR/kty-ntfs" status >/dev/null 2>&1; then
        HEALTHY=1
        break
    fi
done

echo ""
echo "================================================================================"
if [[ $HEALTHY -eq 1 ]]; then
    echo " SUCCESS: kty-ntfs has been installed and kty-ntfsd is running."
else
    echo " NOTICE: kty-ntfs installed. Daemon bootstrap triggered."
    echo " Check daemon logs at $LOG_DIR/kty-ntfsd.err if status does not respond."
fi
echo "================================================================================"
echo "CLI Location:       $BINDIR/kty-ntfs"
echo "Daemon Location:    $BINDIR/kty-ntfsd"
echo "Extension Bundle:   $APPEX_DIR/kty-ntfs-fs.appex"
echo "Service Plist:      $PLIST_DST"
echo "Logs:               $LOG_DIR/kty-ntfsd.log"
echo ""
echo "Quick Test Commands:"
echo "  kty-ntfs status"
echo "  kty-ntfs list"
echo "================================================================================"
