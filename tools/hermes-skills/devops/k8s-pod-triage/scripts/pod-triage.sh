#!/usr/bin/env bash
# Triage one pod for an LLM agent (or a human): state, containers, probes, events, last log lines.
# Usage: pod-triage.sh <namespace> <pod name or name prefix, e.g. a Deployment name>
# Read-only: only `kubectl get` and `kubectl logs`. At most ~60 lines.
# Output goes to a cloud LLM, so every line is redacted: company LAN IPs, tokens, passwords,
# JWT/base64 blobs, key=value secrets. Env values and Secret/ConfigMap data are never read.
# Exit: 0 pod looks fine, 1 something to look at, 2 API unreachable or pod not found.
# KUBECONFIG must point at the hermes-readonly kubeconfig (platform/hermes) or any read-only one.
set -uo pipefail
ns=${1:-}; want=${2:-}
if [ -z "$ns" ] || [ -z "$want" ]; then echo "usage: pod-triage.sh <namespace> <pod-or-prefix>"; exit 2; fi
case "$ns$want" in *[!a-z0-9.-]*) echo "invalid namespace or pod name"; exit 2 ;; esac
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
k() { kubectl --request-timeout=20s "$@" 2>/dev/null; }

if ! k get pods -n "$ns" -o json >"$TMP/pods.json"; then echo "API: UNREACHABLE or namespace $ns not readable"; exit 2; fi
pod=$(python3 - "$TMP/pods.json" "$want" <<'PY'
import json, sys
items = json.load(open(sys.argv[1]))["items"]; w = sys.argv[2]
names = [p["metadata"]["name"] for p in items]
if w in names: print(w); sys.exit()
m = [n for n in names if n.startswith(w + "-") or n.startswith(w)]
# Prefer a pod that is not Ready, so "triage <deployment>" lands on the broken replica.
notready = [p["metadata"]["name"] for p in items if p["metadata"]["name"] in m and not all(
    c.get("ready") for c in p.get("status", {}).get("containerStatuses", []) or [{}])]
print((notready or m or [""])[0])
PY
)
if [ -z "$pod" ]; then echo "POD: no pod named or starting with '$want' in namespace $ns"; exit 2; fi

k get events -n "$ns" --field-selector "involvedObject.name=$pod" -o json >"$TMP/ev.json" || echo '{"items":[]}' >"$TMP/ev.json"
python3 - "$TMP/pods.json" "$pod" >"$TMP/containers.txt" <<'PY'
import json, sys, datetime as dt
p = next(x for x in json.load(open(sys.argv[1]))["items"] if x["metadata"]["name"] == sys.argv[2])
now = dt.datetime.now(dt.timezone.utc)
for c in p.get("status", {}).get("containerStatuses", []) or []:
    last = (c.get("lastState") or {}).get("terminated") or {}
    fin = last.get("finishedAt")
    recent = bool(fin) and (now - dt.datetime.fromisoformat(fin.replace("Z", "+00:00"))).total_seconds() < 3600
    # Previous logs only when they can explain a current problem: the cluster is shut down every
    # evening, so every pod has one old restart whose previous log is just the shutdown.
    print(c["name"], "1" if c.get("restartCount", 0) > 0 and (recent or not c.get("ready")) else "0")
PY
# Logs: previous instance for containers that restarted recently or are not ready, otherwise the current one. 30 lines each, max 2 containers.
n=0
while read -r c restarted; do
  n=$((n+1)); [ "$n" -le 2 ] || break
  if [ "$restarted" = 1 ] && k logs -n "$ns" "$pod" -c "$c" --previous --tail=30 >"$TMP/log-$c.txt"; then
    echo previous >"$TMP/logkind-$c.txt"
  else
    k logs -n "$ns" "$pod" -c "$c" --tail=30 >"$TMP/log-$c.txt" || : ; echo current >"$TMP/logkind-$c.txt"
  fi
done <"$TMP/containers.txt"

