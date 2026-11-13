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
#                                  them --skip-backup-check de bo buoc kiem backup (chi khi chap nhan mat backup ngay)
# Buoc -1 (12/11): neu hom nay chua co lan talos-etcd-backup.service thanh cong thi script tu chay backup (sudo -n),
# backup loi thi KHONG tat. Ly do: toi 10/11 cum tat truoc 16:45 ma chua backup tay, timer 16:45 loi, mat backup ca ngay.
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
DRAIN_ONLY=0; SKIP_BACKUP=0
for a in "$@"; do
  case $a in
    --drain-only) DRAIN_ONLY=1 ;;
    --skip-backup-check) SKIP_BACKUP=1 ;;
    *) say "tham so la: $a (dung: [--drain-only] [--skip-backup-check])"; exit 2 ;;
  esac
done

# -1. Backup ngay truoc khi tat (phai lam TRUOC khi thu Vault ve 0, vi snapshot Vault can Vault dang chay)
# 12/11: truoc day chi can "hom nay co backup" -> ban backup tay buoi sang du qua cong, chieu tat cum khong backup
# lai, moi thay doi trong ngay chi con tren HDD host2. Nay: phai co lan backup thanh cong trong BACKUP_FRESH_MIN
# phut gan nhat (vd timer 16:45 roi tat 16:50 thi khong chay lai), khong co thi chay ngay.
BACKUP_FRESH_MIN=${BACKUP_FRESH_MIN:-30}
backup_ok_recent() {  # doc journal vao bien roi moi grep (grep -q trong pipe co the lam journalctl nhan SIGPIPE)
  local out
  out=$(journalctl -u talos-etcd-backup.service --since "-${BACKUP_FRESH_MIN} min" --no-pager -o cat 2>/dev/null)
  grep -q '^Finished talos-etcd-backup.service' <<<"$out"
}
latest_bundle() { ls -t "$HOME"/talos-kvm/offsite/*.gpg 2>/dev/null | head -1 | xargs -r basename; }
if (( SKIP_BACKUP )); then
  say "CANH BAO: --skip-backup-check, bo qua backup truoc khi tat"
elif backup_ok_recent; then
  say "backup trong ${BACKUP_FRESH_MIN} phut gan nhat: OK ($(latest_bundle))"
else
  say "chua co backup thanh cong trong ${BACKUP_FRESH_MIN} phut gan nhat -> chay talos-etcd-backup.service (1-2 phut)"
  # systemctl start cho unit oneshot chay xong roi moi tra ve; rc=0 la thanh cong. Khong doc lai journal de quyet,
  # vi dong "Finished" co the chua kip ghi (12/11 15:13: backup thanh cong nhung script bao LOI).
  sudo -n systemctl start talos-etcd-backup.service; rc=$?
  journalctl -u talos-etcd-backup.service --since "-10 min" --no-pager -o cat 2>/dev/null | grep -E '^OK|LOI|uploaded' | sed "s/^/$(ts)   /"
  if (( rc == 0 )) && [[ $(systemctl show talos-etcd-backup.service -p Result --value) == success ]]; then
    say "backup truoc khi tat: OK ($(latest_bundle))"
  else
    say "LOI: backup that bai, KHONG tat cum. Xem: journalctl -u talos-etcd-backup.service --since today. Sua xong chay lai script (hoac --skip-backup-check neu chap nhan mat backup)"
    exit 1
  fi
fi

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

(( DRAIN_ONLY )) && { say "--drain-only: khong tat VM. Tra lai: talos-cluster-resume.sh"; exit 0; }

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
# 2b (13/11). Tat w3 (GCP) TRUOC cp1: talosctl toi w3 di qua cp1 (-e 10.10.10.11). Talos tat may -> GCE chuyen
# instance sang TERMINATED, lich jenkins-office-hours bat lai 08:15 ngay lam viec ke tiep.
# Ly do: truoc day w3 chay toi 17:15 (T2/T4 10:40) sau khi cum on-prem da tat; pod tren w3 (kube-state-metrics,
# argo-rollouts, Prometheus...) mat API va crashloop (kube-state-metrics 378 restart trong 14 ngay).
# Bat lai trong ngay (vd tat cum giua gio roi bat lai): tu laptop  gcloud compute instances start w3 --zone asia-southeast1-b
if [[ $(date +%H%M) < 1715 ]] && timeout 20 talosctl -e 10.10.10.11 -n 10.148.0.4 version --short >/dev/null 2>&1; then
  timeout 30 talosctl -e 10.10.10.11 -n 10.148.0.4 shutdown --force --wait=false >/dev/null 2>&1 \
    && say "da gui lenh tat w3 (GCP); bat lai trong ngay: gcloud compute instances start w3 --zone asia-southeast1-b" \
    || say "CANH BAO: khong tat duoc w3, w3 se chay toi lich 17:15 (T2/T4 10:40)"
else
  say "w3 khong tra loi hoac da qua 17:15, bo qua"
fi

say "tat cp1"
talosctl -n 10.10.10.11 shutdown --force --wait=false >/dev/null 2>&1
wait_off cp1 && say "cp1 shut off" || say "CANH BAO: cp1 chua shut off sau 200 s"
say "tat w1, w2"
for n in 10.10.10.21 10.10.10.22; do talosctl -e $n -n $n shutdown --force --wait=false >/dev/null 2>&1; done
wait_off w1 w2 && say "w1, w2 shut off" || say "CANH BAO: worker chua shut off sau 200 s"
$V list --all
