#!/usr/bin/env bash
# talos-cluster-stop.sh - tat cum talos-kvm co kiem soat (10/11, thay cac lenh tay o runbook 2.2).
#
# Van de: tat VM khi volume Longhorn con gan vao pod thi engine/replica chet dot ngot, sang hom sau Longhorn danh
# volume 'faulted', auto-salvage roi dung lai ban sao kia (cold start 10/11: doc them ~1,55 GB tu HDD, Vault va
# Grafana cho them ~1-2 phut).
# Cach lam: tam dung Argo CD cho app co volume Longhorn (annotation skip-reconcile + dau talos-stop), thu workload
# ve 0 de Longhorn tach volume sach, roi moi tat cp1, sau do w1 w2 (talosctl shutdown --force, nhu runbook 2.2).
# Sang hom sau talos-cluster-resume.sh (service luc boot) tra replicas da ghi o annotation talos-stop-replicas roi go
# skip-reconcile.
#
# Chay tren host2, user ngochung:  talos-cluster-stop.sh        (tat ca cum)
#                                  talos-cluster-stop.sh --drain-only   (chi thu workload ve 0, khong tat VM)
# T2/T4 tat som: chay backup tay TRUOC (Vault ve 0 thi snapshot Vault loi).
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/talos-kvm/kubeconfig}"
export TALOSCONFIG="${TALOSCONFIG:-$HOME/talos-kvm/talosconfig}"
K="kubectl --request-timeout=15s"
V="virsh -c qemu:///system"
# app Argo CD | namespace | workload: moi workload co PVC Longhorn (kiem lai o buoc 0)
WORKLOADS="monitoring|monitoring|deploy/kps-grafana vault|vault|sts/vault"
DETACH_TIMEOUT=180
ts() { date +%T; }
say() { echo "$(ts) $*"; }

# 0. Kiem: moi PVC longhorn deu thuoc mot workload trong danh sach (them app moi co Longhorn thi phai them vao day)
known="monitoring/grafana-longhorn vault/data-vault-0 vault/audit-vault-0"
for pvc in $($K get pvc -A -o jsonpath='{range .items[?(@.spec.storageClassName=="longhorn")]}{.metadata.namespace}/{.metadata.name}{" "}{end}'); do
  case " $known " in *" $pvc "*) ;; *) say "CANH BAO: PVC Longhorn $pvc chua co trong WORKLOADS, volume nay se khong duoc tach sach" ;; esac
done

# 1. Tam dung Argo CD, thu ve 0
for w in $WORKLOADS; do
  IFS='|' read -r app ns obj <<<"$w"
  # ghi so replicas hien tai vao workload (annotation talos-stop-replicas) de resume tra lai thang, khong cho Argo CD
  rep=$($K -n "$ns" get "$obj" -o jsonpath='{.spec.replicas}' 2>/dev/null)
  [[ $rep =~ ^[1-9][0-9]*$ ]] || rep=1
  $K -n argocd annotate application "$app" argocd.argoproj.io/skip-reconcile=true talos-stop="$(date +%s)" --overwrite >/dev/null \
    && $K -n "$ns" annotate "$obj" talos-stop-replicas="$rep" --overwrite >/dev/null 2>&1 \
    && $K -n "$ns" scale "$obj" --replicas=0 >/dev/null \
    && say "da tam dung app $app, $ns/$obj ve 0" \
    || say "LOI khi thu $ns/$obj ve 0 (van tiep tuc tat)"
done

# 2. Cho moi volume Longhorn detached
end=$(( $(date +%s) + DETACH_TIMEOUT ))
while :; do
  att=$($K -n longhorn-system get volumes.longhorn.io -o jsonpath='{range .items[*]}{.status.kubernetesStatus.pvcName}={.status.state}{" "}{end}' 2>/dev/null)
  left=$(tr ' ' '\n' <<<"$att" | grep -v -e '=detached$' -e '^$' | tr '\n' ' ')
  [[ -z $left ]] && { say "moi volume Longhorn da detached: $att"; break; }
  (( $(date +%s) >= end )) && { say "CANH BAO: het ${DETACH_TIMEOUT}s, con chua detached: $left (van tat, sang mai co the rebuild)"; break; }
  sleep 5
done

[[ ${1:-} == --drain-only ]] && { say "--drain-only: khong tat VM. Tra lai: talos-cluster-resume.sh"; exit 0; }

# 3. Tat cp1 truoc, roi worker (runbook 2.2: pod giu nguyen node; worker phai co -e chinh no vi cp1 da tat)
wait_off() {  # vm... : cho toi khi shut off, toi da 200 s
  local i vm all
  for i in $(seq 1 40); do
    all=1
    for vm in "$@"; do [[ $($V domstate "$vm" 2>/dev/null) == "shut off" ]] || all=0; done
    (( all )) && return 0
    sleep 5
  done
  return 1
}
say "tat cp1"
talosctl -n 10.10.10.11 shutdown --force --wait=false >/dev/null 2>&1
wait_off cp1 && say "cp1 shut off" || say "CANH BAO: cp1 chua shut off sau 200 s"
say "tat w1, w2"
for n in 10.10.10.21 10.10.10.22; do talosctl -e $n -n $n shutdown --force --wait=false >/dev/null 2>&1; done
wait_off w1 w2 && say "w1, w2 shut off" || say "CANH BAO: worker chua shut off sau 200 s"
$V list --all
