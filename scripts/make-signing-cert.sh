#!/bin/bash
# Creates the local self-signed code signing identity used to build Snipiko.
#
# Why this exists: macOS stores the Screen Recording grant against the app's
# "designated requirement". An ad-hoc signed app has no certificate, so TCC
# falls back to pinning the exact cdhash of the binary -- which changes on
# every rebuild, so the grant is silently invalidated and the app asks again.
# Signing with a stable certificate makes the requirement certificate-based,
# so it survives rebuilds.
#
# Run once. Re-running replaces the identity (you will have to re-grant
# Screen Recording, because the certificate hash changes).

set -euo pipefail

IDENTITY="Snipiko Local Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "Identity '$IDENTITY' already exists. Nothing to do."
    security find-identity -v -p codesigning | grep "$IDENTITY"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cs.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = Snipiko Local Dev
O  = Snipiko
C  = US
[ v3 ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "Generating self-signed code signing certificate..."
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cs.cnf"

openssl pkcs12 -export -out "$WORK/ident.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -passout pass:snipiko -name "$IDENTITY"

echo "Importing into the login keychain..."
security import "$WORK/ident.p12" -k "$KEYCHAIN" -P snipiko -A

echo "Trusting it for code signing..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
security find-identity -v -p codesigning | grep "$IDENTITY"
echo "Done."
