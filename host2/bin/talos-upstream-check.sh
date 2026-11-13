#!/usr/bin/env bash
# talos-upstream-check.sh - bao Telegram khi upstream co ban moi cho thanh phan dang cho ban va.
# 13/11: trivyignore.yaml (platform/image-scan) bo qua co han 30/11 CVE cua Longhorn v1.13.0 va flannel (theo Talos
# v1.14.2). Script nay bao ngay khi co ban moi de nang, thay vi nho tay vao GitHub.
#
# Chay boi talos-upstream-check.timer (09:00 T2-T6). Moi ban moi chi bao 1 lan (nho trong StateDirectory).
# Dau vao (tu unit):
#   CREDENTIALS_DIRECTORY  co file telegram-bot-token (LoadCredential=)
#   TG_CHAT_ID             chat id Telegram
#   STATE_DIRECTORY        noi luu ban da bao
# Chay thu khong gui Telegram: DRY_RUN=1 STATE_DIRECTORY=$(mktemp -d) ~/bin/talos-upstream-check.sh
set -euo pipefail

# repo GitHub | ban da xet toi (bao khi co ban moi hon) | viec can lam khi co ban moi
# Talos: cum chay v1.14.2, nhung v1.14.6 (flannel v0.28.10) van con CVE-2026-111497 (Trivy 13/11), nen moc la v1.14.6.
WATCH=(
  "longhorn/longhorn|v1.13.0|Nang Longhorn, go SUSE-SU-2026:4619-1 va GHSA-hq85-5cpj-mr62 khoi trivyignore"
  "siderolabs/talos|v1.14.6|Kiem flannel trong release notes bang Trivy; neu het CVE-2026-111497 thi nang Talos va go khoi trivyignore"
)

STATE="${STATE_DIRECTORY:-/var/lib/talos-upstream-check}"
log() { echo "upstream-check: $*"; }

send() {
  if [[ ${DRY_RUN:-0} == 1 ]]; then log "DRY_RUN, khong gui: $1"; return 0; fi
  [[ -r ${CREDENTIALS_DIRECTORY:-}/telegram-bot-token ]] || { log "thieu credential telegram-bot-token"; return 1; }
  [[ -n ${TG_CHAT_ID:-} ]] || { log "thieu TG_CHAT_ID"; return 1; }
  local token
  token=$(tr -d '[:space:]' < "$CREDENTIALS_DIRECTORY/telegram-bot-token")
  # Token di qua curl --config tu stdin, khong nam tren dong lenh (ps khong thay).
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" \
    | curl -sS --max-time 20 -o /dev/null --config - \
        --data-urlencode "chat_id=$TG_CHAT_ID" --data-urlencode "text=$1"
}

# Ban release (khong tinh pre-release/draft) moi nhat cua repo, cung major.minor voi ban dang chay va moi nhat noi chung.
latest() {
  local repo=$1 cur=$2 json
  json=$(curl -fsS --max-time 20 -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$repo/releases?per_page=50") || return 1
  # Script python qua -c, du lieu GitHub qua stdin (qua bien moi truong thi vuot gioi han do dai).
  python3 -c '
import json, re, sys
cur = sys.argv[1]
def v(t):
    m = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", t)
    return tuple(map(int, m.groups())) if m else None
c = v(cur)
tags = [r["tag_name"] for r in json.load(sys.stdin) if not r["prerelease"] and not r["draft"] and v(r["tag_name"])]
same = [t for t in tags if v(t)[:2] == c[:2] and v(t) > c]
newer = [t for t in tags if v(t) > c]
print(max(same, key=v) if same else "-", max(newer, key=v) if newer else "-")
' "$cur" <<<"$json"
}

mkdir -p "$STATE"
rc=0
for w in "${WATCH[@]}"; do
  IFS='|' read -r repo cur todo <<<"$w"
  if ! out=$(latest "$repo" "$cur"); then log "$repo: khong doc duoc GitHub"; rc=1; continue; fi
  read -r patch newest <<<"$out"
  log "$repo: da xet toi $cur, ban va cung nhanh $patch, moi nhat $newest"
  [[ $newest == - ]] && continue
  f="$STATE/$(echo "$repo" | tr / _)"
  [[ $(cat "$f" 2>/dev/null) == "$newest" ]] && continue
  msg="[upstream] $repo co ban moi: cung nhanh $patch, moi nhat $newest (da xet toi $cur). $todo. Han trivyignore 30/11."
  send "$msg" && echo "$newest" > "$f" || rc=1
done
exit $rc
