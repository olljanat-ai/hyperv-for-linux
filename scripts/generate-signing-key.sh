#!/usr/bin/env bash
# Generate the GPG signing key used to sign the apt repository's Release
# file, store it in this repo's GitHub Actions secrets, and (optionally)
# print the public key so it can be committed somewhere durable.
#
# Run this exactly once per repository — re-running and replacing the
# key invalidates every previously-signed Release file.
#
# Prerequisites:
#   - gpg (>= 2.2)
#   - gh CLI, authenticated (gh auth status) against the repo you're in
#
# Usage:
#   scripts/generate-signing-key.sh
#   scripts/generate-signing-key.sh --name "Custom Name" --email me@host
#   scripts/generate-signing-key.sh --no-secrets   # just generate, don't upload

set -euo pipefail

NAME="hyperv-for-linux apt repo"
EMAIL="noreply@$(git config --get remote.origin.url 2>/dev/null \
                  | sed -E 's#.*github\.com[:/]([^/]+)/([^/.]+).*#\1.\2.invalid#' \
                  || echo example.invalid)"
KEY_TYPE="rsa4096"
UPLOAD_SECRETS=true

while [ "$#" -gt 0 ]; do
    case "$1" in
        --name)      NAME="$2"; shift 2 ;;
        --email)     EMAIL="$2"; shift 2 ;;
        --type)      KEY_TYPE="$2"; shift 2 ;;
        --no-secrets) UPLOAD_SECRETS=false; shift ;;
        -h|--help)
            sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

if ! command -v gpg >/dev/null 2>&1; then
    echo "error: gpg not installed." >&2; exit 1
fi
if [ "$UPLOAD_SECRETS" = true ] && ! command -v gh >/dev/null 2>&1; then
    echo "error: gh CLI not installed; install it or pass --no-secrets." >&2
    exit 1
fi

WORKDIR="$(mktemp -d -t hvfl-keygen.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT
chmod 700 "$WORKDIR"
export GNUPGHOME="$WORKDIR/gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

case "$KEY_TYPE" in
    rsa4096) KEY_LINES="Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096" ;;
    ed25519) KEY_LINES="Key-Type: EDDSA
Key-Curve: ed25519
Subkey-Type: ECDSA
Subkey-Curve: ed25519" ;;
    *) echo "error: unknown --type '$KEY_TYPE' (try rsa4096 or ed25519)" >&2; exit 2 ;;
esac

cat > "$WORKDIR/keygen.batch" <<EOF
%no-protection
$KEY_LINES
Name-Real: $NAME
Name-Email: $EMAIL
Expire-Date: 0
%commit
EOF

echo ">> Generating $KEY_TYPE key for '$NAME <$EMAIL>' (no passphrase)..."
gpg --batch --generate-key "$WORKDIR/keygen.batch"

KEY_ID="$(gpg --list-secret-keys --with-colons \
          | awk -F: '/^sec/{print $5; exit}')"
echo ">> Key ID: $KEY_ID"

gpg --armor --export-secret-keys "$KEY_ID" > "$WORKDIR/private.asc"
gpg --armor --export             "$KEY_ID" > "$WORKDIR/public.asc"

echo
echo "Files generated under $WORKDIR (this directory will be deleted when this script exits):"
ls -l "$WORKDIR"/*.asc

if [ "$UPLOAD_SECRETS" = true ]; then
    echo
    echo ">> Uploading APT_GPG_PRIVATE_KEY and APT_GPG_PASSPHRASE to GitHub repo secrets..."
    gh secret set APT_GPG_PRIVATE_KEY < "$WORKDIR/private.asc"
    gh secret set APT_GPG_PASSPHRASE  --body ""
    echo ">> Secrets uploaded."
else
    echo
    echo "Skipping secret upload (--no-secrets). To upload manually:"
    echo "    gh secret set APT_GPG_PRIVATE_KEY < <(cat <<'EOF'"
    echo "    ...paste contents of private.asc above..."
    echo "    EOF)"
    echo "    gh secret set APT_GPG_PASSPHRASE  --body ''"
fi

echo
echo "Public key (safe to share; the workflow also republishes this as"
echo "<repo-pages-url>/public.key on every successful build):"
echo "-----BEGIN PUBLIC KEY (copy from below) -----"
cat "$WORKDIR/public.asc"
echo "-----END PUBLIC KEY-----"
