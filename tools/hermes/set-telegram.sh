#!/bin/bash
# Telegram gateway for Hermes on host2 (27/11/2026): bot token + allowed Telegram user IDs
# into /home/hermes/.hermes/.env. Design: docs/de-xuat-hermes-agent.md section "Telegram".
# Usage on host2: cd ~/talos-gitops && git pull -q --rebase && sudo bash tools/hermes/set-telegram.sh
# The token is read without echo: not in argv, shell history or any log. Re-running replaces both lines.
# Only the listed user IDs may talk to the bot (Hermes denies everyone else, DMs and groups).
# Adding people later: re-run, press Enter at the token prompt to keep the current token, and give
# the FULL list of IDs (it replaces the old list). Then: sudo systemctl restart hermes-gateway
# Group chats (27/11): every member of a listed group may use the bot there. Group ID is negative,
# read it from ~hermes/.hermes/logs/gateway.log ("Sending response ... to -<id>"). Enter = none.
set -eu
ENV=/home/hermes/.hermes/.env
[ -f "$ENV" ] || { echo "missing $ENV (install Hermes first)" >&2; exit 1; }
read -rsp "Telegram bot token (from @BotFather, Enter = keep current): " t </dev/tty; echo
if [ -z "$t" ]; then
  t=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$ENV" | tail -1)
  [ -n "$t" ] || { echo "no token set yet, nothing written" >&2; exit 1; }
fi
case "$t" in [0-9]*:*) ;; *) echo "does not look like a bot token (<digits>:<text>), nothing written" >&2; exit 1 ;; esac
read -rp "Allowed Telegram user IDs, comma-separated (from @userinfobot): " u </dev/tty
case "$u" in ''|*[!0-9,]*) echo "user IDs must be digits separated by commas, nothing written" >&2; exit 1 ;; esac
read -rp "Allowed group chat IDs, comma-separated, negative (Enter = none): " g </dev/tty
case "$g" in *[!0-9,-]*) echo "group IDs must be numbers separated by commas, nothing written" >&2; exit 1 ;; esac
tmp=$(mktemp "$ENV.XXXXXX")
grep -vE '^TELEGRAM_(BOT_TOKEN|ALLOWED_USERS|GROUP_ALLOWED_CHATS)=' "$ENV" > "$tmp" || true
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_ALLOWED_USERS=%s\n' "$t" "$u" >> "$tmp"
[ -z "$g" ] || printf 'TELEGRAM_GROUP_ALLOWED_CHATS=%s\n' "$g" >> "$tmp"
unset t
chown hermes:hermes "$tmp"; chmod 600 "$tmp"; mv -f "$tmp" "$ENV"
echo "TELEGRAM_BOT_TOKEN lines: $(grep -c '^TELEGRAM_BOT_TOKEN=..*' "$ENV"), allowed users: $(echo "$u" | tr ',' '\n' | grep -c .), allowed groups: $(echo "$g" | tr ',' '\n' | grep -c . || true)"
