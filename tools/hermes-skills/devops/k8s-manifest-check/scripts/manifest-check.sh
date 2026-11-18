#!/usr/bin/env bash
# Check Kubernetes YAML against this cluster before it goes to Git: schema (cluster OpenAPI),
# Pod Security of the target namespace, Kyverno image policy of this repo, best practices.
# Usage: manifest-check.sh <file.yaml | -> [namespace]     (- = YAML on stdin)
# Read-only (GET only). Values are not printed, so the output is safe to give a cloud LLM.
# Exit: 0 no error, 1 errors found, 2 usage / file / API unreachable.
# KUBECONFIG must point at the hermes-readonly kubeconfig (platform/hermes) or any read-only one.
set -uo pipefail
# System python on purpose: inside Hermes, `python3` on PATH is Hermes' own venv (no PyYAML).
# /usr/bin/python3 has PyYAML from the Ubuntu package python3-yaml. Never pip install for this.
PY=/usr/bin/python3; [ -x "$PY" ] || PY=python3
exec "$PY" -I "$(dirname "$(readlink -f "$0")")/manifest_check.py" "$@"
