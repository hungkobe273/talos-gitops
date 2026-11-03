#!/usr/bin/env bash
# Cold start recorder (03/11): runs once per host2 boot, for 20 minutes, and logs every change in
#   - API reachability
#   - kube-dns EndpointSlice (address, ready, pod)        -> stale endpoints after the shutdown?
#   - CoreDNS pods (node, IP, Ready)
#   - keycloak-0 (init container dbchecker, Ready)
# At the end it saves dbchecker logs with timestamps and the kube-proxy log of each node.
# Question it answers: why dbchecker waited 40 s for DNS/TCP at the 03/11 10:12 cold start.
# Reads only; no Secrets are printed.
set -u
DIR="$HOME/talos-kvm/coldstart-logs"
mkdir -p "$DIR"
LOG="$DIR/coldstart-$(date +%Y%m%d-%H%M).log"
K="kubectl --request-timeout=3s"
END=$(( $(date +%s) + 1200 ))
declare -A prev

log() { echo "$(date +%T) $*" >> "$LOG"; }
changed() {  # key value: log value only when it differs from the previous sample
  if [ "${prev[$1]:-}" != "$2" ]; then prev[$1]="$2"; log "$1: $2"; fi
}

log "host2 up since $(uptime -s), recorder start"
while [ "$(date +%s)" -lt "$END" ]; do
  if $K get --raw /readyz >/dev/null 2>&1; then api=up; else api=down; fi
  changed api "$api"
  if [ "$api" = up ]; then
    changed vms "$(virsh -c qemu:///system list --name 2>/dev/null | grep -v '^$' | tr '\n' ' ')"
    changed nodes "$($K get nodes --no-headers 2>/dev/null | awk '{printf "%s=%s ", $1, $2}')"
    changed kube-dns-eps "$($K -n kube-system get endpointslice -l kubernetes.io/service-name=kube-dns \
      -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}/{.targetRef.name}/ready={.conditions.ready} {end}' 2>/dev/null)"
    changed coredns "$($K -n kube-system get pod -l k8s-app=kube-dns \
      -o jsonpath='{range .items[*]}{.metadata.name}@{.spec.nodeName}/{.status.podIP}/{.status.conditions[?(@.type=="Ready")].status} {end}' 2>/dev/null)"
    changed keycloak "$($K -n keycloak get pod keycloak-0 \
      -o jsonpath='{.spec.nodeName} {.status.phase} init={.status.initContainerStatuses[0].state} ready={.status.containerStatuses[0].ready}' 2>/dev/null | cut -c1-300)"
  fi
  sleep 2
done

log "--- dbchecker log (timestamps)"
$K -n keycloak logs keycloak-0 -c dbchecker --timestamps >> "$LOG" 2>&1
for p in $($K -n kube-system get pod -o name 2>/dev/null | grep -E 'kube-proxy|coredns'); do
  log "--- $p (first 40 lines)"
  $K -n kube-system logs "$p" --timestamps 2>&1 | head -40 | cut -c1-220 >> "$LOG"
done
log "recorder end"
