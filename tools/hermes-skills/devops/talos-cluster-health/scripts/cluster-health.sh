#!/usr/bin/env bash
# Compact health report of the talos-kvm cluster for an LLM agent (or a human), at most ~30 lines.
# Read-only: only `kubectl get`. Prints names, states and reasons; never Secret data, never event messages.
# Exit: 0 all green, 1 something to look at, 2 API unreachable.
# KUBECONFIG must point at the hermes-readonly kubeconfig (platform/hermes) or any read-only one.
set -uo pipefail
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

get() { kubectl get "$@" -o json --request-timeout=20s 2>/dev/null; }
if ! get nodes >"$TMP/nodes.json"; then echo "API: UNREACHABLE (kubectl get nodes failed)"; exit 2; fi
# A failed list must never look like an empty, healthy one: remember which source failed.
fetch() { local f=$1; shift; get "$@" >"$TMP/$f.json" || { echo '{"items":[]}' >"$TMP/$f.json"; echo "$f" >>"$TMP/failed"; }; }
fetch pods pods -A
fetch apps applications.argoproj.io -n argocd
fetch vols volumes.longhorn.io -n longhorn-system
fetch es externalsecrets.external-secrets.io -A
fetch ev events -A --field-selector type=Warning

# System python on purpose: inside Hermes, `python3` on PATH is Hermes' own venv.
PY=/usr/bin/python3; [ -x "$PY" ] || PY=python3
"$PY" - "$TMP" <<'PY'
import json, sys, os, datetime as dt
d = sys.argv[1]
L = lambda n: json.load(open(os.path.join(d, n)))["items"]
now = dt.datetime.now(dt.timezone.utc)
def ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None
bad = 0
out = []
try:
    failed = set(open(os.path.join(d, "failed")).read().split())
except OSError:
    failed = set()
def unknown(label, src):
    """A source whose kubectl call failed: say so and count it, never report it as empty."""
    global bad
    if src in failed:
        out.append(f"{label}: UNKNOWN (kubectl get failed or timed out)")
        bad += 1
        return True
    return False

nodes = L("nodes.json")
nr = [n["metadata"]["name"] for n in nodes
      if not any(c["type"] == "Ready" and c["status"] == "True" for c in n["status"].get("conditions", []))]
ver = sorted({n["status"]["nodeInfo"]["kubeletVersion"] for n in nodes})
out.append(f"NODES: {len(nodes)-len(nr)}/{len(nodes)} Ready, kubelet {','.join(ver)}" + (f"; NOT READY: {', '.join(nr)}" if nr else ""))
bad += bool(nr)
# Ready time of each node. Restarts that finished before both the control plane and the pod's own node
# had been Ready for SETTLE seconds belong to the cold start (containers crash while the API or the
# network is not up yet) and are reported apart instead of counted.
SETTLE = 600
rdy = {n["metadata"]["name"]: ts(next((c.get("lastTransitionTime") for c in n["status"].get("conditions", [])
                                       if c["type"] == "Ready" and c["status"] == "True"), None)) for n in nodes}
cpn = [n["metadata"]["name"] for n in nodes if "node-role.kubernetes.io/control-plane" in n["metadata"].get("labels", {})]
cpr = max((rdy[n] for n in cpn if rdy.get(n)), default=None)
cold = bool(cpr and (now - cpr).total_seconds() < 7200)
if cold:
    out.append(f"COLD START: control plane Ready since {cpr.astimezone().strftime('%H:%M')} ({int((now - cpr).total_seconds() // 60)} min ago)")
# A node that became Ready long after the control plane rebooted on its own (or was restarted by hand).
# w3 is started by a GCP schedule and may join late, so it is only a note.
late_nodes = []
for nm, t in rdy.items():
    if t and cpr and nm not in cpn and (now - t).total_seconds() < 7200 and (t - cpr).total_seconds() > 1800:
        late_nodes.append(nm)
        if nm == "w3":
            out.append(f"NOTE: w3 Ready since {t.astimezone().strftime('%H:%M')}, later than the cold start (started late by hand or by GCP)")
        else:
            out.append(f"NODE REBOOT: {nm} Ready since {t.astimezone().strftime('%H:%M')}, long after the control plane (rebooted?)")
            bad += 1

