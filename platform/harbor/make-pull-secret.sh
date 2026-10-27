#!/bin/sh
# Creates Harbor robot account "talos+demo-pull" (pull only, project talos, no expiry) and
# prints a SealedSecret demo/harbor-pull (kubernetes.io/dockerconfigjson) on stdout:
#   sh platform/harbor/make-pull-secret.sh > apps/demo-app/harbor-pull-sealed.yaml
# The robot secret is only in the API response, piped straight into kubeseal. Harbor shows
# it once; re-running deletes and recreates the robot (old secret stops working).
set -eu
export KUBECONFIG="$HOME/talos-kvm/kubeconfig"
PORT=18094
kubectl -n harbor port-forward svc/harbor-core "$PORT:80" </dev/null >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
sleep 3
API="http://127.0.0.1:$PORT/api/v2.0"
hc() { printf 'user = "admin:%s"\n' "$(cat "$HOME/talos-kvm/harbor-admin-password.txt")" | curl -sS -K - -H 'Content-Type: application/json' "$@"; }

OLD=$(hc "$API/robots?q=name%3D~demo-pull" | python3 -c 'import json,sys;print(" ".join(str(r["id"]) for r in json.load(sys.stdin) if r["name"].endswith("demo-pull")))')
for id in $OLD; do hc -X DELETE "$API/robots/$id" -o /dev/null -w "deleted old robot $id: %{http_code}\n" >&2; done

hc -X POST "$API/robots" -d '{"name":"demo-pull","description":"cluster pulls talos/* (demo-app)","duration":-1,"level":"project","permissions":[{"kind":"project","namespace":"talos","access":[{"resource":"repository","action":"pull"}]}]}' \
| python3 -c '
import json,sys,base64
r=json.load(sys.stdin)
if "secret" not in r: sys.exit("robot not created: %s" % r)
auth=base64.b64encode(("%s:%s" % (r["name"], r["secret"])).encode()).decode()
print(json.dumps({"auths":{"harbor.talos.internal":{"username":r["name"],"password":r["secret"],"auth":auth}}}))' \
| kubectl create secret generic harbor-pull -n demo --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson=/dev/stdin --dry-run=client -o yaml \
| kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system --format yaml
