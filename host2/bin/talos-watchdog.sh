#!/usr/bin/env bash
# talos-watchdog.sh - "nguoi canh" ngoai cum talos-kvm, chay tren host2 bang systemd timer.
# Viet 23/10 (Phuc), chay tren host2 tu 23/10; dua vao Git 05/11 khi them kiem tra NFS.
#
# Kiem tra moi lan chay: Internet cua host2, PSI io, 3 VM running, NFS server (nfs-server active,
# cong 2049 tren 10.10.10.1) va dung luong /srv, kube-apiserver /readyz, so node Ready,
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
#   simulate-fail   moi dong 1 ten kiem tra (internet, psi_io, vms, nfs, srv_disk, api, nodes,
#                   prometheus, alertmanager, pipeline) -> coi nhu loi, de thu ma khong dong vao cum
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
NFS_ADDR="${WATCHDOG_NFS_ADDR:-10.10.10.1}"  # dia chi NFS ma worker mount (bridge talos-net)
NFS_DIR="${WATCHDOG_NFS_DIR:-/srv/nfs/k8s}"
SRV_DISK_MAX="${WATCHDOG_SRV_DISK_MAX:-85}" # % dung cua filesystem chua NFS_DIR

NS=monitoring
PROM_SVC=kps-kube-prometheus-stack-prometheus:9090
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

# NFS cho PV nfs-host2 (05/11; Harbor registry nam tren day). Mount hard: NFS chet thi pod treo
# chu khong bao loi, nen canh tu ngoai cum.
chk_nfs() {
  local s
  s=$(systemctl is-active nfs-server 2>&1) || true
  [[ $s == active ]] || { echo "nfs-server: $s (registry Harbor treo)"; return 1; }
  timeout 5 bash -c "</dev/tcp/$NFS_ADDR/2049" 2>/dev/null \
    || { echo "nfs-server active nhung $NFS_ADDR:2049 khong nhan ket noi"; return 1; }
  echo "nfs-server active, $NFS_ADDR:2049 mo"
}

chk_srv_disk() {
  local p
  p=$(df --output=pcent "$NFS_DIR" 2>/dev/null | tail -1 | tr -cd '0-9')
  [[ -n $p ]] || { echo "khong doc duoc df $NFS_DIR"; return 1; }
  if (( p < SRV_DISK_MAX )); then echo "$NFS_DIR dung ${p}%"; return 0; fi
  echo "$NFS_DIR dung ${p}% (nguong ${SRV_DISK_MAX}%): PV NFS va VM chung o dia nay"; return 1
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

# --- Chay ---------------------------------------------------------------------------------
mkdir -p "$STATE/kube-cache"

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
run_check nfs chk_nfs || true
run_check srv_disk chk_srv_disk || true

# Moi kiem tra Kubernetes phu thuoc apiserver: API chet thi chi bao 1 tin, cac muc sau giu nguyen trang thai
if run_check api chk_api; then
  run_check nodes chk_nodes || true
  run_check prometheus chk_prometheus || true
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
