#!/bin/sh
# Idempotent Harbor setup, run on host2:  sh platform/harbor/setup-replication.sh
#  - project "talos" (private)
#  - registry endpoint "ghcr" (GitHub Container Registry, pull credentials taken from the
#    cluster's demo/ghcr-pull secret)
#  - pull replication "ghcr-demo-app": ghcr hungkobe273/talos-demo-app -> talos/talos-demo-app,
#    every 10 minutes, all tags (images and cosign signature artifacts)
#  - pull replication "ghcr-keycloak": ghcr hungkobe273/talos-keycloak -> talos/talos-keycloak, hourly
# Talks to harbor-core through kubectl port-forward; the admin password and the ghcr token
# are read on host2 and only passed in request bodies/headers, never printed.
set -eu
export KUBECONFIG="$HOME/talos-kvm/kubeconfig"
PORT=18090
kubectl -n harbor port-forward svc/harbor-core "$PORT:80" </dev/null >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
sleep 3
API="http://127.0.0.1:$PORT/api/v2.0"
# curl config on stdin keeps the admin password out of argv.
hc() { printf 'user = "admin:%s"\n' "$(cat "$HOME/talos-kvm/harbor-admin-password.txt")" | curl -sS -K - -H 'Content-Type: application/json' "$@"; }

# GHCR credentials from the pull secret already in the cluster.
read -r GH_USER GH_TOKEN <<EOF
$(kubectl -n demo get secret ghcr-pull -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d \
  | python3 -c 'import json,sys,base64;a=json.load(sys.stdin)["auths"]["ghcr.io"];u,p=base64.b64decode(a["auth"]).decode().split(":",1);print(u,p)')
EOF

# 1) project
if [ "$(hc -o /dev/null -w '%{http_code}' -I "$API/projects?project_name=talos")" != 200 ]; then
  hc -X POST "$API/projects" -d '{"project_name":"talos","public":false}' -o /dev/null -w 'project: %{http_code}\n'
else echo "project: exists"; fi

# 2) registry endpoint
RID=$(hc "$API/registries?name=ghcr" | python3 -c 'import json,sys;r=[x for x in json.load(sys.stdin) if x["name"]=="ghcr"];print(r[0]["id"] if r else "")')
if [ -z "$RID" ]; then
  python3 - "$GH_USER" "$GH_TOKEN" <<'PY' > /tmp/harbor-reg.json
import json,sys
print(json.dumps({"name":"ghcr","type":"github-ghcr","url":"https://ghcr.io","insecure":False,
  "credential":{"type":"basic","access_key":sys.argv[1],"access_secret":sys.argv[2]}}))
PY
  chmod 600 /tmp/harbor-reg.json
  hc -X POST "$API/registries" --data @/tmp/harbor-reg.json -o /dev/null -w 'registry: %{http_code}\n'
  rm -f /tmp/harbor-reg.json
  RID=$(hc "$API/registries?name=ghcr" | python3 -c 'import json,sys;print([x for x in json.load(sys.stdin) if x["name"]=="ghcr"][0]["id"])')
else echo "registry: exists ($RID)"; fi
hc -X GET "$API/registries/$RID/info" -o /dev/null -w 'registry reachable: %{http_code}\n'

# 3) pull replication policies: policy <name> <ghcr repo> <cron> <description>
policy() {
  PID=$(hc "$API/replication/policies?name=$1" | python3 -c 'import json,sys;r=[x for x in json.load(sys.stdin) if x["name"]=="'"$1"'"];print(r[0]["id"] if r else "")')
  if [ -z "$PID" ]; then
    cat > /tmp/harbor-pol.json <<JSON
{"name":"$1","description":"$4",
 "src_registry":{"id":$RID},"dest_namespace":"talos","dest_namespace_replace_count":1,
 "filters":[{"type":"name","value":"$2"}],
 "trigger":{"type":"scheduled","trigger_settings":{"cron":"$3"}},
 "override":true,"enabled":true,"speed":-1,"copy_by_chunk":false}
JSON
    hc -X POST "$API/replication/policies" --data @/tmp/harbor-pol.json -o /dev/null -w "policy $1: %{http_code}\n"
    rm -f /tmp/harbor-pol.json
    PID=$(hc "$API/replication/policies?name=$1" | python3 -c 'import json,sys;print([x for x in json.load(sys.stdin) if x["name"]=="'"$1"'"][0]["id"])')
  else echo "policy $1: exists ($PID)"; fi
  # run it once now
  hc -X POST "$API/replication/executions" -d "{\"policy_id\":$PID}" -o /dev/null -w "execution $1 started: %{http_code}\n"
}
policy ghcr-demo-app hungkobe273/talos-demo-app "0 */10 * * * *" "talos-demo-app images + cosign signatures from ghcr"
# Optimized Keycloak image (platform/keycloak/image, built by GitHub Actions). Changes rarely: hourly.
policy ghcr-keycloak hungkobe273/talos-keycloak "0 0 * * * *" "optimized Keycloak image from ghcr"
