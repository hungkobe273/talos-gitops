#!/usr/bin/env bash
# Cold start recorder (03/11): runs once per host2 boot, for 20 minutes, and logs every change in
#   - API reachability, VMs, node Ready
#   - kube-dns EndpointSlice, CoreDNS pods, keycloak-0 (03/11 question: dbchecker waited 40 s for DNS)
#   - 10/11: pods total/Running/Ready per node (why w2 only creates pod sandboxes at +4:30 although the
#     node is Ready at +3:00), Longhorn volumes, vault-0, Grafana, ClusterSecretStore,
#     host2 I/O scheduler and PSI io every 30 s (first cold start with BFQ, docs/de-xuat-bfq.md)
# At the end it saves dbchecker logs, kube-proxy/CoreDNS/flannel logs, Warning events, and the number of
# slow etcd requests on cp1.
# Reads only; no Secrets are printed.
set -u
DIR="$HOME/talos-kvm/coldstart-logs"
mkdir -p "$DIR"
LOG="$DIR/coldstart-$(date +%Y%m%d-%H%M).log"
K="kubectl --request-timeout=3s"
TALOS="talosctl --talosconfig $HOME/talos-kvm/talosconfig"
END=$(( $(date +%s) + 1200 ))
declare -A prev

log() { echo "$(date +%T) $*" >> "$LOG"; }
changed() {  # key value: log value only when it differs from the previous sample
  if [ "${prev[$1]:-}" != "$2" ]; then prev[$1]="$2"; log "$1: $2"; fi
}

log "host2 up since $(uptime -s), recorder start"
log "sda scheduler: $(cat /sys/block/sda/queue/scheduler 2>/dev/null)"
next_psi=0
while [ "$(date +%s)" -lt "$END" ]; do
  now=$(date +%s)
  if (( now >= next_psi )); then
    log "psi io: $(head -1 /proc/pressure/io)"
    next_psi=$(( now + 30 ))
  fi
  if $K get --raw /readyz >/dev/null 2>&1; then api=up; else api=down; fi
  changed api "$api"
  changed vms "$(virsh -c qemu:///system list --name 2>/dev/null | grep -v '^$' | tr '\n' ' ')"
  if [ "$api" = up ]; then
    changed nodes "$($K get nodes --no-headers 2>/dev/null | awk '{printf "%s=%s ", $1, $2}')"
    # Pods per node: total/Running/Ready (Running lagging behind total = waiting for sandbox or image)
    changed pods-per-node "$($K get pod -A -o jsonpath='{range .items[*]}{.spec.nodeName} {.status.phase} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
      | awk 'NF>=1 && $1!="" {t[$1]++; if ($2=="Running") r[$1]++; if ($3=="True") y[$1]++} END {for (n in t) printf "%s=%d/%d/%d ", n, t[n], r[n], y[n]}')"
    changed kube-dns-eps "$($K -n kube-system get endpointslice -l kubernetes.io/service-name=kube-dns \
      -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}/{.targetRef.name}/ready={.conditions.ready} {end}' 2>/dev/null)"
    changed coredns "$($K -n kube-system get pod -l k8s-app=kube-dns \
      -o jsonpath='{range .items[*]}{.metadata.name}@{.spec.nodeName}/{.status.podIP}/{.status.conditions[?(@.type=="Ready")].status} {end}' 2>/dev/null)"
    changed keycloak "$($K -n keycloak get pod keycloak-0 \
      -o jsonpath='{.spec.nodeName} {.status.phase} init={.status.initContainerStatuses[0].state} ready={.status.containerStatuses[0].ready}' 2>/dev/null | cut -c1-300)"
    changed vault "$($K -n vault get pod vault-0 \
      -o jsonpath='{.spec.nodeName} {.status.phase} ready={.status.containerStatuses[0].ready}' 2>/dev/null)"
    changed grafana "$($K -n monitoring get pod -l app.kubernetes.io/name=grafana \
      -o jsonpath='{range .items[*]}{.spec.nodeName} {.status.phase} ready={.status.conditions[?(@.type=="Ready")].status} {end}' 2>/dev/null)"
    changed longhorn-vols "$($K -n longhorn-system get volumes.longhorn.io \
      -o jsonpath='{range .items[*]}{.status.kubernetesStatus.pvcName}={.status.state}/{.status.robustness}@{.status.currentNodeID} {end}' 2>/dev/null)"
    changed css "$($K get clustersecretstore -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[0].reason} {end}' 2>/dev/null)"
  fi
  sleep 2
done

log "--- dbchecker log (timestamps)"
$K -n keycloak logs keycloak-0 -c dbchecker --timestamps >> "$LOG" 2>&1
for p in $($K -n kube-system get pod -o name 2>/dev/null | grep -E 'kube-proxy|coredns|kube-flannel'); do
  log "--- $p (first 40 lines)"
  $K -n kube-system logs "$p" --timestamps 2>&1 | head -40 | cut -c1-220 >> "$LOG"
done
log "--- Warning events (sandbox, mount, probe), oldest first"
# one line per event (probe messages can span many lines)
$K get events -A --field-selector type=Warning -o json 2>/dev/null | python3 -c '
import json, sys
ev = json.load(sys.stdin)["items"]
ev.sort(key=lambda e: e.get("lastTimestamp") or e.get("eventTime") or "")
for e in ev:
    msg = " ".join((e.get("message") or "").split())
    print((e.get("lastTimestamp") or e.get("eventTime") or "")[:19], e["metadata"]["namespace"],
          e["involvedObject"].get("name", ""), e.get("reason", ""), "x%s" % e.get("count", 1), msg[:180])
' >> "$LOG" 2>&1
log "--- etcd cp1: slow requests (took too long) since boot"
$TALOS -n 10.10.10.11 logs etcd 2>/dev/null | grep -c "took too long" >> "$LOG"
log "recorder end"
