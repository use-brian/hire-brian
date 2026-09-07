#!/usr/bin/env bash
set -euo pipefail
set +x
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$HERE"
[ ! -e .env ] || { echo ".env exists; use stack.sh MODE up to resume or update.sh MODE to update. Secrets were not replaced." >&2; exit 1; }
unset BRIAN_ENV_FILE
source ./common.sh "${1:-oss}"
# A missing .env is not permission to initialize over a previous installation.
existing=$(docker volume ls --filter name=use-brian_ --format '{{.Name}}')
[ -z "$existing" ] || { echo "Existing use-brian volumes found. Restore the original .env and use update.sh; do not generate new keys." >&2; exit 1; }
umask 077
candidate=$(mktemp "$HERE/.env.install.XXXXXX")
trap 'rm -f "$candidate"' EXIT
# Generate only a new installation, never rotate an existing database/key set.
python3 - <<'PY' > "$candidate"
import base64
import os
from pathlib import Path
import secrets

for line in Path('.env.example').read_text().splitlines():
    if not line or line.startswith('#'):
        print(line)
        continue
    name, value = line.split('=', 1)
    if value.startswith('replace-'):
        value = (base64.b64encode(secrets.token_bytes(32)).decode()
                 if name.endswith(('_ENCRYPTION_KEY', '_CREDENTIAL_KEY')) else secrets.token_hex(32))
    else:
        value = os.environ.get(name, value)
    if '\n' in value or '\r' in value:
        raise SystemExit('Installation setting must not contain a newline')
    value = value.replace('\\', '\\\\').replace("'", "\\'")
    print(f"{name}='{value}'")
PY
# Compose shell variables outrank dotenv files. Do not let inherited old secrets
# override the independent keys just generated for this new installation.
while IFS='=' read -r name value; do
  if [[ "$value" == replace-* ]]; then unset "$name"; fi
done < .env.example
export BRIAN_ENV_FILE=$candidate
source ./common.sh "${1:-oss}"
preflight install
# Publish without overwriting a concurrently created .env; no stack changes yet.
ln "$candidate" .env
export BRIAN_ENV_FILE=.env
source ./common.sh "${1:-oss}"
preflight install
deploy
echo "Installation started. Use bash stack.sh $MODE ps to check readiness."
