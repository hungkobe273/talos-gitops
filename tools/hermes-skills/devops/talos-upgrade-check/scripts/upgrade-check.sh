#!/usr/bin/env bash
# Before/after check for a Talos or Kubernetes upgrade of talos-kvm. Read-only (kubectl get).
# Usage: upgrade-check.sh pre  [node-name-or-ip]
#        upgrade-check.sh post [node-name-or-ip] [--expect vX.Y.Z]
# Exit: 0 GO/OK, 1 NO-GO/CHECK, 2 usage or API unreachable.
# KUBECONFIG must point at the hermes-readonly kubeconfig (platform/hermes) or any read-only one.
set -uo pipefail
# System python on purpose: inside Hermes, `python3` on PATH is Hermes' own venv.
PY=/usr/bin/python3; [ -x "$PY" ] || PY=python3
exec "$PY" -I "$(dirname "$(readlink -f "$0")")/upgrade_check.py" "$@"
