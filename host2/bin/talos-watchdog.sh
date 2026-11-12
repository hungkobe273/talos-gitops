#!/usr/bin/env bash
# talos-watchdog.sh - "nguoi canh" ngoai cum talos-kvm, chay tren host2 bang systemd timer.
# Viet 23/10 (Phuc), chay tren host2 tu 23/10; dua vao Git 05/11 khi them kiem tra NFS.
#
# 06/11: them taint out-of-service cho worker da tat han (oos_reconcile), de StatefulSet chuyen node.
# 09/11: bo kiem tra NFS (go NFS cung Harbor); srv_disk nay do dia chua VM.
# 10/11: eso_kick (moi 120 s) - annotate ClusterSecretStore khi Vault da len ma store van loi (ESO backoff toi ~16 phut),
#        roi annotate force-sync cho ExternalSecret chua Ready khi store da Ready.
#
# Kiem tra moi lan chay: Internet cua host2, PSI io, 3 VM running, dung luong dia chua VM
# (/var/lib/libvirt/images), kube-apiserver /readyz, so node Ready,
# Prometheus /-/ready, Alertmanager /-/ready, Watchdog co dang firing trong Alertmanager
# (= duong Prometheus -> Alertmanager con song).
# Chi bao Telegram khi doi trang thai (OK->LOI sau FAIL_AFTER lan lien tiep, LOI->OK),
# nhac lai khi loi keo dai REMIND_SEC. Khong gui duoc (mat Internet) -> giu trong pending.txt,
# gui bu khi co mang lai.
#
# Bien moi truong (dat trong unit):
#   STATE_DIRECTORY        tu StateDirectory= (bat buoc)
#   CREDENTIALS_DIRECTORY  tu LoadCredential= (chua file telegram-bot-token, tuy chon hc-ping-url)
#   TG_CHAT_ID             chat id Telegram
#   KUBECONFIG             kubeconfig tren host2
#   WATCHDOG_DRY_RUN=1     chi ghi log, khong gui Telegram (dung khi thu tay)
#
# File dieu khien trong $STATE_DIRECTORY (user ngochung tu tao/xoa, khong can sudo):
#   pause-until     so epoch; truoc thoi diem do script bo qua moi kiem tra
#   force-test      co file -> gui 1 tin thu roi xoa file
#   simulate-fail   moi dong 1 ten kiem tra (internet, psi_io, vms, srv_disk, backup_age, api, nodes, paused,
#                   prometheus, grafana_dash, alertmanager, pipeline) -> coi nhu loi, de thu ma khong dong vao cum
#
# Khong bao gio dung `set -x`: token Telegram nam trong bien cuc bo cua tg_send.
set -euo pipefail

: "${STATE_DIRECTORY:?can chay qua systemd (StateDirectory=) hoac dat STATE_DIRECTORY khi thu tay}"
STATE="${STATE_DIRECTORY%%:*}"            # StateDirectory co the co nhieu thu muc, lay cai dau
TG_CHAT_ID="${TG_CHAT_ID:-}"
DRY_RUN="${WATCHDOG_DRY_RUN:-0}"

