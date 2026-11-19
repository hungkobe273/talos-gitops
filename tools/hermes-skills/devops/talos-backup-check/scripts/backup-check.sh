#!/usr/bin/env bash
# Daily backup health of talos-kvm (etcd, Keycloak, Vault, encrypted bundle on B2 and GCS). Read-only.
# Reads /var/lib/talos-backup/status.json (written by host2/bin/talos-backup-status.sh after each backup run).
# Exit: 0 OK, 1 something to look at, 2 status file missing or unreadable.
set -uo pipefail
# System python on purpose: inside Hermes, `python3` on PATH is Hermes' own venv.
PY=/usr/bin/python3; [ -x "$PY" ] || PY=python3
exec "$PY" -I "$(dirname "$(readlink -f "$0")")/backup_check.py" "$@"
