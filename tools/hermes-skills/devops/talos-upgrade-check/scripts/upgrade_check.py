#!/usr/bin/env python3
"""Before/after check for a Talos or Kubernetes upgrade of the talos-kvm cluster. Read-only (kubectl get).

Usage: upgrade_check.py pre  [node-name-or-ip]
       upgrade_check.py post [node-name-or-ip] [--expect vX.Y.Z]

pre : GO / NO-GO. Nodes Ready and not cordoned, Longhorn healthy, every Longhorn volume keeps a running
      replica off the node, PodDisruptionBudgets that would block the drain (known Longhorn cases are
      labelled), stuck pods, Argo CD apps, what will be down while the node reboots (local PV, single
      replica), and the Talos-side plan command a human runs (talosctl needs talosconfig, which this
      read-only account does not have, on purpose).
post: OK / CHECK. Same health checks, the node's Talos version against --expect, workloads that prefer
      w3 but have no pod there any more (they piled onto w1/w2 during the drain), recent restarts/warnings.
At most ~35 lines. Exit: 0 GO/OK, 1 NO-GO/CHECK, 2 usage or API unreachable.
"""
import collections
import datetime as dt
import json
import re
import subprocess
import sys

UPGRADE_SCRIPT = "~/bin/talos-upgrade-node.sh"   # on host2, user ngochung