VMS="${WATCHDOG_VMS:-cp1 w1 w2}"
EXPECTED_NODES="${WATCHDOG_EXPECTED_NODES:-3}"
FAIL_AFTER="${WATCHDOG_FAIL_AFTER:-2}"      # so lan loi lien tiep truoc khi bao (chong bao nham khi PSI vot)
REMIND_SEC="${WATCHDOG_REMIND_SEC:-21600}"  # nhac lai moi 6 gio neu van loi
BOOT_GRACE="${WATCHDOG_BOOT_GRACE:-900}"    # 15 phut dau sau boot: khoi dong lanh ~10 phut, bo qua
PSI_HIGH=40                                 # vao LOI khi full avg60 >= 40 (runbook 3.8)
PSI_LOW=25                                  # ra LOI khi < 25 (tre de khong nhap nhay)
PSI_FILE="${WATCHDOG_PSI_FILE:-/proc/pressure/io}"  # doi duoc khi thu tren may khac
DISK_DIR="${WATCHDOG_DISK_DIR:-/var/lib/libvirt/images}"
SRV_DISK_MAX="${WATCHDOG_SRV_DISK_MAX:-85}" # % dung cua filesystem chua DISK_DIR (dia qcow2 cua VM)
# Worker VM -> ten node, cho taint out-of-service (06/11, xem oos_reconcile)
OOS_MAP="${WATCHDOG_OOS_MAP:-w1=talos-hdl-7jo w2=talos-iv6-z5m}"
OOS_TAINT=node.kubernetes.io/out-of-service
# Tuoi backup (12/11, audit obs0): mtime dau do drop-in 40-stamp.conf cham khi talos-etcd-backup.service thanh cong
BACKUP_STAMP="${WATCHDOG_BACKUP_STAMP:-/home/ngochung/talos-kvm/.backup-last-ok}"
BACKUP_MAX_H="${WATCHDOG_BACKUP_MAX_H:-26}"         # T3-T7: hom qua phai co backup (tat cum ~16:50 hoac 10:30)
BACKUP_MAX_H_MON="${WATCHDOG_BACKUP_MAX_H_MON:-74}" # T2: ban thu 6 van hop le

NS=monitoring
PROM_SVC=kps-kube-prometheus-stack-prometheus:9090
GRAFANA_SVC=kps-grafana:80
GRAFANA_SETTLE="${WATCHDOG_GRAFANA_SETTLE:-600}"  # Grafana Ready chua du 10 phut thi chua so (dang provisioning)
AM_SVC=kps-kube-prometheus-stack-alertmanager:9093

now=$(date +%s)
HOST=$(hostname -s)

log() { echo "$*"; }   # stdout -> journald (journalctl -u talos-watchdog)

kk() { kubectl --request-timeout=10s --cache-dir "$STATE/kube-cache" "$@"; }

one_line() { tr '\n\r' '  ' | sed 's/ *$//' | cut -c1-200; }

# --- Telegram -----------------------------------------------------------------------------
# Token khong xuat hien tren dong lenh (ps, /proc/*/cmdline): URL dua cho curl qua stdin (-K -),
# printf la lenh noi bo cua bash nen khong tao tien trinh mang token.
tg_send() {
  local text=$1 token resp
  if [[ $DRY_RUN == 1 ]]; then log "DRY_RUN, khong gui: $text"; return 0; fi
  [[ -n ${CREDENTIALS_DIRECTORY:-} && -r $CREDENTIALS_DIRECTORY/telegram-bot-token ]] || { log "thieu credential telegram-bot-token"; return 1; }
  [[ -n $TG_CHAT_ID ]] || { log "thieu TG_CHAT_ID"; return 1; }
  token=$(tr -d '[:space:]' < "$CREDENTIALS_DIRECTORY/telegram-bot-token")
  resp=$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" \
    | curl -sS --max-time 15 -K - \
        --data-urlencode "chat_id=$TG_CHAT_ID" \
        --data-urlencode "text=$text" 2>/dev/null) || return 1
  [[ $resp == *'"ok":true'* ]]
}

NET_OK=0
PENDING="$STATE/pending.txt"

flush_pending() {
  [[ -s $PENDING ]] || return 0
  local body
  body=$(tail -n 30 "$PENDING" | cut -c1-3300)
  if tg_send "[watchdog $HOST] Tin giu lai luc khong gui duoc:"$'\n'"$body"; then
    : > "$PENDING"; log "da gui bu pending"
  else
    return 1
  fi
}

notify() {
  local msg=$1
  log "BAO: $msg"
  if [[ $NET_OK == 1 ]] && flush_pending && tg_send "[watchdog $HOST] $msg"; then
    return 0
  fi
  printf '%s %s\n' "$(date '+%d/%m %H:%M')" "$msg" >> "$PENDING"
  log "khong gui duoc, da giu trong pending.txt"
}

