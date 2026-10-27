#!/bin/sh
# One-time (idempotent) Vault configuration for talos-kvm. Runs INSIDE vault-0;
# start it from host2 with run-configure.sh (passes the root token on stdin).
# The root token comes in on stdin and never touches the command line or a file in the pod.
# Re-running is safe: every step checks or overwrites with the same value.
set -eu

# 1) Audit log: who read which secret, when (file on the audit PVC).
vault audit list 2>/dev/null | grep -q '^file/' || vault audit enable file file_path=/vault/audit/audit.log

# 2) KV v2 at "kv". Path convention: kv/<namespace>/<app>, one key per env variable.
vault secrets list | grep -q '^kv/' || vault secrets enable -path=kv -version=2 kv

# 3) Kubernetes auth: Vault checks service-account tokens with the API server
#    (TokenReview, allowed by the chart's system:auth-delegator binding).
vault auth list | grep -q '^kubernetes/' || vault auth enable kubernetes
vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443" >/dev/null

# 4) ESO may only read application secrets.
vault policy write eso-read - <<'EOF'
path "kv/data/*"     { capabilities = ["read"] }
path "kv/metadata/*" { capabilities = ["read", "list"] }
EOF

# 5) Role "eso": only the external-secrets service account in its namespace.
vault write auth/kubernetes/role/eso \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-read ttl=1h >/dev/null

# 6) demo-app's ".env" (demo values; DEMO_API_KEY is a fake secret to prove the flow).
vault kv get kv/demo/demo-app >/dev/null 2>&1 || \
  vault kv put kv/demo/demo-app ERROR_RATE=0 DEMO_API_KEY="demo-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')" >/dev/null

echo "OK: audit=$(vault audit list | grep -c '^file/') kv=$(vault secrets list | grep -c '^kv/') k8s-auth=$(vault auth list | grep -c '^kubernetes/') role=eso keys=$(vault kv get -format=json kv/demo/demo-app | grep -c '\"ERROR_RATE\"\|\"DEMO_API_KEY\"')"
