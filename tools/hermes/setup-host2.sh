#!/bin/sh
# Hermes Agent on host2, step 2 (17/11/2026): config + read-only kubeconfig for user "hermes".
# Step 1 (install) was: sudo -u hermes -H bash install.sh --non-interactive --skip-browser --skip-computer-use
# Usage on host2 (as ngochung): cd ~/talos-gitops && git pull -q --rebase && sudo sh tools/hermes/setup-host2.sh
# Later skill updates only: sudo git -C /opt/talos-gitops pull -q --ff-only
# Safe to re-run. Prints no token or key.
# Design: docs/de-xuat-hermes-agent.md (answers 1A 2A 3A: free OpenRouter, read-only, CLI only).
set -eu
H=hermes
HH=/home/hermes
SRC=/opt/talos-gitops                       # skills + hook source, root-owned, read-only for hermes
REPO=https://github.com/hungkobe273/talos-gitops.git
LOCKED="$HH/.hermes/config.yaml $HH/.hermes/shell-hooks-allowlist.json $HH/.hermes/SOUL.md"
run() { sudo -u "$H" -H env PATH="$HH/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"; }

# 0. (20/11) Unlock the files step 5 locks, so `hermes config set` below can write.
for f in $LOCKED; do if [ -e "$f" ]; then chattr -i "$f"; fi; done

# 1. (20/11) Skills and the hook come from a root-owned clone the agent cannot change. Before, the
#    clone was ~hermes/talos-gitops: the agent could edit a skill script (e.g. drop the redaction)
#    or the hook source, and root installed that hook on the next run (independent review 20/11).
if [ -d "$SRC/.git" ]; then
  git -C "$SRC" pull -q --ff-only
else
  git clone -q "$REPO" "$SRC"
fi
[ -z "$(git -C "$SRC" status --porcelain)" ] || { echo "$SRC has local changes, refusing" >&2; exit 1; }
chown -R root:root "$SRC"; chmod -R u+rwX,go+rX,go-w "$SRC"
# The old hermes-owned clone is no longer used; keep it aside instead of deleting it.
if [ -d "$HH/talos-gitops" ]; then
  mv "$HH/talos-gitops" "$HH/talos-gitops.old-$(date +%Y%m%d)"
  echo "moved old clone to $HH/talos-gitops.old-$(date +%Y%m%d) (not used any more)"
fi

# 2. Model, approvals, skills, telemetry off.
run hermes config set model.provider openrouter
run hermes config set model.default 'nvidia/nemotron-3-ultra-550b-a55b:free'
run hermes config set approvals.mode manual
run hermes config set skills.external_dirs '["/opt/talos-gitops/tools/hermes-skills"]'
run hermes config set telemetry.shared_metrics.enabled false
run hermes config set telemetry.shared_metrics.send false
# (27/11) Telegram group: answer only when tagged or replied to. The bot is a group admin (it must
# see mentions, Telegram privacy mode only passes /commands), so without this it would answer every
# message in the group and burn the 50 free requests a day.
run hermes config set telegram.require_mention true
# Keep terminal, file, skills, todo, memory, session_search, clarify. The rest is not needed for
# cluster checks and would send more data or spend more requests.
# (27/11) Toolsets are per platform: the Telegram gateway had all of them on (web, browser,
# code_execution, cronjob...) while only cli was locked down. Same set for both.
for p in cli telegram; do
  run hermes tools disable --platform "$p" web browser code_execution vision image_gen tts cronjob \
    computer_use delegation connections
done

# 2b. (18/11) Policy hook: block package installs and sudo/su before any terminal command runs.
#     approvals.mode manual does not ask for pip/apt/sudo. Root-owned copy so the agent cannot edit
#     it; fail_closed so a broken hook blocks instead of allowing. First launch asks once for
#     consent (shell hooks are opt-in); answer yes. Blocks are logged to ~/.hermes/logs/policy-blocks.log.
install -d -m 755 -o root -g root /usr/local/lib/hermes-hooks
install -m 755 -o root -g root "$SRC/tools/hermes/hooks/block-installs.sh" /usr/local/lib/hermes-hooks/block-installs.sh
# (20/11) The file tools too: they may not read credential files, write Hermes config or the skills.
# Consent is stored per (event, command), so a new matcher does not ask again.
# Leaf key: once the hooks section exists (since 18/11), `config set hooks` refuses to replace it.
run hermes config set hooks.pre_tool_call '[{"matcher":"terminal|process|execute_code|read_file|write_file|patch|search_files","command":"/usr/local/lib/hermes-hooks/block-installs.sh","timeout":10,"fail_closed":true}]'

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

# 3b. (27/11) Persona: default text plus what this deployment can and cannot do. Asked "what can you
#     do" over Telegram, the model listed web, email and browser work. Locked in step 4.
install -m 600 -o "$H" -g "$H" "$SRC/tools/hermes/SOUL.md" "$HH/.hermes/SOUL.md"

# 4. (20/11) Lock Hermes config and the hook consent list. ~/.hermes is the agent's own directory, so
#    a root-owned file there could still be renamed or replaced; the immutable flag stops that too.
#    Hermes only reads config.yaml at runtime (unchanged since 18/11 across many sessions).
for f in $LOCKED; do if [ -e "$f" ]; then chattr +i "$f"; fi; done

# 5. Checks (as hermes).
echo "can-i get pods:       $(run kubectl auth can-i get pods -A || true)"
echo "can-i get secrets:    $(run kubectl auth can-i get secrets -A || true)"
echo "can-i delete pods:    $(run kubectl auth can-i delete pods -A || true)"
echo "can-i create pods/exec: $(run kubectl auth can-i create pods/exec -A || true)"
echo "model: $(run hermes config get model.default) via $(run hermes config get model.provider)"
echo "approvals: $(run hermes config get approvals.mode); metrics: $(run hermes config get telemetry.shared_metrics.enabled)/$(run hermes config get telemetry.shared_metrics.send)"
echo "policy hook pip blocked (expect rc=2): $(printf '{"tool_name":"terminal","tool_input":{"command":"pip install x"}}' | run /usr/local/lib/hermes-hooks/block-installs.sh >/dev/null 2>&1 && echo rc=0 || echo rc=$?)"
run hermes hooks list 2>&1 | grep -E 'block-installs' || echo "policy hook NOT configured"
echo "OPENROUTER_API_KEY set: $(run sh -c 'grep -c "^OPENROUTER_API_KEY=..*" ~/.hermes/.env || true')"
echo "skills dir: $(run hermes config get skills.external_dirs); clone $(git -C "$SRC" log --oneline -1)"
echo "immutable flag (expect ----i---- on all):"; lsattr $LOCKED
for p in cli telegram; do echo "toolsets on ($p, expect 7): $(run hermes tools list --platform $p | grep -c '✓ enabled')"; done
echo "own script blocked (expect rc=2): $(printf '{"tool_name":"terminal","tool_input":{"command":"bash /tmp/x.sh"}}' | run /usr/local/lib/hermes-hooks/block-installs.sh >/dev/null 2>&1 && echo rc=0 || echo rc=$?)"
echo "skill run allowed (expect rc=0): $(printf '{"tool_name":"terminal","tool_input":{"command":"bash scripts/cluster-health.sh"}}' | run /usr/local/lib/hermes-hooks/block-installs.sh >/dev/null 2>&1 && echo rc=0 || echo rc=$?)"
run bash -c "cd $SRC/tools/hermes-skills/devops/talos-cluster-health && bash scripts/cluster-health.sh | head -1" || true
