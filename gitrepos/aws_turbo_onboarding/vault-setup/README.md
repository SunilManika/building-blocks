# HashiCorp Vault — Single-Node Deployment on RHEL

Ansible-based deployment of HashiCorp Vault on a dedicated RHEL VM with:

- **Single-node Integrated Storage (Raft)** — no external Consul or etcd required
- **Auto-unseal on reboot** via a systemd one-shot service (file-based keys; swap for AWS KMS / Azure Key Vault in production)
- **AppRole authentication** for all toolkit scripts — no root tokens in config files
- **TLS-enabled listener** on port 8200 with a self-signed certificate
- **KV v2 secrets engine** with a least-privilege policy scoped to `secret/turbo/*`

---

## Directory Layout

```
vault-setup/
├── README.md
├── inventory/
│   └── hosts.ini                          # Set your RHEL VM IP here
├── group_vars/
│   └── vault.yml                          # All variables: version, TLS, AppRole, secrets
├── roles/
│   └── vault/
│       ├── defaults/main.yml              # Role defaults (overridden by group_vars)
│       ├── handlers/main.yml              # vault restart / systemd reload handlers
│       └── tasks/
│           ├── main.yml                   # Orchestrates all task files
│           ├── install.yml                # Downloads & installs Vault binary
│           ├── configure.yml              # vault.hcl, TLS cert, systemd service
│           ├── init_unseal.yml            # vault operator init + unseal
│           ├── auto_unseal.yml            # Systemd auto-unseal service on reboot
│           └── secrets.yml                # KV engine, AppRole, store all credentials
│       └── templates/
│           ├── vault.hcl.j2               # Vault server config (Raft + TLS)
│           ├── vault.service.j2           # systemd vault unit
│           └── vault-unseal.service.j2    # systemd auto-unseal one-shot unit
├── playbooks/
│   ├── deploy.yml                         # Full deploy: install → configure → init → secrets
│   └── store-secrets.yml                  # Re-run to rotate / update credentials
├── scripts/
│   ├── store-secrets.sh                   # Bash helper: write creds via Vault REST API
│   └── get-secret.sh                      # Bash helper: retrieve a secret (smoke test)
└── output/                                # Created at runtime (git-ignored)
    ├── vault-init.json                    # Unseal keys + root token — store offline securely
    └── approle-credentials.json           # role_id + secret_id for toolkit scripts
```

---

## Prerequisites

### Ansible control node (your workstation or CI/CD machine)
```bash
pip install ansible
ansible-galaxy collection install ansible.posix   # for firewalld module
ansible --version   # requires 2.12+
```

### RHEL Vault VM
- RHEL 8 or 9 (Rocky Linux, AlmaLinux, CentOS Stream also supported)
- SSH access with a user that has `sudo` rights
- Outbound HTTPS to `releases.hashicorp.com` (or use an internal mirror)
- Inbound TCP **8200** open from the management VM

---

## Quick Start

### 1 — Set your Vault VM IP

Edit [`inventory/hosts.ini`](inventory/hosts.ini):
```ini
[vault]
192.168.1.50 ansible_user=rhel_admin ansible_ssh_private_key_file=~/.ssh/id_ed25519
```

### 2 — Review variables

Edit [`group_vars/vault.yml`](group_vars/vault.yml). Minimum changes:
- `vault_tls_cert_subject_alt_names` — add your Vault VM IP or hostname
- `vault_secrets` — update passwords if they differ from `config/config.json`

### 3 — Deploy Vault

```bash
cd vault-setup
ansible-playbook -i inventory/hosts.ini playbooks/deploy.yml
```

This single command:
1. Installs the Vault binary and sets `cap_ipc_lock`
2. Generates a self-signed TLS certificate
3. Deploys `vault.hcl` (Raft storage, TLS listener) and the systemd service
4. Initialises Vault and unseals it
5. Installs the `vault-unseal.service` one-shot unit for auto-unseal on reboot
6. Enables KV v2 at `secret/`, creates the `turbo-toolkit` AppRole + policy
7. Stores all credentials from `group_vars/vault.yml` into Vault

### 4 — Copy AppRole credentials to the Windows management VM

After the playbook completes, `output/approle-credentials.json` contains:
```json
{
  "vault_addr":  "https://192.168.1.50:8200",
  "role_id":     "...",
  "secret_id":   "..."
}
```

Set these as **system environment variables** on the Windows management VM:
```powershell
[System.Environment]::SetEnvironmentVariable('VAULT_ADDR',      'https://192.168.1.50:8200', 'Machine')
[System.Environment]::SetEnvironmentVariable('VAULT_ROLE_ID',   '<role_id>',                  'Machine')
[System.Environment]::SetEnvironmentVariable('VAULT_SECRET_ID', '<secret_id>',                'Machine')
```

### 5 — Remove plaintext passwords from config.json

Replace credential fields with `vault_path` references. The toolkit scripts
will resolve them at runtime via the Vault API:

```json
{
  "turbonomic": {
    "host": "tz1.demo.turbonomic.com",
    "api_base_url": "https://tz1.demo.turbonomic.com/api/v3",
    "vault_path": "turbo/turbonomic"
  },
  "targets": {
    "windows": [
      {
        "display_name": "WMI-turbo-wmi-win-d16",
        "vm_name": "turbo-wmi-win-d16",
        "nameOrAddress": "localhost",
        "vault_path": "turbo/wmi/turbo-wmi-win-d16"
      }
    ]
  }
}
```

---

## Secret Paths in Vault

| Secret Path | Fields stored |
|---|---|
| `secret/turbo/turbonomic` | `username`, `password` |
| `secret/turbo/wmi/turbo-wmi-win-d16` | `username`, `password`, `domain` |
| `secret/turbo/wmi/turbo-wmi-win-d14` | `username`, `password`, `domain` |
| `secret/turbo/wmi/turbo-wmi-win-d12` | `username`, `password`, `domain` |
| `secret/turbo/wmi/turbo-wmi-win-d10` | `username`, `password`, `domain` |
| `secret/turbo/ssh/turbo-wmi-linux-d8` | `username` |

---

## Auto-Unseal on Reboot

The `vault-unseal.service` systemd unit runs as a `Type=oneshot` service
after `vault.service` starts. It:
1. Waits up to 60 s for the Vault API to become responsive
2. Reads unseal keys from `/etc/vault.d/.unseal_keys` (mode 0400, vault user)
3. Submits keys until Vault reports `sealed: false`

> **Security note:** The unseal key file contains key shares on disk.
> For production workloads replace with **AWS KMS** or **Azure Key Vault** auto-unseal:
> set `vault_auto_unseal_type: awskms` in `group_vars/vault.yml` — the
> `vault-unseal.service` will not be installed and Vault will unseal itself
> via the KMS seal stanza in `vault.hcl`.

---

## Rotating Credentials

Update passwords in `group_vars/vault.yml` then re-run the secrets playbook:
```bash
ansible-playbook -i inventory/hosts.ini playbooks/store-secrets.yml
```

Or use the bash helper directly:
```bash
export VAULT_ADDR=https://192.168.1.50:8200
./scripts/store-secrets.sh "$VAULT_ADDR" "<root_token_or_admin_token>"
```

---

## Smoke Test

Verify a secret is readable via AppRole:
```bash
export VAULT_ADDR=https://192.168.1.50:8200
export VAULT_ROLE_ID=<role_id>
export VAULT_SECRET_ID=<secret_id>

# Print all fields for the Turbonomic admin account
./scripts/get-secret.sh turbo/turbonomic

# Print only the password
./scripts/get-secret.sh turbo/wmi/turbo-wmi-win-d16 password
```
