#!/bin/sh
# One-time: generate every internal Harbor secret on host2 and print ONE SealedSecret
# (harbor/harbor-secrets) + the token-signing key pair (harbor/harbor-token-cert) on stdout. Values never touch the screen or the repo:
#   sh platform/harbor/make-secrets.sh > platform/harbor/manifests/harbor-secrets-sealed.yaml
# The admin password is also kept (600) in ~/talos-kvm/harbor-admin-password.txt so a
# person can log in when Keycloak is down. Re-running ROTATES everything (Harbor must
# then be restarted and the admin password changes), so run it once.
set -eu
umask 077
export KUBECONFIG="$HOME/talos-kvm/kubeconfig"
rand() { head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

ADMIN=$(rand 24)
REG_PASS=$(rand 32)
DB_PASS=$(rand 32)
# bcrypt htpasswd line for the registry's internal user, made in a throwaway pod
# (the password goes over stdin, not argv).
# kubectl run -i attaches to the container named like the pod, so both use $POD.
POD="htpasswd-$(rand 6 | tr A-Z a-z)"
REG_HTPASSWD=$(printf '%s' "$REG_PASS" | kubectl -n default run "$POD" \
  --image=docker.io/library/httpd:2.4.65-alpine --restart=Never --rm -i -q --pod-running-timeout=5m \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"'"$POD"'","image":"docker.io/library/httpd:2.4.65-alpine","stdin":true,"stdinOnce":true,"command":["htpasswd","-niB","harbor_registry_user"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
  | grep '^harbor_registry_user:')
[ -n "$REG_HTPASSWD" ] || { echo "ERROR: htpasswd failed" >&2; exit 1; }

printf '%s' "$ADMIN" > "$HOME/talos-kvm/harbor-admin-password.txt"

kubectl create secret generic harbor-secrets -n harbor --dry-run=client -o yaml \
  --from-literal=HARBOR_ADMIN_PASSWORD="$ADMIN" \
  --from-literal=secretKey="$(rand 16)" \
  --from-literal=secret="$(rand 32)" \
  --from-literal=CSRF_KEY="$(rand 32)" \
  --from-literal=JOBSERVICE_SECRET="$(rand 32)" \
  --from-literal=REGISTRY_HTTP_SECRET="$(rand 32)" \
  --from-literal=REGISTRY_PASSWD="$REG_PASS" \
  --from-literal=REGISTRY_HTPASSWD="$REG_HTPASSWD" \
  --from-literal=password="$DB_PASS" \
  --from-literal=POSTGRES_PASSWORD="$DB_PASS" \
| kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system --format yaml

# Key pair Harbor core uses to sign registry tokens (chart: core.secretName). Without it
# the chart generates a new pair on every render, so every Argo CD sync would rotate it.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
openssl req -x509 -newkey rsa:4096 -nodes -days 3650 -subj "/CN=harbor-token-service"   -keyout "$T/tls.key" -out "$T/tls.crt" 2>/dev/null
echo "---"
kubectl create secret tls harbor-token-cert -n harbor --cert="$T/tls.crt" --key="$T/tls.key"   --dry-run=client -o yaml | kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system --format yaml