python3 - "$TMP" "$pod" <<'PY'
import json, sys, os, re, glob, datetime as dt
d, name = sys.argv[1], sys.argv[2]
now = dt.datetime.now(dt.timezone.utc)
def ts(s): return dt.datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None
def ago(s):
    t = ts(s)
    if not t: return "?"
    m = int((now - t).total_seconds() // 60)
    return f"{m}m" if m < 120 else f"{m//60}h" if m < 2880 else f"{m//1440}d"
RED = [
    (re.compile(r"\b192\.168\.\d{1,3}\.\d{1,3}\b"), "<LAN-IP>"),
    (re.compile(r"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"), r"\1 <REDACTED>"),
    (re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}"), "<JWT>"),
    (re.compile(r"(?i)((?:pass(?:word|wd)?|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|credentials?|auth)[\"']?\s*[:=]\s*)[\"']?[^\s\"',;}&]+"), r"\1<REDACTED>"),
    (re.compile(r"\b(sk-[A-Za-z0-9-]{10,}|gh[pousr]_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9_-]{10,}|hvs\.[A-Za-z0-9_-]{10,})"), "<KEY>"),
    (re.compile(r"\b(?=[A-Za-z0-9+/]*[0-9])(?=[A-Za-z0-9+/]*[A-Z])(?=[A-Za-z0-9+/]*[a-z])[A-Za-z0-9+/]{32,}={0,2}"), "<BLOB>"),
    (re.compile(r"-----BEGIN [A-Z ]+-----"), "<PEM>"),
]
def red(s):
    for r, rep in RED: s = r.sub(rep, s)
    return s
def cut(s, n=200):
    s = red(" ".join(str(s).split()))
    return s if len(s) <= n else s[:n] + "..."

p = next(x for x in json.load(open(os.path.join(d, "pods.json")))["items"] if x["metadata"]["name"] == name)
md, sp, st = p["metadata"], p.get("spec", {}), p.get("status", {})
owner = ",".join(f'{o["kind"]}/{o["name"]}' for o in md.get("ownerReferences", [])) or "-"
bad = 0
out = []
out.append(f'POD: {md["namespace"]}/{name} phase={st.get("phase","?")} node={sp.get("nodeName","-")} owner={owner} age={ago(md.get("creationTimestamp"))}')
conds = {c["type"]: c for c in st.get("conditions", [])}
cl = []
for t in ("PodScheduled", "Initialized", "ContainersReady", "Ready"):
    c = conds.get(t)
    if c:
        cl.append(f'{t}={c["status"]}' + (f'({c.get("reason")})' if c["status"] != "True" and c.get("reason") else ""))
        if c["status"] != "True": bad += 1
out.append("CONDITIONS: " + " ".join(cl))
if st.get("reason") or st.get("message"):
    out.append(f'STATUS: {st.get("reason","")} {cut(st.get("message",""))}'); bad += 1

specs = {c["name"]: c for c in sp.get("containers", []) + sp.get("initContainers", [])}
def probe(pr):
    if not pr: return "-"
    kind = "http " + str(pr["httpGet"].get("path", "")) if "httpGet" in pr else "tcp" if "tcpSocket" in pr else "exec" if "exec" in pr else "grpc" if "grpc" in pr else "?"
    return f'{kind} period={pr.get("periodSeconds",10)}s timeout={pr.get("timeoutSeconds",1)}s fail={pr.get("failureThreshold",3)}'
for c in (st.get("initContainerStatuses") or []) + (st.get("containerStatuses") or []):
    s = specs.get(c["name"], {})
    state = next(iter(c.get("state", {})), "?")
    sd = c.get("state", {}).get(state, {})
    line = f'CONTAINER {c["name"]}: ready={c.get("ready")} restarts={c.get("restartCount",0)} state={state}'
    if sd.get("reason"): line += f'({sd["reason"]})'
    if state == "running": line += f' since {ago(sd.get("startedAt"))}'
    out.append(line + f' image={c.get("image","").split("/")[-1]}')
    last = c.get("lastState", {}).get("terminated")
    recent = bool(last) and ts(last.get("finishedAt")) is not None and (now - ts(last["finishedAt"])).total_seconds() < 3600
    if last:
        out.append(f'  LAST TERMINATED: reason={last.get("reason")} exit={last.get("exitCode")} finished {ago(last.get("finishedAt"))} ago{"" if recent else " (old, e.g. evening shutdown)"}' + (f' msg={cut(last.get("message",""),120)}' if last.get("message") else ""))
    r = s.get("resources", {})
    out.append(f'  RESOURCES: req={r.get("requests",{})} lim={r.get("limits",{})}  LIVENESS: {probe(s.get("livenessProbe"))}  READINESS: {probe(s.get("readinessProbe"))}')
    if not c.get("ready") and state != "terminated": bad += 1
    if state == "waiting" or (recent and last.get("reason") in ("OOMKilled", "Error")): bad += 1

ev = json.load(open(os.path.join(d, "ev.json")))["items"]
ev.sort(key=lambda e: e.get("lastTimestamp") or e.get("eventTime") or "", reverse=True)
warn = [e for e in ev if e.get("type") == "Warning"]
out.append(f"EVENTS: {len(ev)} total, {len(warn)} warning (newest first, max 6)")
for e in ev[:6]:
    out.append(f'  {e.get("type")} {e.get("reason")} x{e.get("count",1)} last {ago(e.get("lastTimestamp") or e.get("eventTime"))} ago: {cut(e.get("message",""),160)}')
if warn: bad += 1

for f in sorted(glob.glob(os.path.join(d, "log-*.txt"))):
    c = os.path.basename(f)[4:-4]
    kind = open(os.path.join(d, f"logkind-{c}.txt")).read().strip()
    def compact(l):
        # JSON log lines (Keycloak, Longhorn...): keep time, level, logger, message so the cause is not cut off.
        s = l.strip()
        if s.startswith("{"):
            try:
                j = json.loads(s)
                g = lambda *ks: next((str(j[k]) for k in ks if k in j and j[k] not in (None, "")), "")
                return " ".join(x for x in (g("timestamp", "time", "ts", "@timestamp")[:19], g("level", "lvl", "severity"),
                    g("loggerName", "logger", "caller", "func").split(".")[-1], g("message", "msg"), g("error", "err")) if x)
            except ValueError:
                pass
        return s
    lines = [compact(l) for l in open(f, errors="replace").read().splitlines() if l.strip()]
    # Errors first, then the tail, so the cause is not cut off by the 12-line limit.
    errs = [l for l in lines if re.search(r"(?i)\b(error|fatal|panic|exception|fail(ed|ure)?|denied|refused|timeout|oom)\b", l)]
    pick = (errs[-6:] + [l for l in lines[-12:] if l not in errs[-6:]])[-12:]
    out.append(f"LOGS {c} ({kind}, {len(lines)} lines read, {len(errs)} error-like; showing {len(pick)}):")
    out += ["  " + cut(re.sub(r"(realmId|sequence|loggerClassName)=\"?[^,\"]*\"?,? ?", "", l), 240) for l in pick]

print(f"POD TRIAGE {now.astimezone().strftime('%Y-%m-%d %H:%M')}: " + ("OK" if bad == 0 else f"CHECK ({bad} signal(s))"))
print("\n".join(out))
sys.exit(1 if bad else 0)
PY
