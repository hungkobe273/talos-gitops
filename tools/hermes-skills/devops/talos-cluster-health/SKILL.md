---
name: talos-cluster-health
description: Check the health of the talos-kvm Kubernetes cluster (nodes, Argo CD apps, Longhorn volumes, Vault, pods, restarts, ExternalSecrets, warning events) with one read-only script. Use for "is the cluster OK", morning checks, after a cold start or an upgrade.
version: 1.0.0
platforms: [linux]
metadata:
  hermes:
    tags: [kubernetes, talos, argocd, longhorn, health]
    category: devops
---
# Talos cluster health

## When to Use
- The user asks whether the cluster is healthy, what is broken, or for a morning check.
- After host2 boots (cold start), after an upgrade, after draining a node.

## Procedure
1. Run `bash scripts/cluster-health.sh` with the terminal tool. Do not run other kubectl commands first: the script already collects everything in one pass.
2. Read the first line: `GREEN` means nothing to do; say so in one sentence.
3. If it says `CHECK n item(s)`, list only the lines that are not OK, in the user's language, with the likely cause from Pitfalls below.
4. Suggest at most 3 read-only follow-up commands (for example `kubectl describe pod`, `kubectl logs --previous`). Never run write commands (apply, delete, rollout restart, scale); propose them for a human.

## Pitfalls
- Exit code 2 / `API: UNREACHABLE`: the cluster is off (host2 powered off, or before 08:30 cold start ends) or the kubeconfig is wrong. Do not retry in a loop.
- Right after a cold start (first ~10 minutes) Keycloak, Vault and Grafana are still starting: `NotReady` and `Unhealthy` probe events there are normal.
- `VAULT: NOT READY` usually means sealed or the pod is restarting; it unseals itself through GCP KMS. External Secrets then retries on its own (up to ~16 minutes back-off).
- Longhorn volumes that are `detached` are skipped on purpose (Grafana/Vault scaled to 0 in the evening).
- Warning events are counts by reason and object only; probe failures during a rollout are expected.
- w3 runs on GCP 08:15–17:15; outside these hours it shows NotReady, which is expected.

## Verification
- The answer quotes the first line of the script output.
- Every problem mentioned appears in the script output; nothing is invented.

## Security
- The script prints names, states and reasons only. It never reads Secrets or ConfigMaps and never prints event messages or logs, because the output goes to a cloud LLM.
- Use the `hermes-readonly` kubeconfig (platform/hermes), not the admin kubeconfig.
