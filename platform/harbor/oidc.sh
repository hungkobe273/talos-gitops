#!/bin/sh
# Switch Harbor login to Keycloak (realm talos, client harbor). Run on host2:
#   sh platform/harbor/oidc.sh
# - talos-admins -> Harbor system admin; everyone else in the realm can log in, sees
#   only projects they are made member of (add group talos-viewers to project talos as
#   Guest in the UI or API: read/pull only).
# - Local "admin" keeps working (password ~/talos-kvm/harbor-admin-password.txt) as the
#   way in when Keycloak is down.
# Harbor refuses to change auth mode once local users other than admin exist; there are none.
# Secrets (admin password, client secret) go in the request body only, never argv/screen.
set -eu
export KUBECONFIG="$HOME/talos-kvm/kubeconfig"
PORT=18092
kubectl -n harbor port-forward svc/harbor-core "$PORT:80" </dev/null >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null; rm -f /tmp/harbor-oidc.json' EXIT
sleep 3
API="http://127.0.0.1:$PORT/api/v2.0"
hc() { printf 'user = "admin:%s"\n' "$(cat "$HOME/talos-kvm/harbor-admin-password.txt")" | curl -sS -K - -H 'Content-Type: application/json' "$@"; }

umask 077
kubectl -n keycloak get secret keycloak-oidc-clients -o go-template='{{index .data "HARBOR_CLIENT_SECRET" | base64decode}}' \
| python3 -c '
import json,sys
secret=sys.stdin.read().strip()
if not secret: sys.exit("HARBOR_CLIENT_SECRET missing in keycloak/keycloak-oidc-clients (SealedSecret not synced?)")
print(json.dumps({
  "auth_mode": "oidc_auth",
  "oidc_name": "Keycloak",
  "oidc_endpoint": "https://keycloak.talos.internal/realms/talos",
  "oidc_client_id": "harbor",
  "oidc_client_secret": secret,
  "oidc_scope": "openid,profile,email,offline_access",
  "oidc_groups_claim": "groups",
  "oidc_admin_group": "talos-admins",
  "oidc_user_claim": "preferred_username",
  "oidc_verify_cert": True,
  "oidc_auto_onboard": True,
}))' > /tmp/harbor-oidc.json

hc -X PUT "$API/configurations" --data @/tmp/harbor-oidc.json -o /dev/null -w 'configurations: %{http_code}\n'
# Ask Harbor to reach Keycloak's discovery document now (DNS/CA problems show here).
hc -X POST "$API/system/oidc/ping" -d '{"url":"https://keycloak.talos.internal/realms/talos","verify_cert":true}' -o /dev/null -w 'oidc ping: %{http_code}\n'
hc "$API/configurations" | python3 -c 'import json,sys;c=json.load(sys.stdin);print("auth_mode =", c["auth_mode"]["value"], "| endpoint =", c["oidc_endpoint"]["value"], "| admin group =", c["oidc_admin_group"]["value"])'