def kget(*args):
    r = subprocess.run(["kubectl", "--request-timeout=20s", "get", *args, "-o", "json"],
                       capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        return None
    return json.loads(r.stdout).get("items", [])


def usage():
    print("usage: upgrade-check.sh pre|post [node-name-or-ip] [--expect vX.Y.Z]")
    sys.exit(2)


args = sys.argv[1:]
if not args or args[0] not in ("pre", "post"):
    usage()
mode, expect, target_arg = args[0], None, None
rest = args[1:]
while rest:
    a = rest.pop(0)
    if a == "--expect" and rest:
        expect = rest.pop(0)
    elif re.fullmatch(r"[a-z0-9.-]+", a) and target_arg is None:
        target_arg = a
    else:
        usage()
if expect and not re.fullmatch(r"v\d+\.\d+\.\d+", expect):
    usage()

nodes = kget("nodes")
if nodes is None:
    print("API: UNREACHABLE")
    sys.exit(2)
pods = kget("pods", "-A") or []
pdbs = kget("pdb", "-A") or []
vols = kget("volumes.longhorn.io", "-n", "longhorn-system") or []
reps = kget("replicas.longhorn.io", "-n", "longhorn-system") or []
engs = kget("engines.longhorn.io", "-n", "longhorn-system") or []
apps = kget("applications.argoproj.io", "-n", "argocd") or []
pvs = kget("pv") or []
rss = kget("replicasets", "-A") or []
now = dt.datetime.now(dt.timezone.utc)


def ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


# ---------------------------------------------------------------- nodes
def ip_of(n):
    return next((a["address"] for a in n["status"].get("addresses", []) if a["type"] == "InternalIP"), "?")


def ready(n):
    return any(c["type"] == "Ready" and c["status"] == "True" for c in n["status"].get("conditions", []))


byname = {n["metadata"]["name"]: n for n in nodes}


def ready_since(n):
    return ts(next((c.get("lastTransitionTime") for c in n["status"].get("conditions", [])
                    if c["type"] == "Ready" and c["status"] == "True"), None))


# A container that ended within SETTLE seconds after the control plane or its own node became Ready
# belongs to that boot (reboot after an upgrade, or the morning cold start), not to a new fault.
SETTLE = 600
rdy = {nm: ready_since(n) for nm, n in byname.items()}
cpr = max((rdy[nm] for nm, n in byname.items() if rdy.get(nm)
           and "node-role.kubernetes.io/control-plane" in n["metadata"].get("labels", {})), default=None)


def boot_of(p):
    """Latest Ready time that matters for this pod: control plane or the pod's node."""
    t = [x for x in (cpr, rdy.get(p["spec"].get("nodeName"))) if x]
    return max(t) if t else None
SHORT = {"cp1": "10.10.10.11", "w1": "10.10.10.21", "w2": "10.10.10.22"}   # w3 is the real node name
target = None
if target_arg:
    want = SHORT.get(target_arg, target_arg)
    target = next((n for n in nodes if want in (n["metadata"]["name"], ip_of(n))), None)
    if target is None:
        print("NODE: no node named or with IP '%s' (short names: cp1 w1 w2 w3)" % target_arg)
        sys.exit(2)
tname = target["metadata"]["name"] if target else None

items, notes, lines = [], [], []

vers = collections.Counter()
for n in nodes:
    nm = n["metadata"]["name"]
    os_img = n["status"]["nodeInfo"].get("osImage", "")
    m = re.search(r"\((v[\d.]+[^)]*)\)", os_img)
    vers[(m.group(1) if m else os_img, n["status"]["nodeInfo"]["kubeletVersion"])] += 1
    if not ready(n):
        items.append("node %s not Ready" % nm)
    if n["spec"].get("unschedulable"):
        items.append("node %s is cordoned (kubectl uncordon %s, by a human)" % (nm, nm))
lines.append("NODES: %d, versions %s" % (len(nodes), ", ".join(
    "Talos %s / k8s %s x%d" % (t, k, c) for (t, k), c in sorted(vers.items()))))
if target:
    ti = target["status"]["nodeInfo"]
    cp = "node-role.kubernetes.io/control-plane" in target["metadata"].get("labels", {})
    lines.append("TARGET: %s (%s) %s, kubelet %s, control-plane=%s" % (
        tname, ip_of(target), ti.get("osImage"), ti["kubeletVersion"], "yes" if cp else "no"))
    if mode == "post" and rdy.get(tname):
        lines.append("TARGET READY since %s (%d min ago)" % (
            rdy[tname].astimezone().strftime("%H:%M"), (now - rdy[tname]).total_seconds() // 60))
    if mode == "post" and expect and "(%s)" % expect not in ti.get("osImage", ""):
        items.append("%s runs %s, expected Talos %s" % (tname, ti.get("osImage"), expect))
    if mode == "pre" and cp:
        notes.append("control plane: the only one (cp2/cp3 are off) -> Kubernetes API is down while it reboots, "
                     "a few minutes; the upgrade script takes an etcd snapshot first")

# ---------------------------------------------------------------- Longhorn
rob = collections.Counter(v.get("status", {}).get("robustness", "unknown") for v in vols)
lines.append("LONGHORN: %d volumes %s" % (len(vols), dict(rob)))
for v in vols:
    r = v.get("status", {}).get("robustness")
    st = v.get("status", {}).get("state")
    if r != "healthy" and not (r == "unknown" and st == "detached"):
        items.append("Longhorn volume %s robustness=%s state=%s%s" % (
            v["metadata"]["name"], r, st, " (rebuilding after the node came back? wait and re-run)" if mode == "post" and r == "degraded" else ""))
if target and mode == "pre":
    by_vol = collections.defaultdict(list)
    for r in reps:
        by_vol[r["spec"].get("volumeName")].append((r["spec"].get("nodeID"), r.get("status", {}).get("currentState")))
    for v in vols:
        vn = v["metadata"]["name"]
        others = [n for n, s in by_vol.get(vn, []) if s == "running" and n != tname]
        if v.get("status", {}).get("state") == "attached" and not others:
            items.append("Longhorn volume %s has no running replica outside %s" % (vn, tname))
    att = [e["spec"].get("volumeName") for e in engs if e["spec"].get("nodeID") == tname]
    if att:
        notes.append("Longhorn volumes attached on %s (detach/re-attach during the reboot): %s" % (tname, ", ".join(att)))

# ---------------------------------------------------------------- pods
pod_node = {}
STUCK_WAIT = ("CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "CreateContainerConfigError",
              "CreateContainerError", "ContainerCreating", "PodInitializing", "InvalidImageName")
stuck = []
for p in pods:
    ns, nm = p["metadata"]["namespace"], p["metadata"]["name"]
    st = p.get("status", {})
    pod_node[(ns, nm)] = p["spec"].get("nodeName")
    phase = st.get("phase")
    if phase in ("Succeeded", "Failed"):
        continue
    why = None
    if p["metadata"].get("deletionTimestamp"):
        age = (now - ts(p["metadata"]["deletionTimestamp"])).total_seconds()
        if age > 120:
            why = "Terminating %dm" % (age // 60)
    elif phase == "Pending":
        why = "Pending"
    else:
        for c in (st.get("initContainerStatuses") or []) + (st.get("containerStatuses") or []):
            w = (c.get("state") or {}).get("waiting") or {}
            if w.get("reason") in STUCK_WAIT:
                why = w["reason"]
                break
        if not why and phase == "Running":
            cs = st.get("containerStatuses") or []
            started = max([x for x in (ts(st.get("startTime")), boot_of(p)) if x], default=None)
            if cs and not all(c.get("ready") for c in cs) and started and (now - started).total_seconds() > 600:
                why = "Running but not Ready > 10m"
    if why:
        stuck.append("%s/%s (%s, node %s)" % (ns, nm, why, p["spec"].get("nodeName") or "-"))
if stuck:
    items.append("%d stuck pod(s): %s" % (len(stuck), "; ".join(stuck[:5]) + (" ..." if len(stuck) > 5 else "")))
lines.append("PODS: %d, stuck %d" % (len(pods), len(stuck)))

# ---------------------------------------------------------------- PDB
KNOWN_PDB = [(r"^csi-(attacher|provisioner)$", "handled: the upgrade script deletes these CSI pods on the node first"),
             (r"^instance-manager-", "known: always 0 in a dry run; Longhorn removes it on a real cordon (13/11)")]
blocking = []
for b in pdbs:
    ns, nm = b["metadata"]["namespace"], b["metadata"]["name"]
    st = b.get("status", {})
    if st.get("disruptionsAllowed", 0) > 0 or st.get("expectedPods", 0) == 0:
        continue
    sel = (b["spec"].get("selector") or {}).get("matchLabels") or {}
    covered = [p for p in pods if p["metadata"]["namespace"] == ns and sel
               and all(p["metadata"].get("labels", {}).get(k) == v for k, v in sel.items())]
    on_t = [p for p in covered if p["spec"].get("nodeName") == tname] if target else covered
    if target and not on_t:
        continue
    known = next((txt for rx, txt in KNOWN_PDB if ns == "longhorn-system" and re.search(rx, nm)), None)
    if known:
        notes.append("PDB %s/%s allows 0 disruptions (%s)" % (ns, nm, known))
    else:
        blocking.append("%s/%s" % (ns, nm))
if blocking:
    items.append("PDB allows 0 disruptions and would block the drain: " + ", ".join(blocking))

# ---------------------------------------------------------------- Argo CD
bad_apps = ["%s(%s/%s)" % (a["metadata"]["name"], a.get("status", {}).get("sync", {}).get("status"),
                           a.get("status", {}).get("health", {}).get("status")) for a in apps
            if a.get("status", {}).get("sync", {}).get("status") != "Synced"
            or a.get("status", {}).get("health", {}).get("status") != "Healthy"]
lines.append("ARGO CD: %d apps, not Synced/Healthy %d" % (len(apps), len(bad_apps)))
if bad_apps:
    items.append("Argo CD apps not Synced/Healthy: " + ", ".join(bad_apps[:6]))


# ---------------------------------------------------------------- workloads (owner = Deployment/StatefulSet/...)
rs_owner = {(r["metadata"]["namespace"], r["metadata"]["name"]): (r["metadata"].get("ownerReferences") or [{}])[0]
            for r in rss}


def owner(p):
    o = (p["metadata"].get("ownerReferences") or [{}])[0]
    if o.get("kind") == "ReplicaSet":
        o2 = rs_owner.get((p["metadata"]["namespace"], o.get("name")), {})
        if o2.get("kind"):
            o = o2
    return o.get("kind"), o.get("name")


groups = collections.defaultdict(list)
for p in pods:
    if p.get("status", {}).get("phase") in ("Succeeded", "Failed"):
        continue
    k, n = owner(p)
    if k in ("Deployment", "StatefulSet", "Rollout"):
        groups[(p["metadata"]["namespace"], k, n)].append(p)

if target and mode == "pre":
    local_pv = {(pv["spec"].get("claimRef") or {}).get("namespace", "") + "/" + (pv["spec"].get("claimRef") or {}).get("name", "")
                for pv in pvs
                if tname in json.dumps((pv["spec"].get("nodeAffinity") or {}))}
    down = []
    for (ns, k, n), ps in sorted(groups.items()):
        if all(p["spec"].get("nodeName") == tname for p in ps):
            pinned = any("%s/%s" % (ns, v["persistentVolumeClaim"]["claimName"]) in local_pv
                         for p in ps for v in p["spec"].get("volumes", []) if v.get("persistentVolumeClaim"))
            down.append("%s/%s%s" % (ns, n, " (local PV, stays down until the node is back)" if pinned else ""))
    if down:
        notes.append("down while %s reboots (all replicas there): %s" % (tname, ", ".join(down[:12]) + (" ..." if len(down) > 12 else "")))
    if any(p["metadata"]["namespace"] == "vault" and p["spec"].get("nodeName") == tname for p in pods):
        notes.append("vault-0 is on %s: it restarts and auto-unseals via GCP KMS (needs Internet); "
                     "StatefulSet uses OnDelete" % tname)

if mode == "post":
    w3 = byname.get("w3")
    if w3 is not None and ready(w3) and not w3["spec"].get("unschedulable"):
        late, recent = [], []
        for (ns, k, n), ps in sorted(groups.items()):
            pref = json.dumps(((ps[0]["spec"].get("affinity") or {}).get("nodeAffinity") or {})
                              .get("preferredDuringSchedulingIgnoredDuringExecution") or [])
            if '"w3"' in pref and not any(p["spec"].get("nodeName") == "w3" for p in ps):
                # descheduler-w3 moves them back hourly at :45 (08:45-16:45 Mon-Fri): only late ones count
                age = min((now - max(rdy.get("w3") or now, ts(p["metadata"]["creationTimestamp"]))).total_seconds() for p in ps)
                (late if age > 4500 else recent).append("%s/%s %s %dm" % (ns, k.lower(), n, age // 60))
        if late:
            items.append("prefer w3 but have no pod there for more than 75 min (descheduler-w3 at :45 did not move them): " + ", ".join(late)
                         + ". A human runs kubectl -n <ns> rollout restart <kind>/<name>")
        if recent:
            notes.append("prefer w3, not there yet (descheduler-w3 moves them at :45, or a human runs rollout restart now): " + ", ".join(recent))
    rec, boot = collections.Counter(), collections.Counter()
    for p in pods:
        b = boot_of(p)
        for c in p.get("status", {}).get("containerStatuses") or []:
            fin = ts(((c.get("lastState") or {}).get("terminated") or {}).get("finishedAt"))
            if fin and (now - fin).total_seconds() < 1800:
                (boot if b and (fin - b).total_seconds() < SETTLE else rec)[p["metadata"]["namespace"]] += 1
    if rec:
        notes.append("container restarts in the last 30 min by namespace (after the nodes were up): "
                     + ", ".join("%s %d" % kv for kv in rec.most_common(8)))
    if boot:
        notes.append("container restarts during the node boot (expected, not a problem): "
                     + ", ".join("%s %d" % kv for kv in boot.most_common(8)))

# ---------------------------------------------------------------- output
if mode == "pre":
    print(("NO-GO %d item(s)" % len(items)) if items else "GO (Kubernetes side)")
else:
    print(("CHECK %d item(s)" % len(items)) if items else "OK")
for i in items:
    print("- " + i)
print("\n".join(lines))
for n in notes:
    print("NOTE " + n)
if mode == "pre":
    ip = ip_of(target) if target else "<node-ip>"
    print("TALOS SIDE (human, on host2, prints the plan and changes nothing): %s %s %s"
          % (UPGRADE_SCRIPT, ip, expect or "<vX.Y.Z>"))
sys.exit(1 if items else 0)
