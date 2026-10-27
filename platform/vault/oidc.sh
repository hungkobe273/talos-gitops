#!/bin/sh
# Vault UI login with Keycloak (realm talos, client "vault"). Runs INSIDE vault-0; start it from host2:
#   sh platform/vault/run-configure.sh oidc.sh keycloak/keycloak-oidc-clients/VAULT_CLIENT_SECRET
# Idempotent: re-running writes the same values.
# Keycloak group -> Vault policy (external identity groups, matched on the "groups" claim):
#   talos-admins  -> talos-admin  (everything)
#   talos-viewers -> talos-viewer (engines, auth methods, policies and secret NAMES; never secret values)
# Break-glass when Keycloak is down: the root token through run-configure.sh, as before.
set -eu
[ -n "${PASSED_SECRET:-}" ] || { echo "client secret missing: pass keycloak/keycloak-oidc-clients/VAULT_CLIENT_SECRET to run-configure.sh" >&2; exit 1; }

# Internal CA (public). Same certificate as BaoCao/talos-internal-ca.crt and ConfigMap talos-internal-ca
# (SHA-256 48:35:6A:23:...:10:A0:3A:8D). Vault uses it to reach https://keycloak.talos.internal.
CA_PEM=$(cat <<'EOF'
-----BEGIN CERTIFICATE-----
MIIBszCCAVqgAwIBAgIUA3ct+b3dSfmubNulaFMfmnDkqy0wCgYIKoZIzj0EAwIw
ODEWMBQGA1UEChMNdGFsb3Mta3ZtIGxhYjEeMBwGA1UEAxMVdGFsb3Mta3ZtIGlu
dGVybmFsIENBMB4XDTI2MTAxNjA2NTEzMFoXDTM2MTAxMzA2NTEzMFowODEWMBQG
A1UEChMNdGFsb3Mta3ZtIGxhYjEeMBwGA1UEAxMVdGFsb3Mta3ZtIGludGVybmFs
IENBMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEFhBc+Hg7EIQTx6fVJt7jNI2f
pu4t0dqTi+baV3FI7SZk3SX2BunJzcT/19HNZAy5ocSQ9tLAb7hQwzBgEM6EsKNC
MEAwDgYDVR0PAQH/BAQDAgKkMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFK7d
doDbcrQa85E+qWM7TKvs736sMAoGCCqGSM49BAMCA0cAMEQCIGbITibE6zNQTJIO
zuYI5WWKK0KnbJdzQK/3F7VgA8bKAiAWbUqh9WEXPOKVa3XDhs+ata9Vwlt9qDOE
v5YPJ9ilyQ==
-----END CERTIFICATE-----
EOF
)

# 1) Policies for the two Keycloak groups.
vault policy write talos-admin - <<'EOF'
path "*" { capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"] }
EOF
vault policy write talos-viewer - <<'EOF'
# Read the shape of Vault: engines, auth methods, policies.
path "sys/mounts"         { capabilities = ["read"] }
path "sys/auth"           { capabilities = ["read"] }
path "sys/policies/acl"   { capabilities = ["list"] }
path "sys/policies/acl/*" { capabilities = ["read"] }
# KV v2: list paths and see versions/metadata. No kv/data/*, so values stay hidden.
path "kv/metadata"        { capabilities = ["list"] }
path "kv/metadata/*"      { capabilities = ["read", "list"] }
EOF

# 2) OIDC auth method at "oidc" (UI callback: /ui/vault/auth/oidc/oidc/callback).
#    Writing the config makes Vault fetch the discovery document now, so DNS/CA/HAProxy errors show here.
vault auth list | grep -q '^oidc/' || vault auth enable -description="Keycloak realm talos" oidc
printf '%s' "$PASSED_SECRET" | vault write auth/oidc/config \
  oidc_discovery_url="https://keycloak.talos.internal/realms/talos" \
  oidc_discovery_ca_pem="$CA_PEM" \
  oidc_client_id=vault \
  oidc_client_secret=- \
  default_role=keycloak >/dev/null

# 3) One role for everybody in the realm; permissions come only from the groups below
#    (a user in neither group gets the "default" policy: can log in, sees nothing).
#    user_claim = preferred_username so the audit log shows readable names (usernames are not editable in realm talos).
vault write auth/oidc/role/keycloak \
  role_type=oidc \
  allowed_redirect_uris="https://vault.talos.internal/ui/vault/auth/oidc/oidc/callback" \
  user_claim=preferred_username \
  groups_claim=groups \
  token_policies=default \
  token_ttl=1h token_max_ttl=8h >/dev/null

# 4) External groups: Keycloak group name -> Vault policy.
acc=$(vault read -field=accessor sys/auth/oidc)
for pair in talos-admins:talos-admin talos-viewers:talos-viewer; do
  g=${pair%%:*}; p=${pair#*:}
  vault write "identity/group/name/$g" type=external policies="$p" >/dev/null
  gid=$(vault read -field=id "identity/group/name/$g")
  vault read -field=alias "identity/group/name/$g" | grep -q "$acc" || \
    vault write identity/group-alias name="$g" mount_accessor="$acc" canonical_id="$gid" >/dev/null
done

echo "OK: oidc=$(vault auth list | grep -c '^oidc/') role=$(vault list auth/oidc/role | grep -c '^keycloak$')" \
  "aliases=$(for g in talos-admins talos-viewers; do vault read -field=alias "identity/group/name/$g" | grep -c "$acc"; done | tr -d '\n')"
