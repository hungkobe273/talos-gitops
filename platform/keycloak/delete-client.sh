#!/bin/sh
# Deletes one client of realm "talos" from the RUNNING Keycloak (counterpart of upsert-client.sh).
# Remove the client from manifests/realm-import.json too, or a rebuild of the realm brings it back.
# Usage on host2: cd ~/talos-gitops && git pull -q --ff-only && sh platform/keycloak/delete-client.sh <clientId>
# - Admin login: hung-admin (realm master), password from ~/talos-kvm/keycloak-admin-password.txt, over stdin only;
#   kcadm runs with --no-config, so no admin token is left in the pod.
set -eu
export KUBECONFIG="$HOME/talos-kvm/kubeconfig"
client=${1:?usage: delete-client.sh <clientId>}
password=$(head -n 1 "$HOME/talos-kvm/keycloak-admin-password.txt" | tr -d '\r\n')
[ -n "$password" ] || { echo "empty Keycloak admin password file" >&2; exit 1; }

printf '%s\n' "$password" | kubectl -n keycloak exec -i keycloak-0 -c keycloak -- sh -c '
  read -r KC_CLI_PASSWORD; export KC_CLI_PASSWORD
  kc() { /opt/keycloak/bin/kcadm.sh "$@" --no-config --server http://localhost:8080 --realm master --user hung-admin; }
  id=$(kc get clients -r talos -q clientId="$1" --fields id --format csv --noquotes)
  if [ -n "$id" ]; then
    kc delete "clients/$id" -r talos && echo "OK: deleted client $1 ($id)"
  else
    echo "client $1 not found (already deleted?)"
  fi
  echo "clients left: $(kc get clients -r talos --fields clientId --format csv --noquotes | tr "\n" " ")"' sh "$client"
