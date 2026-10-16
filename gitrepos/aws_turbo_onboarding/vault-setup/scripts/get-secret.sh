#!/usr/bin/env bash
# =============================================================================
# get-secret.sh
# Retrieves a secret from Vault using AppRole authentication.
#
# Requirements : curl, jq
# Usage        : ./get-secret.sh <secret_path> [field]
# Examples     :
#   ./get-secret.sh turbo/turbonomic              # prints all fields as JSON
#   ./get-secret.sh turbo/turbonomic username     # prints only the username value
#
# Environment variables required:
#   VAULT_ADDR      - Vault server URL  (e.g. https://192.168.1.50:8200)
#   VAULT_ROLE_ID   - AppRole role_id   (from output/approle-credentials.json)
#   VAULT_SECRET_ID - AppRole secret_id (from output/approle-credentials.json)
# =============================================================================
set -euo pipefail

RAW_PATH="${1:?Usage: $0 <secret_path> [field]}"
FIELD="${2:-}"
KV_MOUNT="secret"

# Strip leading "secret/data/", "secret/", or "data/" if passed by user
SECRET_PATH="${RAW_PATH#secret/data/}"
SECRET_PATH="${SECRET_PATH#secret/}"
SECRET_PATH="${SECRET_PATH#data/}"

: "${VAULT_ADDR:?VAULT_ADDR environment variable is not set}"
: "${VAULT_ROLE_ID:?VAULT_ROLE_ID environment variable is not set}"
: "${VAULT_SECRET_ID:?VAULT_SECRET_ID environment variable is not set}"

# Authenticate with AppRole and retrieve a short-lived client token
CLIENT_TOKEN=$(curl -sk \
  -X POST \
  -H "Content-Type: application/json" \
  -d "{\"role_id\":\"${VAULT_ROLE_ID}\",\"secret_id\":\"${VAULT_SECRET_ID}\"}" \
  "${VAULT_ADDR}/v1/auth/approle/login" | jq -r '.auth.client_token')

if [[ -z "$CLIENT_TOKEN" || "$CLIENT_TOKEN" == "null" ]]; then
  echo "ERROR: AppRole authentication failed. Check VAULT_ROLE_ID and VAULT_SECRET_ID." >&2
  exit 1
fi

# Retrieve the secret
SECRET_JSON=$(curl -sk \
  -H "X-Vault-Token: ${CLIENT_TOKEN}" \
  "${VAULT_ADDR}/v1/${KV_MOUNT}/data/${SECRET_PATH}")

# Check for errors
if echo "$SECRET_JSON" | jq -e '.errors' > /dev/null 2>&1; then
  echo "ERROR: $(echo "$SECRET_JSON" | jq -r '.errors[]')" >&2
  exit 1
fi

if [[ -z "$FIELD" ]]; then
  # Print all fields as JSON
  echo "$SECRET_JSON" | jq '.data.data'
else
  # Print a specific field value
  echo "$SECRET_JSON" | jq -r ".data.data.${FIELD}"
fi
