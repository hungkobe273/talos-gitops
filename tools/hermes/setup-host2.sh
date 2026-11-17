#!/bin/sh
# Hermes Agent on host2, step 2 (17/11/2026): config + read-only kubeconfig for user "hermes".
# Step 1 (install) was: sudo -u hermes -H bash install.sh --non-interactive --skip-browser --skip-computer-use
# Usage on host2 (as ngochung): cd ~/talos-gitops && git pull -q --rebase && sudo sh tools/hermes/setup-host2.sh
# Safe to re-run. Prints no token or key.
# Design: docs/de-xuat-hermes-agent.md (answers 1A 2A 3A: free OpenRouter, read-only, CLI only).
set -eu
H=hermes
HH=/home/hermes
run() { sudo -u "$H" -H env PATH="$HH/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"; }

# 1. Skills come from the hermes user's own read-only clone (ngochung's home is 750).
run git -C "$HH/talos-gitops" pull -q --ff-only

# 2. Model, approvals, skills, telemetry off.
run hermes config set model.provider openrouter
run hermes config set model.default 'nvidia/nemotron-3-ultra-550b-a55b:free'
run hermes config set approvals.mode manual
run hermes config set skills.external_dirs '["~/talos-gitops/tools/hermes-skills"]'
run hermes config set telemetry.shared_metrics.enabled false
run hermes config set telemetry.shared_metrics.send false
# Keep terminal, file, skills, todo, memory, session_search, clarify. The rest is not needed for
# cluster checks and would send more data or spend more requests.
run hermes tools disable web browser code_execution vision image_gen tts cronjob computer_use \
  delegation connections

# 3. kubeconfig from ServiceAccount hermes/hermes-readonly (ClusterRole without Secret/ConfigMap/exec/write).
#    Token and CA go straight into the file (0600, owner hermes); nothing is printed.
#    Hermes' built-in write denylist covers ~/.kube, so the agent cannot change this file.
ADMIN=/home/ngochung/talos-kvm/kubeconfig
install -d -m 700 -o "$H" -g "$H" "$HH/.kube"
chown "$H:$H" "$HH/.kube"; chmod 700 "$HH/.kube"   # existed as root:root 755 since 16/11
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
KUBECONFIG=$ADMIN kubectl -n hermes get secret hermes-readonly-token -o jsonpath='{.data.ca\.crt}' | base64 -d > "$tmp/ca.crt"
token=$(KUBECONFIG=$ADMIN kubectl -n hermes get secret hermes-readonly-token -o jsonpath='{.data.token}' | base64 -d)
[ -n "$token" ] || { echo "empty token in hermes/hermes-readonly-token" >&2; exit 1; }
# Written with printf (shell builtin): the token never appears in a process argument list.
K="$tmp/config"
umask 077
ca=$(base64 -w0 < "$tmp/ca.crt")
printf 'apiVersion: v1\nkind: Config\nclusters:\n- name: talos-kvm\n  cluster:\n    server: https://10.10.10.100:6443\n    certificate-authority-data: %s\nusers:\n- name: hermes-readonly\n  user:\n    token: %s\ncontexts:\n- name: hermes\n  context:\n    cluster: talos-kvm\n    user: hermes-readonly\ncurrent-context: hermes\n' "$ca" "$token" > "$K"
unset token
install -m 600 -o "$H" -g "$H" "$K" "$HH/.kube/config"

# 4. Checks (as hermes).
echo "can-i get pods:       $(run kubectl auth can-i get pods -A || true)"
echo "can-i get secrets:    $(run kubectl auth can-i get secrets -A || true)"
echo "can-i delete pods:    $(run kubectl auth can-i delete pods -A || true)"
echo "can-i create pods/exec: $(run kubectl auth can-i create pods/exec -A || true)"
echo "model: $(run hermes config get model.default) via $(run hermes config get model.provider)"
echo "approvals: $(run hermes config get approvals.mode); metrics: $(run hermes config get telemetry.shared_metrics.enabled)/$(run hermes config get telemetry.shared_metrics.send)"
echo "OPENROUTER_API_KEY set: $(run sh -c 'grep -c "^OPENROUTER_API_KEY=..*" ~/.hermes/.env || true')"
run sh -c 'cd ~ && sh ~/talos-gitops/tools/hermes-skills/devops/talos-cluster-health/scripts/cluster-health.sh | tail -4' || true
