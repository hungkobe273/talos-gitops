#!/bin/bash
# Puts the OpenRouter key into /home/hermes/.hermes/.env (17/11/2026).
# Usage on host2: cd ~/talos-gitops && git pull -q --rebase && sudo bash tools/hermes/set-openrouter-key.sh
# The key is read from the terminal without echo: not in argv, shell history or any log.
# Re-running replaces the old line. Prints only whether a key is set.
set -eu
ENV=/home/hermes/.hermes/.env
[ -f "$ENV" ] || { echo "missing $ENV (install Hermes first)" >&2; exit 1; }
read -rsp "OpenRouter key: " k </dev/tty; echo
case "$k" in sk-or-*) ;; *) echo "does not look like an OpenRouter key (sk-or-...), nothing written" >&2; exit 1 ;; esac
tmp=$(mktemp "$ENV.XXXXXX")
grep -v '^OPENROUTER_API_KEY=' "$ENV" > "$tmp" || true
printf 'OPENROUTER_API_KEY=%s\n' "$k" >> "$tmp"
unset k
chown hermes:hermes "$tmp"; chmod 600 "$tmp"; mv -f "$tmp" "$ENV"
echo "OPENROUTER_API_KEY lines: $(grep -c '^OPENROUTER_API_KEY=..*' "$ENV")"