apps = L("apps.json")
ab = [f'{a["metadata"]["name"]}({a.get("status",{}).get("sync",{}).get("status","?")}/{a.get("status",{}).get("health",{}).get("status","?")})'
      for a in apps if a.get("status",{}).get("sync",{}).get("status") != "Synced"
      or a.get("status",{}).get("health",{}).get("status") != "Healthy"]
if not unknown("ARGOCD", "apps"):
    out.append(f"ARGOCD: {len(apps)-len(ab)}/{len(apps)} Synced+Healthy" + (f"; {', '.join(ab[:8])}" if ab else ""))
    bad += bool(ab)

vols = L("vols.json")
vb = [f'{v["metadata"]["name"][:20]}({(v.get("status") or {}).get("state","?")}/{(v.get("status") or {}).get("robustness","?")})'
      for v in vols if (v.get("status") or {}).get("robustness") not in ("healthy",)
      and not ((v.get("status") or {}).get("state") == "detached")]
if not unknown("LONGHORN", "vols"):
    out.append(f"LONGHORN: {len(vols)} volumes, {len(vols)-len(vb)} ok" + (f"; {', '.join(vb)}" if vb else ""))
    bad += bool(vb)

pods = L("pods.json")
pb, rs, left, boot = [], [], 0, 0
for p in pods:
    ns, name = p["metadata"]["namespace"], p["metadata"]["name"]
    ph = p["status"].get("phase")
    cs = p["status"].get("containerStatuses", []) or []
    # Pods failed by the kubelet (node shutdown or eviction) stay as Failed until garbage-collected;
    # their controller already made a replacement, which is checked on its own.
    if ph == "Failed" and any(c["type"] == "DisruptionTarget" and c["status"] == "True"
                              for c in p["status"].get("conditions", [])):
        left += 1
        continue
    waiting = [c["state"]["waiting"].get("reason", "") for c in cs if "waiting" in c.get("state", {})]
    notready = ph == "Running" and any(not c.get("ready") for c in cs)
    if ph not in ("Running", "Succeeded") or waiting or notready:
        why = waiting[0] if waiting else (ph if ph != "Running" else "NotReady")
        pb.append(f"{ns}/{name}({why})")
    for c in cs:
        fin = ts(c.get("lastState", {}).get("terminated", {}).get("finishedAt"))
        if fin and (now - fin).total_seconds() < 3600:
            # Excused only during the morning cold start, only right after the node came up,
            # never on a node that came up much later, and never an OOM kill.
            nn = p["spec"].get("nodeName")
            nrdy = [t for t in (cpr, rdy.get(nn)) if t]
            reason = c["lastState"]["terminated"].get("reason", "")
            if (cold and nn not in late_nodes and nrdy and reason != "OOMKilled"
                    and (fin - max(nrdy)).total_seconds() < SETTLE):
                boot += 1
                continue
            rs.append(f'{ns}/{name}:{c["name"]} x{c.get("restartCount",0)} ({c["lastState"]["terminated"].get("reason","?")})')
vault = [p for p in pods if p["metadata"]["namespace"] == "vault" and p["metadata"]["name"].startswith("vault-")
         and not p["metadata"]["name"].startswith("vault-agent")]
vr = all(all(c.get("ready") for c in (p["status"].get("containerStatuses") or [{}])) for p in vault) if vault else False
if unknown("PODS (and VAULT, RESTARTS, W3 PREFERRED)", "pods"):
    pods = []
else:
  out.append(f"VAULT: {'Ready (unsealed)' if vr else 'NOT READY (sealed, down or missing)'}")
  bad += not vr
  out.append(f"PODS: {len(pods)} total, {len(pb)} not healthy" + (f"; {', '.join(pb[:8])}" + (" ..." if len(pb) > 8 else "") if pb else "")
           + (f"; {left} old Failed left by node shutdown/eviction (replaced, harmless)" if left else ""))
  bad += bool(pb)
  out.append(f"RESTARTS (last 1h): {len(rs)}" + (f"; {', '.join(rs[:6])}" if rs else "")
             + (f"; {boot} more during the cold start (right after the nodes came up, expected)" if boot else ""))
  bad += bool(rs)

