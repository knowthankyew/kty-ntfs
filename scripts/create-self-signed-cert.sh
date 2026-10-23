#!/usr/bin/env bash
set -euo pipefail

# create-self-signed-cert.sh
# Generates a local self-signed code signing certificate and imports it into the macOS Keychain.
# Designed for local development and testing of kty-ntfs prior to Apple Developer ID enrollment.
#
# Usage:
#   ./scripts/create-self-signed-cert.sh [certificate-name] [keychain-name]
#
# Examples:
#   ./scripts/create-self-signed-cert.sh
#   ./scripts/create-self-signed-cert.sh my-custom-identity

CERT_NAME="${1:-kty-ntfs-local}"
KEYCHAIN="${2:-login.keychain-db}"
DAYS=3650

echo "=== kty-ntfs Local Self-Signed Certificate Generator ==="
echo "Certificate Name: $CERT_NAME"
echo "Target Keychain:  $KEYCHAIN"
echo "Validity:         $DAYS days"
echo ""

# Verify prerequisites
if ! command -v openssl >/dev/null 2>&1; then
    echo "Error: openssl command not found. Please install Xcode Command Line Tools." >&2
    exit 1
fi

if ! command -v security >/dev/null 2>&1; then
    echo "Error: macOS security utility not found." >&2
    exit 1
fi

# Check if certificate already exists in keychain
if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Warning: A certificate named '$CERT_NAME' already exists in $KEYCHAIN."
    read -r -p "Do you want to overwrite / recreate it? [y/N]: " CONFIRM || CONFIRM="n"
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Aborted by user. Existing certificate preserved."
        echo ""
        echo "To use the existing certificate for building kty-ntfs, run:"
        echo "  export KTY_CODESIGN_IDENTITY=\"$CERT_NAME\""
        echo "  make all"
        exit 0
    fi
    echo "Removing existing certificate '$CERT_NAME' from $KEYCHAIN..."
    security delete-certificate -c "$CERT_NAME" "$KEYCHAIN" 2>/dev/null || true
fi

# Secure temporary directory for keys and configurations
TMP_DIR="$(mktemp -d -t kty_cert_XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

cat << EOF > "$TMP_DIR/cert.cnf"
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3_codesign

[ dn ]
CN = $CERT_NAME
O = KnowThankYew Local
OU = Local Development & Evaluation

[ v3_codesign ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
EOF

echo "[1/3] Generating 2048-bit RSA private key and self-signed X.509 certificate..."
openssl req -new -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP_DIR/key.pem" \
    -out "$TMP_DIR/cert.pem" \
    -days "$DAYS" \
    -config "$TMP_DIR/cert.cnf" >/dev/null 2>&1

echo "[2/3] Bundling PKCS#12 archive for macOS Keychain import..."
PKCS12_EXTRA_ARGS=()
# OpenSSL 3.x requires -legacy for PKCS#12 encryption compatibility with macOS SecKeychainItemImport
if openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then
    PKCS12_EXTRA_ARGS+=(-legacy)
fi

openssl pkcs12 "${PKCS12_EXTRA_ARGS[@]}" -export \
    -inkey "$TMP_DIR/key.pem" \
    -in "$TMP_DIR/cert.pem" \
    -out "$TMP_DIR/cert.p12" \
    -passout pass:ktylocal \
    -name "$CERT_NAME"

echo "[3/3] Importing identity into $KEYCHAIN..."
security import "$TMP_DIR/cert.p12" \
    -k "$KEYCHAIN" \
    -P ktylocal \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null

echo ""
echo "================================================================================"
echo " SUCCESS: Certificate '$CERT_NAME' imported successfully into $KEYCHAIN."
echo "================================================================================"
echo ""
echo "Next Steps & Usage Instructions:"
echo "1. Trust Settings (Optional):"
echo "   To prevent trust warnings, open Keychain Access, locate '$CERT_NAME' in your"
echo "   login keychain, expand 'Trust', and set 'Code Signing' to 'Always Trust'."
echo ""
echo "2. Build with your self-signed identity:"
echo "   export KTY_CODESIGN_IDENTITY=\"$CERT_NAME\""
echo "   make clean && make all"
echo ""
echo "3. Automated / Non-interactive testing:"
echo "   If you prefer building without any Keychain authorization prompts, do not"
echo "   set KTY_CODESIGN_IDENTITY (or set it to '-'). The build system defaults to"
echo "   ad-hoc codesigning, which requires zero keychain interaction."
echo "================================================================================"