# --- Trang thai tung kiem tra -------------------------------------------------------------
# $STATE/<ten>.state: "<OK|FAIL> <since_epoch> <so_lan_loi_lien_tiep> <lan_bao_cuoi_epoch>"
record() {
  local name=$1 res=$2 detail=$3 f="$STATE/$1.state"
  local st=OK since=$now cnt=0 last=0
  if [[ -f $f ]]; then read -r st since cnt last < "$f" || true; fi

  if [[ $res == ok ]]; then
    if [[ $st == FAIL ]]; then
      notify "DA ON: $name - $detail (loi keo dai $(( (now - since) / 60 )) phut, tu $(date -d "@$since" '+%H:%M %d/%m'))"
      since=$now
    fi
    st=OK; cnt=0
  else
    cnt=$((cnt + 1))
    if [[ $st == OK && $cnt -ge $FAIL_AFTER ]]; then
      st=FAIL; since=$now; last=$now
      notify "LOI: $name - $detail"
    elif [[ $st == FAIL && $(( now - last )) -ge $REMIND_SEC ]]; then
      last=$now
      notify "VAN LOI: $name - $detail (tu $(date -d "@$since" '+%H:%M %d/%m'))"
    fi
  fi
  log "$name: res=$res state=$st cnt=$cnt detail=$detail"
  printf '%s %s %s %s\n' "$st" "$since" "$cnt" "$last" > "$f"
}

simulated() { [[ -f $STATE/simulate-fail ]] && grep -qx "$1" "$STATE/simulate-fail"; }

# run_check <ten> <ham kiem tra>: ham in 1 dong mo ta, tra 0 = OK, khac 0 = loi
run_check() {
  local name=$1 fn=$2 detail
  if simulated "$name"; then record "$name" fail "GIA LAP (simulate-fail)"; return 1; fi
  if detail=$("$fn" 2>&1); then
    record "$name" ok "$(one_line <<<"${detail:-ok}")"; return 0
  else
    record "$name" fail "$(one_line <<<"${detail:-loi}")"; return 1
  fi
}

# --- Cac ham kiem tra ---------------------------------------------------------------------
chk_internet() {
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 https://api.telegram.org/ 2>/dev/null) || true
  if [[ -n $code && $code != 000 ]]; then echo "HTTP $code"; return 0; fi
  echo "khong toi duoc api.telegram.org (portal het han?)"; return 1
}

chk_psi_io() {
  local v prev=OK lim=$PSI_HIGH
  v=$(awk '/^full/ { for (i = 2; i <= NF; i++) if ($i ~ /^avg60=/) { sub("avg60=", "", $i); print $i } }' "$PSI_FILE")
  if [[ -f $STATE/psi_io.state ]]; then read -r prev _ < "$STATE/psi_io.state" || true; fi
  [[ $prev == FAIL ]] && lim=$PSI_LOW
  if awk -v v="$v" -v l="$lim" 'BEGIN { exit !(v < l) }'; then echo "PSI io full avg60=${v}%"; return 0; fi
  echo "PSI io full avg60=${v}% (nguong ${lim}%, xem runbook 3.8)"; return 1
}