# Workloads that prefer w3 (preferred nodeAffinity on hostname w3) but have no pod there.
# descheduler-w3 moves them back hourly at :45 (08:45-16:45 Mon-Fri), so only count it as a problem
# when a pod has been off w3 for more than 75 min since both w3 became Ready and the pod was created.
w3 = next((n for n in nodes if n["metadata"]["name"] == "w3"), None)
w3c = next((c for c in (w3 or {}).get("status", {}).get("conditions", []) if c["type"] == "Ready"), {})
if "pods" in failed:
    pass
elif not w3 or w3c.get("status") != "True":
    out.append("W3 PREFERRED: w3 not Ready, skipped")
else:
    w3since = ts(w3c.get("lastTransitionTime"))
    grp = {}
    for p in pods:
        if p["status"].get("phase") != "Running":
            continue
        pref = json.dumps(((p["spec"].get("affinity") or {}).get("nodeAffinity") or {})
                          .get("preferredDuringSchedulingIgnoredDuringExecution") or [])
        if '"w3"' not in pref:
            continue
        o = (p["metadata"].get("ownerReferences") or [{}])[0]
        if o.get("kind") == "Job":
            continue
        k = (p["metadata"]["namespace"], o.get("name", p["metadata"]["name"]))
        grp.setdefault(k, []).append(p)
    off, late = [], 0
    for (ns, owner), ps in sorted(grp.items()):
        if any(p["spec"].get("nodeName") == "w3" for p in ps):
            continue
        age = min((now - max(w3since, ts(p["metadata"]["creationTimestamp"]))).total_seconds() for p in ps)
        name = owner.rsplit("-", 1)[0] if ps[0]["metadata"].get("labels", {}).get("pod-template-hash") else owner
        off.append(f"{ns}/{name} {int(age // 60)}m")
        late += age > 4500
    out.append(f"W3 PREFERRED: {len(grp)-len(off)}/{len(grp)} on w3" + (f"; off w3: {', '.join(off[:6])}" if off else "")
               + ("; descheduler-w3 did not move them (runs :45)" if late else ""))
    bad += bool(late)

es = L("es.json")
eb = [f'{e["metadata"]["namespace"]}/{e["metadata"]["name"]}' for e in es
      if not any(c["type"] == "Ready" and c["status"] == "True" for c in e.get("status", {}).get("conditions", []))]
if not unknown("EXTERNALSECRETS", "es"):
    out.append(f"EXTERNALSECRETS: {len(es)-len(eb)}/{len(es)} Ready" + (f"; NOT READY: {', '.join(eb)}" if eb else ""))
    bad += bool(eb)

cnt = {}
for e in L("ev.json"):
    t = ts(e.get("lastTimestamp") or e.get("eventTime") or e["metadata"].get("creationTimestamp"))
    if t and (now - t).total_seconds() < 1800:
        k = f'{e.get("reason","?")} {e["involvedObject"].get("kind","")}/{e["involvedObject"].get("namespace","")}/{e["involvedObject"].get("name","")}'
        cnt[k] = cnt.get(k, 0) + e.get("count", 1) or 1
top = sorted(cnt.items(), key=lambda x: -x[1])[:5]
if "ev" in failed:
    out.append("WARNING EVENTS: UNKNOWN (kubectl get failed)")
else:
    out.append(f"WARNING EVENTS (last 30m): {sum(cnt.values())}" + (f"; top: {'; '.join(f'{k} x{v}' for k, v in top)}" if top else ""))

print(f"CLUSTER HEALTH {now.astimezone().strftime('%Y-%m-%d %H:%M')}: {'GREEN' if not bad else 'CHECK ' + str(bad) + ' item(s)'}")
print("\n".join(out))
sys.exit(1 if bad else 0)
PY
