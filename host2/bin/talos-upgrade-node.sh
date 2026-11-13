#!/usr/bin/env bash
# talos-upgrade-node.sh - nang Talos 1 node, gom cac buoc da hoc ngay 13/11 (docs/de-xuat-talos-1.14.6.md).
#
#   talos-upgrade-node.sh <ip-node> <version> [--yes]
#   vd: talos-upgrade-node.sh 10.148.0.4 v1.14.6          # chi in ke hoach + kiem truoc, khong doi gi
#       talos-upgrade-node.sh 10.148.0.4 v1.14.6 --yes    # nang that
#
# Lam gi:
#   1. Doc schematic dang chay tren chinh node do (khong doan): giu extension, tranh mat iscsi-tools (bai hoc 06/11).
#      Installer: w3 (IP 10.148.*) dung gcp-installer, con lai metal-installer.
#   2. Kiem truoc: moi node Ready; 3 volume Longhorn healthy; moi volume co replica dang chay o node KHAC node sap nang.
#   3. Control plane: chup etcd snapshot vao ~/talos-kvm/ truoc (khong in noi dung).
#   4. Xoa pod csi-attacher/csi-provisioner tren node do (PDB Longhorn minAvailable 1 + 1 replica chan drain, 13/11).
#   5. talosctl upgrade --wait; kiem tag, extension giong truoc, node Ready va da uncordon.
#   6. Cho Longhorn healthy va khong con pod treo (toi da 30 phut) roi moi thoat 0.
# Moi lenh doi he thong chi chay khi co --yes. Khong doc/in machine config.
set -euo pipefail

NODE=${1:?ip node}; VER=${2:?version, vd v1.14.6}; YES=${3:-}
EP=10.10.10.11
export TALOSCONFIG=${TALOSCONFIG:-$HOME/talos-kvm/talosconfig}
export KUBECONFIG=${KUBECONFIG:-$HOME/talos-kvm/kubeconfig}
T() { talosctl -e "$EP" -n "$NODE" "$@"; }
say() { echo "$(date +%T) $*"; }
die() { say "DUNG: $*"; exit 1; }
run() { if [[ $YES == --yes ]]; then "$@"; else say "(chua chay, thieu --yes) $*"; fi; }

[[ $VER =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version phai dang v1.14.6"

# --- node, schematic, installer
NAME=$(kubectl get node -o jsonpath="{range .items[*]}{.metadata.name} {.status.addresses[?(@.type=='InternalIP')].address}{'\n'}{end}" | awk -v ip="$NODE" '$2==ip{print $1}')
[[ -n $NAME ]] || die "khong thay node co IP $NODE"
CUR=$(T version 2>/dev/null | awk '/Server:/{s=1} s&&/Tag:/{print $2; exit}')
EXT_BEFORE=$(T get extensions 2>/dev/null | awk 'NR>1{print $6}' | sort | tr '\n' ' ')
SCHEM=$(T get extensions -o yaml 2>/dev/null | grep -A3 'name: schematic' | grep -oE '[0-9a-f]{64}' | head -1)
[[ -n $SCHEM ]] || die "khong doc duoc schematic cua $NODE"
case $NODE in 10.148.*) KIND=gcp-installer ;; *) KIND=metal-installer ;; esac
IMAGE=factory.talos.dev/$KIND/$SCHEM:$VER
CP=no; kubectl get node "$NAME" -o jsonpath='{.metadata.labels}' | grep -q 'node-role.kubernetes.io/control-plane' && CP=yes
say "node $NAME ($NODE) control-plane=$CP dang chay $CUR -> $VER"
say "extension: $EXT_BEFORE"
say "installer: $IMAGE"
[[ $CUR == "$VER" ]] && { say "da o $VER, khong lam gi"; exit 0; }

# --- kiem truoc
NOTREADY=$(kubectl get node --no-headers | awk '$2!="Ready"{print $1}')
[[ -z $NOTREADY ]] || die "node chua Ready: $NOTREADY"
ROB=$(kubectl -n longhorn-system get volumes.longhorn.io -o jsonpath='{range .items[*]}{.status.robustness}{"\n"}{end}' | sort | uniq -c | tr '\n' ' ')
echo "$ROB" | grep -qvE 'degraded|faulted|unknown' || die "Longhorn chua healthy: $ROB"
LAST=$(kubectl -n longhorn-system get replicas.longhorn.io -o custom-columns=V:.spec.volumeName,N:.spec.nodeID,S:.status.currentState --no-headers \
  | awk -v n="$NAME" '{all[$1]=1} $3=="running" && $2!=n {ok[$1]=1} END{for(v in all) if(!ok[v]) print v}')
