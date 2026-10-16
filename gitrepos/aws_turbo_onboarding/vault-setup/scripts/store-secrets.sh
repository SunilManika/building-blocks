#!/usr/bin/env bash
# =============================================================================
# store-secrets.sh
# Stores all Turbonomic toolkit credentials into a running Vault instance.
#
# Requirements : curl, jq
# Usage        : ./store-secrets.sh <vault_addr> <vault_token>
# Example      : ./store-secrets.sh https://192.168.1.50:8200 hvs.XXXX
# =============================================================================
set -euo pipefail

VAULT_ADDR="${1:?Usage: $0 <vault_addr> <vault_token>}"
VAULT_TOKEN="${2:?Usage: $0 <vault_addr> <vault_token>}"
KV_MOUNT="secret"

# Helper: write a secret and report result
vault_write() {
  local path="$1"
  local payload="$2"
  local http_code
  http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"data\": ${payload}}" \
    "${VAULT_ADDR}/v1/${KV_MOUNT}/data/${path}")
  if [[ "$http_code" =~ ^(200|204)$ ]]; then
    echo "  [OK]  ${KV_MOUNT}/data/${path}"
  else
    echo "  [FAIL] ${KV_MOUNT}/data/${path} — HTTP ${http_code}" >&2
    exit 1
  fi
}

echo ""
echo "=================================================="
echo "  Storing Turbonomic Toolkit Secrets in Vault"
echo "=================================================="
echo "  Vault addr : ${VAULT_ADDR}"
echo "  KV mount   : ${KV_MOUNT}"
echo ""

# Turbonomic admin credentials
vault_write "turbo/turbonomic" \
  '{"username":"turboplanuser","password":"turboplanuser"}'

# WMI Windows targets
vault_write "turbo/wmi/turbo-wmi-win-d16" \
  '{"username":"turbowmid16","password":"TrbWmi#2026!X9@Q7","domain":"WORKGROUP"}'

vault_write "turbo/wmi/turbo-wmi-win-d14" \
  '{"username":"turbowmid14","password":"TrbWmi#2026!X9@Q7","domain":"WORKGROUP"}'

vault_write "turbo/wmi/turbo-wmi-win-d12" \
  '{"username":"turbowmid12","password":"TrbWmi#2026!X9@Q7","domain":"WORKGROUP"}'

vault_write "turbo/wmi/turbo-wmi-win-d10" \
  '{"username":"turbowmid10","password":"TrbWmi#2026!X9@Q7","domain":"WORKGROUP"}'

# SSH Linux target
vault_write "turbo/ssh/turbo-wmi-linux-d8" \
  '{"username":"azureuser"}'

echo ""
echo "  All secrets stored successfully."
echo "=================================================="
