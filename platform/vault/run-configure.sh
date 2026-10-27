#!/bin/sh
# Runs a script from this folder inside vault-0 (default configure.sh) with the root token from
# ~/talos-kvm/vault-init.json on host2.
# Usage on host2: cd ~/talos-gitops && git pull -q --rebase && sh platform/vault/run-configure.sh [script.sh]
# The token goes over stdin only: not in argv, env of this shell, or any file in the pod.
set -eu
export KUBECONFIG="$HOME/talos-kvm/kubeconfig"
dir=$(dirname "$0")
script="$dir/${1:-configure.sh}"
[ -f "$script" ] || { echo "no such script: $script" >&2; exit 1; }
{
  python3 -c 'import json,os; print(json.load(open(os.path.expanduser("~/talos-kvm/vault-init.json")))["root_token"])'
  cat "$script"
} | kubectl -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; sh -s'
