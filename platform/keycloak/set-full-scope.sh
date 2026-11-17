#!/bin/sh
# Sets only fullScopeAllowed on clients of realm "talos" in the RUNNING Keycloak (17/11).
# Why: Keycloak 26.8 warns that "Full scope allowed" will be removed. Our clients get permissions from the
# "groups" mapper, not from roles, so turning it off only drops realm_access/resource_access from tokens.
# upsert-client.sh is not used here: it rewrites the whole client from realm-import.json, and the live
# clients have small drifts (URI order, a test webOrigin) that are not worth touching for one field.
# Usage on host2: cd ~/talos-gitops && git pull -q --rebase && sh platform/keycloak/set-full-scope.sh false grafana argocd ...
# Rollback: the same command with "true".
# After each change it prints the claim names of an example access token for the first member of
# talos-admins (admin "evaluate scopes" endpoint, read-only), plus the groups value. No token is printed.
set -eu
export KUBECONFIG="$HOME/talos-kvm/kubeconfig"
value=${1:?usage: set-full-scope.sh <true|false> <clientId>...}
case "$value" in true|false) ;; *) echo "first argument must be true or false" >&2; exit 1 ;; esac
shift
[ $# -gt 0 ] || { echo "no clientId given" >&2; exit 1; }
password=$(head -n 1 "$HOME/talos-kvm/keycloak-admin-password.txt" | tr -d '\r\n')
[ -n "$password" ] || { echo "empty Keycloak admin password file" >&2; exit 1; }

printf '%s\n' "$password" | kubectl -n keycloak exec -i keycloak-0 -c keycloak -- sh -c '
  read -r KC_CLI_PASSWORD; export KC_CLI_PASSWORD
  value=$1; shift
  kc() { /opt/keycloak/bin/kcadm.sh "$@" --no-config --server http://localhost:8080 --realm master --user hung-admin; }
  gid=$(kc get groups -r talos -q search=talos-admins --fields id --format csv --noquotes | head -n 1)
  uid=$(kc get "groups/$gid/members" -r talos --fields id --format csv --noquotes | head -n 1)
  for client in "$@"; do
    id=$(kc get clients -r talos -q clientId="$client" --fields id --format csv --noquotes)
    [ -n "$id" ] || { echo "SKIP: no client $client"; continue; }
    kc update "clients/$id" -r talos -s fullScopeAllowed="$value"
    now=$(kc get "clients/$id" -r talos --fields fullScopeAllowed --format csv --noquotes)
    claims=$(kc get "clients/$id/evaluate-scopes/generate-example-access-token" -r talos -q scope=openid -q userId="$uid" \
      | sed -n "s/^  \"\([a-z_]*\)\" : .*/\1/p" | tr "\n" " ")
    groups=$(kc get "clients/$id/evaluate-scopes/generate-example-access-token" -r talos -q scope=openid -q userId="$uid" \
      | tr -d "\n " | sed -n "s/.*\"groups\":\[\([^]]*\)\].*/\1/p")
    echo "OK: $client fullScopeAllowed=$now groups=[$groups]"
    echo "    claims: $claims"
  done' sh "$value" "$@"
