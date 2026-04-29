#!/usr/bin/env bash
set -euo pipefail

# One-time setup: create a self-signed codesigning identity in the user's login
# keychain so rebuilds produce a stable Designated Requirement. TCC keys on that
# DR, so grants persist across rebuilds instead of being invalidated by every
# new CDHash (which is what happens with pure ad-hoc signing).

CERT_NAME="Whisper Free Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

log() { printf '==> %s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Idempotency: bail if the identity already exists. `find-identity -v -p codesigning`
# filters by trust policy, which self-signed roots fail — so we check without -v.
if security find-identity | grep -q "\"$CERT_NAME\""; then
    log "Identity '$CERT_NAME' already present in login keychain. Nothing to do."
    exit 0
fi

command -v openssl >/dev/null || err "openssl not found on PATH"

WORK=$(mktemp -d)
trap "rm -rf '$WORK'" EXIT

log "Generating self-signed codesigning certificate"

cat > "$WORK/cert.conf" <<EOF
[req]
distinguished_name = req_dn
prompt             = no
x509_extensions    = v3_req

[req_dn]
CN = $CERT_NAME
O  = Local Development
C  = US

[v3_req]
basicConstraints    = CA:FALSE
keyUsage            = digitalSignature
extendedKeyUsage    = codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -config "$WORK/cert.conf" >/dev/null 2>&1

# Apple's `security import` only reads PKCS12 files that use the old SHA1 MAC
# and PBE-SHA1-3DES ciphers; OpenSSL 3 defaults to modern algorithms. It also
# chokes on empty passwords in the p12. Use a throwaway passphrase and pass
# the same one to `security import -P`.
P12_PASS="wf-local-dev"
openssl pkcs12 -export -legacy \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg SHA1 \
    -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$CERT_NAME" -passout "pass:$P12_PASS"

log "Importing into login keychain"

# -A: any app can use the key without prompting (traditional ACL)
# -T codesign: also grant codesign ACL access explicitly
security import "$WORK/identity.p12" \
    -k "$KEYCHAIN" \
    -P "$P12_PASS" \
    -A \
    -T /usr/bin/codesign >/dev/null

log "Verifying"
if ! security find-identity | grep -q "\"$CERT_NAME\""; then
    err "Import reported success but identity not visible. Check 'security find-identity' manually."
fi

# Self-signed roots show as CSSMERR_TP_NOT_TRUSTED under `-v`, but codesign uses
# the identity regardless — trust matters for Gatekeeper, not for code signing
# itself. We only need the key + cert pair to be present.

cat <<EOF

Installed identity: $CERT_NAME

The first time codesign uses this key (during the next build) macOS may show a
keychain dialog asking for your account password and whether to allow access.
Click "Always Allow" once; subsequent builds will be silent.

You can now run: ./build.sh
EOF
