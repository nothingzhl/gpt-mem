#!/usr/bin/env bash
# Used only by the explicitly dispatched signed build, never by pull requests.
set -euo pipefail
: "${RUNNER_TEMP:?GitHub runner required}"
: "${APPLE_CERTIFICATE_P12_BASE64:?Missing Developer ID certificate}"
: "${APPLE_CERTIFICATE_PASSWORD:?Missing certificate password}"
: "${APPLE_SIGN_IDENTITY:?Missing Developer ID signing identity}"
: "${APPLE_NOTARY_KEY_BASE64:?Missing App Store Connect API key}"
: "${APPLE_NOTARY_KEY_ID:?Missing App Store Connect key ID}"
: "${APPLE_NOTARY_ISSUER_ID:?Missing App Store Connect issuer ID}"
directory="$RUNNER_TEMP/gpt-manager-signing"
if [[ -e "$directory" || -L "$directory" ]]; then echo "Signing staging path already exists." >&2; exit 1; fi
umask 077
mkdir "$directory"
python3 - "$directory" <<'PY'
import base64, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
for variable, name in [("APPLE_CERTIFICATE_P12_BASE64", "certificate.p12"), ("APPLE_NOTARY_KEY_BASE64", "AuthKey.p8")]:
    (root / name).write_bytes(base64.b64decode(os.environ[variable], validate=True))
PY
keychain="$directory/signing.keychain-db"
keychain_password="$(openssl rand -hex 32)"
# Mask before passing the ephemeral password to any tool.
echo "::add-mask::$keychain_password"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$directory/certificate.p12" -k "$keychain" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign > /dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" > /dev/null
xcrun notarytool store-credentials gpt-manager-notary --key "$directory/AuthKey.p8" --key-id "$APPLE_NOTARY_KEY_ID" --issuer "$APPLE_NOTARY_ISSUER_ID" --keychain "$keychain"
rm -f "$directory/certificate.p12" "$directory/AuthKey.p8"
