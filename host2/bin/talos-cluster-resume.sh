#!/usr/bin/env bash
# talos-cluster-resume.sh - tra lai cac app ma talos-cluster-stop.sh da tam dung (10/11).
# Chay boi talos-cluster-resume.service luc host2 boot; chay tay duoc khi bat VM bang tay (runbook 2.3):
#   sudo systemctl start talos-cluster-resume.service   (hoac chay thang script nay)
# Cho API song va instance-manager Longhorn tren w1, w2 Ready SAU lan bat VM gan nhat (trang thai cu trong API
# khong tinh), roi tra replicas cho workload co annotation talos-stop-replicas (scale thang) va go skip-reconcile
# tren app co dau talos-stop; pod gan volume Longhorn sach (khong faulted, khong rebuild). Khong co app nao bi tam
# dung thi thoat ngay.
# Cold start 10/11 11:06 ban dau chi go skip-reconcile de Argo CD tra replicas: app monitoring (kube-prometheus-stack)
# sync mat 7 phut, toi luot Grafana da 4 phut sau -> Grafana Ready +11:31. Nen scale thang truoc.
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/talos-kvm/kubeconfig}"
K="kubectl --request-timeout=10s"
TIMEOUT="${RESUME_TIMEOUT:-3600}"
WORKERS="w1=talos-hdl-7jo w2=talos-iv6-z5m"
end=$(( $(date +%s) + TIMEOUT ))
say() { echo "$(date +%T) $*"; }

vm_start() {  # epoch luc tien trinh qemu cua VM bat dau (0 neu VM khong chay)
  local pid; pid=$(pgrep -f "guest=$1," | head -1)
  [[ -n $pid ]] && date -d "$(ps -o lstart= -p "$pid")" +%s || echo 0
}

paused=""
until paused=$($K -n argocd get application -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.annotations.talos-stop}{" "}{end}' 2>/dev/null); do
  (( $(date +%s) >= end )) && { say "het ${TIMEOUT}s ma API chua song"; exit 1; }
  sleep 5
done
paused=$(tr ' ' '\n' <<<"$paused" | grep -v '=$' | grep -v '^$' | cut -d= -f1 | tr '\n' ' ')
[[ -z $paused ]] && { say "khong co app nao bi tam dung, thoat"; exit 0; }
say "app dang tam dung: $paused"

for pair in $WORKERS; do
  vm=${pair%%=*}; node=${pair#*=}
  while :; do
    since=$(vm_start "$vm")
    ready=$($K -n longhorn-system get pod -l longhorn.io/component=instance-manager --field-selector spec.nodeName="$node" \
      -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}={.status.conditions[?(@.type=="Ready")].lastTransitionTime}{" "}{end}' 2>/dev/null)
    ok=0
    for r in $ready; do
      [[ ${r%%=*} == True ]] || continue
      t=$(date -d "${r#*=}" +%s 2>/dev/null || echo 0)
      (( since > 0 && t >= since )) && ok=1
    done
    (( ok )) && { say "instance-manager Longhorn tren $vm ($node) Ready"; break; }
    (( $(date +%s) >= end )) && { say "het ${TIMEOUT}s ma Longhorn tren $vm chua Ready, van tra lai app"; break; }
    sleep 5
  done
done

# Tra replicas truoc (pod tao ngay) roi go annotation tren workload; Git cung so replicas nen Argo CD van Synced
for r in $($K get deploy,sts -A -o jsonpath='{range .items[*]}{.kind}|{.metadata.namespace}|{.metadata.name}|{.metadata.annotations.talos-stop-replicas}{" "}{end}' 2>/dev/null); do
  IFS='|' read -r kind ns name rep <<<"$r"
  [[ -n $rep ]] || continue
  $K -n "$ns" scale "${kind,,}/$name" --replicas="$rep" >/dev/null \
    && $K -n "$ns" annotate "${kind,,}/$name" talos-stop-replicas- >/dev/null 2>&1 \
    && say "da tra $ns/${kind,,}/$name ve $rep replicas" \
    || say "LOI khi tra replicas $ns/$name"
done

for app in $paused; do
  $K -n argocd annotate application "$app" argocd.argoproj.io/skip-reconcile- talos-stop- >/dev/null \
    && $K -n argocd annotate application "$app" argocd.argoproj.io/refresh=normal --overwrite >/dev/null \
    && say "da tra lai app $app cho Argo CD" \
    || say "LOI khi go annotation app $app"
done
