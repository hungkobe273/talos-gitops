#!/bin/sh
# Creates (or updates) one client of realm "talos" in the RUNNING Keycloak from manifests/realm-import.json.
# Why: the realm import only runs on an empty realm (IGNORE_EXISTING), so a client added to the file
# later never reaches the live realm by itself. The file stays the source of truth for a rebuild.
# Usage on host2: cd ~/talos-gitops && git pull -q --rebase && sh platform/keycloak/upsert-client.sh <clientId>
#
# - Client secret (OIDC clients): key <CLIENTID>_CLIENT_SECRET of Secret keycloak/keycloak-oidc-clients (SealedSecret
#   manifests/keycloak-oidc-clients-sealed.yaml), the same value the import placeholder ${...} gets.
#   SAML clients have no secret (Keycloak signs, the SP checks with the realm certificate).
# - Admin login: hung-admin (realm master), password from ~/talos-kvm/keycloak-admin-password.txt.
# - Password and client JSON travel over stdin only (not argv, not a file); kcadm runs with --no-config,
#   so no admin token is left in the pod.
# - Update (client already exists) sets the client fields and secret; protocol mappers are only created
#   with a new client. Change mappers of an existing client in the admin console.
set -eu
export KUBECONFIG="$HOME/talos-kvm/kubeconfig"
client=${1:?usage: upsert-client.sh <clientId>}
dir=$(dirname "$0")
var=$(printf '%s' "$client" | tr 'a-z-' 'A-Z_')_CLIENT_SECRET

# Empty for clients without a secret placeholder (SAML clients); python below refuses a missing secret.
secret=$(kubectl -n keycloak get secret keycloak-oidc-clients -o go-template="{{with index .data \"$var\"}}{{base64decode .}}{{end}}")
password=$(head -n 1 "$HOME/talos-kvm/keycloak-admin-password.txt" | tr -d '\r\n')
[ -n "$password" ] || { echo "empty Keycloak admin password file" >&2; exit 1; }

# The client object with ${VAR} replaced; the secret goes into python over stdin.
json=$(printf '%s\n' "$secret" | python3 -c '
import json, sys
path, client, var = sys.argv[1:4]
secret = sys.stdin.readline().rstrip("\n")
realm = json.load(open(path, encoding="utf-8"))
found = [c for c in realm["clients"] if c["clientId"] == client]
if not found:
    sys.exit("client %s not in %s" % (client, path))
c = found[0]
if c.get("secret") == "${%s}" % var:
    if not secret:
        sys.exit("Secret keycloak/keycloak-oidc-clients has no key %s (SealedSecret not synced yet?)" % var)
    c["secret"] = secret
print(json.dumps(c))
' "$dir/manifests/realm-import.json" "$client" "$var")

printf '%s\n%s\n' "$password" "$json" | kubectl -n keycloak exec -i keycloak-0 -c keycloak -- sh -c '
  read -r KC_CLI_PASSWORD; export KC_CLI_PASSWORD
  kc() { /opt/keycloak/bin/kcadm.sh "$@" --no-config --server http://localhost:8080 --realm master --user hung-admin; }
  id=$(kc get clients -r talos -q clientId="$1" --fields id --format csv --noquotes)
  if [ -n "$id" ]; then
    kc update "clients/$id" -r talos -f - && echo "OK: updated client $1 ($id)"
  else
    id=$(kc create clients -r talos -f - -i) && echo "OK: created client $1 ($id)"
  fi' sh "$client"