[[ -z $LAST ]] || die "volume chi con replica chay tren $NAME: $LAST"
say "kiem truoc dat: node Ready, Longhorn $ROB"

# --- control plane: snapshot etcd
if [[ $CP == yes ]]; then
  SNAP=$HOME/talos-kvm/etcd-pre-upgrade-$(date +%Y%m%d-%H%M).db
  run talosctl -e "$EP" -n "$NODE" etcd snapshot "$SNAP"
  [[ $YES == --yes ]] && { [[ -s $SNAP ]] || die "snapshot etcd rong"; chmod 600 "$SNAP"; say "snapshot etcd: $SNAP ($(du -h "$SNAP" | cut -f1))"; }
fi

# --- pod CSI tren node nay
CSI=$(kubectl -n longhorn-system get pod -o wide --no-headers | awk -v n="$NAME" '$1~/^csi-(attacher|provisioner)-/ && $7==n{print $1}')
if [[ -n $CSI ]]; then
  say "pod CSI tren $NAME: $CSI"
  run kubectl -n longhorn-system delete pod $CSI
  run kubectl -n longhorn-system wait --for=condition=available deploy/csi-attacher deploy/csi-provisioner --timeout=180s
fi

[[ $YES == --yes ]] || { say "KE HOACH xong. Chay lai voi --yes de nang that."; exit 0; }

# --- nang
say "bat dau upgrade"
T upgrade --image "$IMAGE" --wait --timeout 20m 2>&1 | grep -vE '^\s*$' | tail -8 || true
NEW=$(T version 2>/dev/null | awk '/Server:/{s=1} s&&/Tag:/{print $2; exit}')
EXT_AFTER=$(T get extensions 2>/dev/null | awk 'NR>1{print $6}' | sort | tr '\n' ' ')
# cp1: apiserver co the chua tra loi ngay sau khi node len; thu lai toi 5 phut.
for _ in $(seq 1 30); do UNS=$(kubectl get node "$NAME" -o jsonpath='{.spec.unschedulable}' 2>/dev/null) && break; UNS=ERR; sleep 10; done
[[ $UNS != ERR ]] || die "apiserver khong tra loi sau 5 phut (talosctl -e $EP -n $EP service; logs kubelet)"
say "sau upgrade: tag=$NEW extension=$EXT_AFTER unschedulable=${UNS:-false}"
[[ $NEW == "$VER" ]] || die "node khong len $VER (lui: talosctl -e $EP -n $NODE rollback; neu con cordon: kubectl uncordon $NAME)"
[[ $EXT_AFTER == "$EXT_BEFORE" ]] || die "extension khac truoc! truoc: $EXT_BEFORE sau: $EXT_AFTER"
[[ -z $UNS ]] || die "node con cordon: kubectl uncordon $NAME"

# --- cho cum on dinh
STUCK='Pending|ContainerCreating|PodInitializing|Init:|CrashLoopBackOff|ImagePull|ErrImage|Terminating|0/[0-9]+ +Running'
say "cho Longhorn healthy va pod on dinh (toi da 30 phut)"
for _ in $(seq 1 60); do
  R=$(kubectl -n longhorn-system get volumes.longhorn.io -o jsonpath='{range .items[*]}{.status.robustness} {end}' 2>/dev/null || echo "api-loi ")
  # Chi dem pod dang ket (khong dem pod Error/Completed cu cua Job, vd image-scan hom truoc).
  P=$(kubectl get pod -A --no-headers 2>/dev/null | grep -cE "$STUCK" || true)
  if ! echo "$R" | grep -qvE '^(healthy )+$' && [[ $P -eq 0 ]]; then say "on dinh: Longhorn $R, pod treo 0"; exit 0; fi
  sleep 30
done
kubectl get pod -A --no-headers | grep -E "$STUCK" || true
die "sau 30 phut chua on dinh: Longhorn $R, pod treo $P"
