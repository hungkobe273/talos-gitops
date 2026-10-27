#!/bin/sh
# Runs a script from this folder inside vault-0 (default configure.sh) with the root token from
# ~/talos-kvm/vault-init.json on host2.
# Usage on host2: cd ~/talos-gitops && git pull -q --rebase && sh platform/vault/run-configure.sh [script.sh [ns/secret/key]]
# The token goes over stdin only: not in argv, env of this shell, or any file in the pod.
# Optional ns/secret/key (e.g. keycloak/keycloak-oidc-clients/VAULT_CLIENT_SECRET): that Secret value follows
# the token on stdin and is exported as PASSED_SECRET for the script (oidc.sh needs it).
set -eu
export KUBECONFIG="$HOME/talos-kvm/kubeconfig"
dir=$(dirname "$0")
script="$dir/${1:-configure.sh}"
[ -f "$script" ] || { echo "no such script: $script" >&2; exit 1; }
passed=""
if [ -n "${2:-}" ]; then
  ns=${2%%/*}; rest=${2#*/}; name=${rest%%/*}; key=${rest#*/}
  passed=$(kubectl -n "$ns" get secret "$name" -o go-template="{{with index .data \"$key\"}}{{base64decode .}}{{end}}")
  [ -n "$passed" ] || { echo "empty or missing: secret $ns/$name key $key" >&2; exit 1; }
fi
{
  python3 -c 'import json,os; print(json.load(open(os.path.expanduser("~/talos-kvm/vault-init.json")))["root_token"])'
  [ -z "$passed" ] || printf '%s\n' "$passed"
  cat "$script"
} | kubectl -n vault exec -i vault-0 -- sh -c '
  read -r VAULT_TOKEN; export VAULT_TOKEN
  if [ "$1" = 1 ]; then read -r PASSED_SECRET; export PASSED_SECRET; fi
  sh -s' sh "${passed:+1}"
