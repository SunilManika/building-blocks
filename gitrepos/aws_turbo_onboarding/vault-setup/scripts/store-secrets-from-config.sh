#!/usr/bin/env bash
# =============================================================================
# store-secrets-from-config.sh
# Reads credentials directly from config/config.json and dynamically stores
# them into HashiCorp Vault KV v2 engine.
#
# Requirements : curl, jq
# Usage        : ./store-secrets-from-config.sh [config_file] [vault_addr] [vault_token]
# Example      :
#   export VAULT_ADDR="https://127.0.0.1:8200"
#   export VAULT_TOKEN="hvs.xxxx"
#   ./store-secrets-from-config.sh config/config.json
# =============================================================================
set -euo pipefail

CONFIG_FILE="${1:-config/config.json}"
VAULT_ADDR="${2:-${VAULT_ADDR:-https://127.0.0.1:8200}}"
VAULT_TOKEN="${3:-${VAULT_TOKEN:-}}"
KV_MOUNT="secret"

# Check dependencies
for cmd in curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Required tool '$cmd' is not installed." >&2
    exit 1
  fi
done

# Check config file
if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: Configuration file not found at '$CONFIG_FILE'." >&2
  exit 1
fi

# Attempt to load token from vault-init.json if not provided
if [ -z "$VAULT_TOKEN" ]; then
  if [ -f "vault-setup/output/vault-init.json" ]; then
    VAULT_TOKEN=$(jq -r '.root_token // empty' vault-setup/output/vault-init.json 2>/dev/null || true)
  elif [ -f "output/vault-init.json" ]; then
    VAULT_TOKEN=$(jq -r '.root_token // empty' output/vault-init.json 2>/dev/null || true)
  elif [ -f "/etc/vault.d/.vault_init.json" ]; then
    VAULT_TOKEN=$(sudo jq -r '.root_token // empty' /etc/vault.d/.vault_init.json 2>/dev/null || true)
  fi
fi

if [ -z "$VAULT_TOKEN" ]; then
  echo "ERROR: VAULT_TOKEN not provided and could not be detected automatically." >&2
  echo "Usage: $0 [config_file] [vault_addr] <vault_token>" >&2
  exit 1
fi

# Function to write secrets into Vault KV v2
vault_write() {
  local secret_path="$1"
  local json_payload="$2"
  local http_code

  http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"data\": ${json_payload}}" \
    "${VAULT_ADDR}/v1/${KV_MOUNT}/data/${secret_path}")

  if [[ "$http_code" =~ ^(200|204)$ ]]; then
    echo "  [OK]   ${KV_MOUNT}/data/${secret_path}"
  else
    echo "  [FAIL] ${KV_MOUNT}/data/${secret_path} — HTTP ${http_code}" >&2
    return 1
  fi
}

echo "=================================================="
echo " Storing Credentials from ${CONFIG_FILE} into Vault"
echo "=================================================="
echo " Vault Address : ${VAULT_ADDR}"
echo " KV Mount      : ${KV_MOUNT}"
echo " Config File   : ${CONFIG_FILE}"
echo ""

TOTAL_STORED=0

# -----------------------------------------------------------------------------
# 1. Turbonomic Admin Credentials
# -----------------------------------------------------------------------------
TURBO_USER=$(jq -r '.turbonomic.admin_username // .turbonomic.username // empty' "$CONFIG_FILE")
TURBO_PASS=$(jq -r '.turbonomic.admin_password // .turbonomic.password // empty' "$CONFIG_FILE")

if [ -n "$TURBO_USER" ] && [ -n "$TURBO_PASS" ]; then
  echo "[+] Processing Turbonomic appliance credentials..."
  PAYLOAD=$(jq -n --arg u "$TURBO_USER" --arg p "$TURBO_PASS" '{username: $u, password: $p}')
  vault_write "turbo/turbonomic" "$PAYLOAD"
  TOTAL_STORED=$((TOTAL_STORED + 1))
fi

# -----------------------------------------------------------------------------
# 2. Windows Targets Credentials
# -----------------------------------------------------------------------------
WIN_COUNT=$(jq -r '.targets.windows | length // 0' "$CONFIG_FILE")
if [ "$WIN_COUNT" -gt 0 ]; then
  echo "[+] Processing ${WIN_COUNT} Windows target(s)..."
  for ((i=0; i<WIN_COUNT; i++)); do
    VM_NAME=$(jq -r ".targets.windows[$i].vm_name // empty" "$CONFIG_FILE")
    W_USER=$(jq -r ".targets.windows[$i].username // empty" "$CONFIG_FILE")
    W_PASS=$(jq -r ".targets.windows[$i].password // empty" "$CONFIG_FILE")
    DOMAIN=$(jq -r ".targets.windows[$i].domain // \"WORKGROUP\"" "$CONFIG_FILE")

    if [ -n "$VM_NAME" ]; then
      PAYLOAD=$(jq -n \
        --arg u "$W_USER" \
        --arg p "$W_PASS" \
        --arg d "$DOMAIN" \
        '{username: $u, password: $p, domain: $d}')
      vault_write "turbo/wmi/${VM_NAME}" "$PAYLOAD"
      TOTAL_STORED=$((TOTAL_STORED + 1))
    fi
  done
fi

# -----------------------------------------------------------------------------
# 3. Linux Targets Credentials
# -----------------------------------------------------------------------------
LIN_COUNT=$(jq -r '.targets.linux | length // 0' "$CONFIG_FILE")
if [ "$LIN_COUNT" -gt 0 ]; then
  echo "[+] Processing ${LIN_COUNT} Linux target(s)..."
  for ((i=0; i<LIN_COUNT; i++)); do
    VM_NAME=$(jq -r ".targets.linux[$i].vm_name // empty" "$CONFIG_FILE")
    L_USER=$(jq -r ".targets.linux[$i].username // empty" "$CONFIG_FILE")

    if [ -n "$VM_NAME" ]; then
      PAYLOAD=$(jq -n \
        --arg u "$L_USER" \
        '{username: $u}')
      vault_write "turbo/ssh/${VM_NAME}" "$PAYLOAD"
      TOTAL_STORED=$((TOTAL_STORED + 1))
    fi
  done
fi

echo ""
echo "=================================================="
echo " Done: ${TOTAL_STORED} secret(s) stored in Vault."
echo "=================================================="
