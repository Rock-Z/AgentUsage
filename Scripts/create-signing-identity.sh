#!/usr/bin/env bash
set -euo pipefail

IDENTITY_NAME="AgentUsage Code Signing"
OUTPUT_P12="${1:-$PWD/AgentUsage-Code-Signing.p12}"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SIGNING_KEYCHAIN="$HOME/Library/Keychains/AgentUsage-signing.keychain-db"
PASSWORD_SERVICE="io.github.rock-z.agentusage.release-signing"

if security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" 2>/dev/null \
  | grep -F "\"$IDENTITY_NAME\"" >/dev/null
then
  echo "The $IDENTITY_NAME identity already exists."
  exit 0
fi
if [[ -e "$SIGNING_KEYCHAIN" ]]; then
  echo "A dedicated signing keychain already exists but has no valid identity:" >&2
  echo "$SIGNING_KEYCHAIN" >&2
  echo "Move it aside or delete it before trying again." >&2
  exit 1
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/AgentUsage-signing.XXXXXX")"
CREATED_KEYCHAIN=0
cleanup() {
  status=$?
  rm -rf "$TEMP_DIR"
  if [[ "$status" -ne 0 && "$CREATED_KEYCHAIN" -eq 1 ]]; then
    security delete-keychain "$SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT

PRIVATE_KEY="$TEMP_DIR/private-key.pem"
CERTIFICATE="$TEMP_DIR/certificate.pem"
P12_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"
KEYCHAIN_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"

openssl req \
  -new \
  -newkey rsa:3072 \
  -x509 \
  -sha256 \
  -days 3650 \
  -nodes \
  -subj "/CN=$IDENTITY_NAME/O=AgentUsage/OU=AGENTUSAGE" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,digitalSignature,keyCertSign" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -keyout "$PRIVATE_KEY" \
  -out "$CERTIFICATE"

openssl pkcs12 \
  -export \
  -legacy \
  -name "$IDENTITY_NAME" \
  -inkey "$PRIVATE_KEY" \
  -in "$CERTIFICATE" \
  -passout "pass:$P12_PASSWORD" \
  -out "$OUTPUT_P12"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"
CREATED_KEYCHAIN=1
security set-keychain-settings -lut 21600 "$SIGNING_KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"
security import "$OUTPUT_P12" \
  -k "$SIGNING_KEYCHAIN" \
  -P "$P12_PASSWORD" \
  -T /usr/bin/codesign
security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "$SIGNING_KEYCHAIN" \
  "$CERTIFICATE"
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$KEYCHAIN_PASSWORD" \
  "$SIGNING_KEYCHAIN" >/dev/null
security list-keychains -d user -s "$LOGIN_KEYCHAIN" "$SIGNING_KEYCHAIN"
security add-generic-password \
  -U \
  -s "$PASSWORD_SERVICE" \
  -a "keychain-password" \
  -w "$KEYCHAIN_PASSWORD" \
  "$LOGIN_KEYCHAIN" >/dev/null
security add-generic-password \
  -U \
  -s "$PASSWORD_SERVICE" \
  -a "certificate-password" \
  -w "$P12_PASSWORD" \
  "$LOGIN_KEYCHAIN" >/dev/null

IDENTITY_HASH="$(
  security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" \
    | awk -v name="$IDENTITY_NAME" 'index($0, "\"" name "\"") { print $2; exit }'
)"
if [[ -z "$IDENTITY_HASH" ]]; then
  echo "Created the certificate, but macOS does not consider it a valid code-signing identity." >&2
  exit 1
fi

chmod 600 "$OUTPUT_P12"
echo
echo "Created code-signing identity: $IDENTITY_NAME"
echo "Identity SHA-1: $IDENTITY_HASH"
echo "Dedicated keychain: $SIGNING_KEYCHAIN"
echo "PKCS#12 file: $OUTPUT_P12"
echo "Passwords: stored in the login Keychain under $PASSWORD_SERVICE"
echo
echo "Keep the PKCS#12 file private. It and its stored password create the CI signing secrets."
