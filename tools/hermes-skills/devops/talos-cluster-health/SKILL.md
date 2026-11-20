---
name: talos-cluster-health
description: Check the health of the talos-kvm Kubernetes cluster (nodes, Argo CD apps, Longhorn volumes, Vault, pods, restarts, ExternalSecrets, warning events) with one read-only script. Use for "is the cluster OK", morning checks, after a cold start or an upgrade.
version: 1.0.5
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
Write the whole answer in the user's language: if the user wrote Vietnamese, answer in Vietnamese (keep the quoted script lines as they are).

1. Run `bash scripts/cluster-health.sh` right away, as your first tool call. Do not open or read the script files first; this page is all you need. Do not run other kubectl commands before or after it: the script already collects everything in one pass. Run it only once.
2. Read the first line: `GREEN` means nothing to do; say so in one sentence.
3. If it says `CHECK n item(s)`, list only the lines that are not OK, in the user's language. Add a cause only when a Pitfall below names that exact line; otherwise say the cause is not in the output.
4. Suggest at most 3 read-only follow-up commands (for example `kubectl describe pod`, `kubectl logs --previous`). Never run write commands (apply, delete, rollout restart, scale); propose them for a human.

## Pitfalls
- Exit code 2 / `API: UNREACHABLE`: the cluster is off (host2 powered off, or the morning cold start has not finished, often until about 09:00) or the kubeconfig is wrong. Do not retry in a loop.
- `COLD START: control plane Ready since HH:MM` appears for 2 hours after the morning start. Restarts in the first 10 minutes after the nodes came up are listed as `more during the cold start (expected)` and are not counted (an `OOMKilled` restart is always counted); do not report them as a problem. Warning events from the first 30 minutes after that time (Unhealthy, FailedMount, NetworkNotReady) are the same start: say the count once, as a consequence of the cold start, not as separate problems.
- `VAULT: NOT READY` usually means sealed or the pod is restarting; it unseals itself through GCP KMS. External Secrets then retries on its own (up to ~16 minutes back-off).
- Longhorn volumes that are `detached` are skipped on purpose (Grafana/Vault scaled to 0 in the evening).
- Warning events are counts by reason and object only; the script cannot tell why they happened. Do not guess a cause
  (no "rollout", "cold start" or "expected" unless the output itself shows a restart or a recent cold start).
  Say the count and the object, and suggest `kubectl -n <ns> describe pod <pod>` for a human to read the probe message.
- w3 runs on GCP 08:15–17:15 Mon–Fri and also stops at 10:40 on Monday and Wednesday; outside those hours w3 NotReady is the schedule, not a fault. Pods that keep data on w3 (Prometheus, VictoriaLogs) then stay Pending or Terminating until w3 is back.
- `UNKNOWN (kubectl get failed or timed out)`: that part could not be read, so nothing is known about it; never call it healthy. Often a slow API right after a cold start: suggest re-running in a few minutes.
- `NODE REBOOT: <node> Ready since HH:MM, long after the control plane`: that worker came up more than 30 minutes after the cold start, so it rebooted or was restarted by hand. Restarts on it are counted, not excused. Report it; the cause is not in the output.
- `W3 PREFERRED` lists workloads that prefer w3 but have no pod there. The CronJob `descheduler-w3` moves them back hourly at :45 (08:45–16:45 Mon–Fri), so a short time off w3 is normal and not counted. It is counted only with "descheduler-w3 did not move them": then suggest, for a human, `kubectl -n descheduler logs job/<latest descheduler-w3 job>` and `kubectl -n <ns> rollout restart <kind>/<name>`.
- `old Failed left by node shutdown/eviction` are pods the kubelet ended (w3 stop, memory pressure). Their replacement is checked separately; these leftovers are harmless and not a problem to report.

## Verification
- The answer quotes the first line of the script output.
- Every problem mentioned appears in the script output; nothing is invented.

## Security
- The script prints names, states and reasons only. It never reads Secrets or ConfigMaps and never prints event messages or logs, because the output goes to a cloud LLM.
- Use the `hermes-readonly` kubeconfig (platform/hermes), not the admin kubeconfig.