chk_vms() {
  local v s bad=()
  for v in $VMS; do
    s=$(virsh -c qemu:///system domstate "$v" 2>&1) || s="loi virsh"
    s=$(one_line <<<"$s")
    [[ $s == running ]] || bad+=("$v=$s")
  done
  if (( ${#bad[@]} == 0 )); then echo "VM running: $VMS"; return 0; fi
  echo "VM khong chay: ${bad[*]}"; return 1
}

chk_srv_disk() {
  local p
  p=$(df --output=pcent "$DISK_DIR" 2>/dev/null | tail -1 | tr -cd '0-9')
  [[ -n $p ]] || { echo "khong doc duoc df $DISK_DIR"; return 1; }
  if (( p < SRV_DISK_MAX )); then echo "$DISK_DIR dung ${p}%"; return 0; fi
  echo "$DISK_DIR dung ${p}% (nguong ${SRV_DISK_MAX}%): dia qcow2 cua VM sap day"; return 1
}

# Chi kiem khi cp1 dang chay (cum tat thi khong co gi moi de backup). Sau ngay nghi (cum khong bat) se bao 1 lan
# luc sang, dung y: lan backup cuoi da cu; muon im thi cham tay: touch <BACKUP_STAMP>.
chk_backup_age() {
  [[ $(virsh -c qemu:///system domstate cp1 2>/dev/null) == running ]] || { echo "cp1 khong chay, bo qua"; return 0; }
  [[ -f $BACKUP_STAMP ]] || { echo "chua co dau $BACKUP_STAMP (cho lan backup thanh cong dau tien)"; return 0; }
  local mt max age_h
  mt=$(stat -c %Y "$BACKUP_STAMP")
  max=$BACKUP_MAX_H; [[ $(date +%u) == 1 ]] && max=$BACKUP_MAX_H_MON
  age_h=$(( (now - mt) / 3600 ))
  if (( age_h >= max )); then
    echo "backup thanh cong cuoi luc $(date -d "@$mt" '+%H:%M %d/%m') (${age_h} gio truoc, nguong ${max} gio). Chay backup tay (runbook 2.1) hoac kiem journalctl -u talos-etcd-backup"
    return 1
  fi
  echo "backup cuoi $(date -d "@$mt" '+%H:%M %d/%m') (${age_h} gio)"
}

chk_api() {
  local out
  out=$(kk get --raw /readyz 2>&1) || { echo "apiserver khong tra loi: $out"; return 1; }
  echo "/readyz $out"
}

chk_nodes() {
  local out ready total notready
  out=$(kk get nodes --no-headers 2>&1) || { echo "kubectl get nodes loi: $out"; return 1; }
  total=$(grep -c . <<<"$out" || true)
  ready=$(awk '$2 ~ /^Ready/' <<<"$out" | grep -c . || true)
  notready=$(awk '$2 !~ /^Ready/ { printf "%s(%s) ", $1, $2 }' <<<"$out")
  if (( ready >= EXPECTED_NODES )); then echo "$ready/$total node Ready"; return 0; fi
  echo "$ready/$EXPECTED_NODES node Ready; chua Ready: ${notready:-thieu node}"; return 1
}

chk_prometheus() {
  local out
  out=$(kk get --raw "/api/v1/namespaces/$NS/services/$PROM_SVC/proxy/-/ready" 2>&1) \
    || { echo "Prometheus chua ready: $out"; return 1; }
  echo "$out"
}

# 12/11: Grafana khoi dong lai co the bo do provisioning ("Could not set default permissions ... context canceled",
# 06/11 va 12/11): dashboard van co nhung Viewer/anonymous bi 403. So so dashboard anonymous thay voi so muc trong
# ConfigMap nhan grafana_dashboard. Lech thi bao, kem ten dashboard thieu; sua: UI dashboard > Settings > Permissions,
# them Role Viewer=View, Editor=Edit (URL ...?editview=permissions).
chk_grafana_dash() {
  local ready_since cms seen
  ready_since=$(kk -n "$NS" get pod -l app.kubernetes.io/name=grafana     -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].lastTransitionTime}' 2>/dev/null)
  [[ -n $ready_since ]] || { echo "chua co pod Grafana Ready, bo qua"; return 0; }
  if (( now - $(date -d "$ready_since" +%s) < GRAFANA_SETTLE )); then echo "Grafana moi Ready luc $ready_since, cho provisioning xong"; return 0; fi
  cms=$(kk get cm -A -l grafana_dashboard -o json 2>&1) || { echo "khong doc duoc ConfigMap dashboard: $(one_line <<<"$cms")"; return 1; }
  seen=$(kk get --raw "/api/v1/namespaces/$NS/services/$GRAFANA_SVC/proxy/api/search?type=dash-db&limit=5000" 2>&1)     || { echo "khong goi duoc Grafana /api/search: $(one_line <<<"$seen")"; return 1; }
  # ConfigMap dashboard co the vai MB (qua gioi han 128 KB cua 1 bien moi truong) -> dua qua stdin
  SEEN=$seen python3 -c '
import json, os, sys
seen = {d.get("uid") for d in json.loads(os.environ["SEEN"])}
want = {}
for cm in json.load(sys.stdin)["items"]:
    for v in (cm.get("data") or {}).values():
        try:
            j = json.loads(v)
        except ValueError:
            continue
        want[j.get("uid")] = j.get("title", "?")
miss = sorted(t for u, t in want.items() if u not in seen)
if miss:
    print("anonymous thay %d/%d dashboard, thieu quyen Viewer: %s" % (len(want) - len(miss), len(want), "; ".join(miss)))
    sys.exit(1)
print("anonymous thay du %d dashboard" % len(want))
' <<<"$cms"
}

chk_alertmanager() {
  local out
  out=$(kk get --raw "/api/v1/namespaces/$NS/services/$AM_SVC/proxy/-/ready" 2>&1) \
    || { echo "Alertmanager chua ready: $out"; return 1; }
  echo "Alertmanager $out"
}

# Watchdog luon firing; mat khoi Alertmanager = Prometheus khong danh gia rule hoac khong gui duoc
chk_pipeline() {
  local out
  out=$(kk get --raw "/api/v1/namespaces/$NS/services/$AM_SVC/proxy/api/v2/alerts?active=true" 2>&1) \
    || { echo "khong doc duoc /api/v2/alerts: $out"; return 1; }
  if grep -q '"alertname":"Watchdog"' <<<"$out"; then echo "Watchdog dang firing trong Alertmanager"; return 0; fi
  echo "Watchdog KHONG co trong Alertmanager (Prometheus -> Alertmanager dut?)"; return 1
}

# 10/11: talos-cluster-stop.sh tam dung app co volume Longhorn (Vault, Grafana ve 0); talos-cluster-resume.sh tra lai
# luc boot. Quen resume (bat VM bang tay ma khong chay service) thi Vault nam o 0 pod -> bao.
chk_paused() {
  local apps
  apps=$(kk -n argocd get application -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.annotations.talos-stop}{" "}{end}' 2>&1) \
    || { echo "khong doc duoc Application: $apps"; return 1; }
  apps=$(tr ' ' '\n' <<<"$apps" | grep -v -e '=$' -e '^$' | cut -d= -f1 | tr '\n' ' ')
  [[ -z $apps ]] && { echo "khong co app tam dung"; return 0; }
  echo "app van tam dung boi talos-cluster-stop.sh: $apps(Vault/Grafana o 0 pod). Chay: sudo systemctl start talos-cluster-resume.service"
  return 1
}

# --- Taint out-of-service (06/11) ---------------------------------------------------------
# Test N-1 06/11: rut dien w1 thi keycloak-0 (StatefulSet) ket tren node chet, Kubernetes khong tu tao
# ban moi (tranh 2 ban cung chay) nen SSO mat 20 phut. Cach chuan: gan taint
# node.kubernetes.io/out-of-service=nodeshutdown:NoExecute len node DA TAT HAN -> Kubernetes xoa cuong buc
# pod va thao volume, StatefulSet tao lai o worker con lai. Chi host2 biet chac VM da tat (virsh domstate),
# nen chi gan khi VM "shut off"/"crashed" VA node khong Ready. VM chay lai -> go taint ngay (ca luc
# boot grace va pause, de taint khong o lai lam hong cold start).
#   oos_reconcile remove : chi go taint khi VM da running
#   oos_reconcile apply  : gan taint khi VM tat va node khong Ready
oos_reconcile() {
  local mode=$1 pair vm node vs ready tainted
  for pair in $OOS_MAP; do
    vm=${pair%%=*}; node=${pair#*=}
    vs=$(virsh -c qemu:///system domstate "$vm" 2>/dev/null | one_line) || continue
    tainted=$(kk get node "$node" -o jsonpath="{.spec.taints[?(@.key==\"$OOS_TAINT\")].effect}" 2>/dev/null) || continue
    if [[ $mode == remove ]]; then
      [[ -n $tainted && $vs == running ]] || continue
      if [[ $DRY_RUN == 1 ]]; then log "DRY_RUN: se go taint $OOS_TAINT khoi $node"; continue; fi
      kk taint nodes "$node" "$OOS_TAINT-" >/dev/null \
        && notify "DA GO taint out-of-service khoi $node: VM $vm da chay lai"
      continue
    fi
    [[ -z $tainted ]] || continue
    case $vs in "shut off"|crashed) ;; *) continue ;; esac
    ready=$(kk get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || continue
    [[ $ready != True ]] || continue
    if [[ $DRY_RUN == 1 ]]; then log "DRY_RUN: se gan taint $OOS_TAINT len $node (VM $vm $vs, Ready=$ready)"; continue; fi
    kk taint nodes "$node" "$OOS_TAINT=nodeshutdown:NoExecute" --overwrite >/dev/null \
      && notify "GAN taint out-of-service len $node: VM $vm $vs, node Ready=$ready. Pod tren node (ca StatefulSet nhu Keycloak) bi xoa cuong buc de chay lai o worker con lai. VM chay lai thi watchdog tu go taint"
  done
}

# 10/11: Vault dung vai phut (chuyen Longhorn) thi ClusterSecretStore loi InvalidProviderConfig. ESO v2.14 thu lai
# theo cap so nhan cua controller-runtime (toi ~16 phut), refreshInterval khong ap khi dang loi, khong co flag de
# chinh. Annotate store thi ESO reconcile ngay. Chi annotate khi vault-0 da Ready (unsealed) ma store van khong Ready,
# toi da 1 lan moi ESO_KICK_SEC cho moi store. Chi ghi log, khong bao Telegram (tu sua duoc, cold start cung gap).
# Cold start 10/11 11:06: lan kick 11:15:02 (vault-0 Ready tu 11:13:48) van "connection refused" toi vault-active
# (ESO chay tren w3, kube-proxy w3 chua cap nhat endpoint sau khi API chap chon), 300 s sau moi kick lai -> store
# Valid 11:21. Ha xuong 120 s = moi lan watchdog chay (3 phut); moi lan kick chi la 1 lan login Vault.
ESO_KICK_SEC="${WATCHDOG_ESO_KICK_SEC:-120}"
eso_kick() {
  local vready stores s last
  vready=$(kk -n vault get pod vault-0 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || return 0
  [[ $vready == True ]] || return 0
  stores=$(kk get clustersecretstore -o jsonpath='{range .items[?(@.status.conditions[0].status!="True")]}{.metadata.name}{"\n"}{end}' 2>/dev/null) || return 0
  for s in $stores; do
    last=$(cat "$STATE/eso-kick-$s" 2>/dev/null || echo 0)
    (( now - last >= ESO_KICK_SEC )) || continue
    if [[ $DRY_RUN == 1 ]]; then log "DRY_RUN: se annotate clustersecretstore $s"; continue; fi
    kk annotate clustersecretstore "$s" "watchdog.talos/force-sync=$now" --overwrite >/dev/null \
      && echo "$now" > "$STATE/eso-kick-$s" \
      && log "vault-0 Ready nhung clustersecretstore $s chua Ready: da annotate de ESO reconcile ngay"
  done
  # Cold start 10/11 09:51: store tu Valid lai nhung ExternalSecret demo-app-env van SecretSyncedError (lan thu cuoi
  # truoc khi store Valid 6 s, sau do cung lui theo cap so nhan). Store da Ready het thi annotate ExternalSecret chua Ready
  # (force-sync la cach ESO huong dan de lam moi ngay).
  [[ -z $stores ]] || return 0
  local es ns name key
  es=$(kk get externalsecret -A -o jsonpath='{range .items[?(@.status.conditions[0].status!="True")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null) || return 0
  for s in $es; do
    ns=${s%%/*}; name=${s#*/}; key="eso-kick-es-$ns-$name"
    last=$(cat "$STATE/$key" 2>/dev/null || echo 0)
    (( now - last >= ESO_KICK_SEC )) || continue
    if [[ $DRY_RUN == 1 ]]; then log "DRY_RUN: se annotate externalsecret $s"; continue; fi
    kk -n "$ns" annotate externalsecret "$name" "force-sync=$now" --overwrite >/dev/null \
      && echo "$now" > "$STATE/$key" \
      && log "clustersecretstore Ready nhung externalsecret $s chua Ready: da annotate force-sync"
  done
}

# --- Chay ---------------------------------------------------------------------------------
mkdir -p "$STATE/kube-cache"

# Go taint truoc moi dieu kien bo qua (boot grace, pause): VM da chay lai thi node phai nhan pod binh thuong.
oos_reconcile remove || true
# Cung chay truoc boot grace/pause: chi annotate, khong hai, giup cold start va luc Vault restart.
eso_kick || true

uptime_s=$(cut -d. -f1 /proc/uptime)
if (( uptime_s < BOOT_GRACE )); then
  log "host2 moi boot ${uptime_s}s (< ${BOOT_GRACE}s), bo qua lan nay"; exit 0
fi

if [[ -f $STATE/pause-until ]]; then
  until_ts=$(tr -cd '0-9' < "$STATE/pause-until")
  if [[ -n $until_ts ]] && (( now < until_ts )); then
    log "dang tam dung den $(date -d "@$until_ts" '+%H:%M %d/%m'), bo qua"; exit 0
  fi
  rm -f "$STATE/pause-until"; log "het tam dung, kiem tra lai binh thuong"
fi

# Internet truoc: quyet dinh co gui tin ngay duoc khong
if simulated internet; then
  NET_OK=0
  record internet fail "GIA LAP (simulate-fail)"
elif net_detail=$(chk_internet); then
  NET_OK=1
  record internet ok "$net_detail"
else
  NET_OK=0
  record internet fail "$net_detail"
fi

# Co mang ma con tin cu chua gui (vd lan truoc Telegram loi tam thoi) -> gui bu ngay
if [[ $NET_OK == 1 ]]; then flush_pending || log "gui bu pending loi, thu lai lan sau"; fi

if [[ -f $STATE/force-test ]]; then
  rm -f "$STATE/force-test"
  notify "Tin thu: watchdog chay binh thuong ($(date '+%H:%M %d/%m'))"
fi

run_check psi_io chk_psi_io || true
run_check vms chk_vms || true
run_check srv_disk chk_srv_disk || true
run_check backup_age chk_backup_age || true

# Moi kiem tra Kubernetes phu thuoc apiserver: API chet thi chi bao 1 tin, cac muc sau giu nguyen trang thai
if run_check api chk_api; then
  run_check nodes chk_nodes || true
  oos_reconcile apply || true
  run_check paused chk_paused || true
  run_check prometheus chk_prometheus || true
  run_check grafana_dash chk_grafana_dash || true
  if run_check alertmanager chk_alertmanager; then
    run_check pipeline chk_pipeline || true
  fi
fi

# Tuy chon (giai doan 2): ping healthchecks.io = "host2 con song va co Internet".
# Chi chay khi unit co LoadCredential=hc-ping-url:... (drop-in 10-healthchecks.conf).
if [[ $NET_OK == 1 && $DRY_RUN != 1 && -n ${CREDENTIALS_DIRECTORY:-} && -r $CREDENTIALS_DIRECTORY/hc-ping-url ]]; then
  printf 'url = "%s"\n' "$(tr -d '[:space:]' < "$CREDENTIALS_DIRECTORY/hc-ping-url")" \
    | curl -sS -o /dev/null --max-time 10 --retry 2 -K - 2>/dev/null || log "ping healthchecks loi"
fi

exit 0
