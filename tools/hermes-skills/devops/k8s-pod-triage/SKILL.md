---
name: k8s-pod-triage
description: Find out why one Kubernetes pod in the talos-kvm cluster is not healthy (CrashLoopBackOff, not Ready, probe failures, OOMKilled, Pending, many restarts) with one read-only script that collects state, probes, events and the last log lines. Use when the user names a pod or a deployment, or after talos-cluster-health reports a pod.
version: 1.0.0
platforms: [linux]
metadata:
  hermes:
    tags: [kubernetes, pod, troubleshooting, logs, events]
    category: devops
---
# Kubernetes pod triage

## When to Use
- The user asks why a pod is crashing, restarting, not Ready, Pending, or has probe failures.
- `talos-cluster-health` listed a pod under not healthy, restarts or warning events.
- The user gives a Deployment/StatefulSet name: pass it as the prefix, the script picks a not-Ready replica first.

## Procedure
1. You need a namespace and a pod name (or prefix). If the user did not give the namespace, ask once (clarify tool); do not run `kubectl get pods -A` to search.
2. Run `bash scripts/pod-triage.sh <namespace> <pod-or-prefix>` with the terminal tool. Do not run other kubectl commands first: the script already collects everything in one pass.
3. First line `OK`: say the pod looks fine in one sentence and quote the CONTAINER line.
4. First line `CHECK`: answer in the user's language, in this order:
   - What is wrong, quoting the exact lines (CONDITIONS, CONTAINER, LAST TERMINATED, EVENTS, LOGS) that show it.
   - The most likely cause, only if a quoted line supports it. If the lines do not show a cause, say "not clear from this output".
   - At most 3 next steps. Read-only commands you may suggest: `kubectl describe pod`, `kubectl logs --previous`, `kubectl get events`, `kubectl top pod`. Write actions (delete pod, rollout restart, edit limits or probes) are proposals for a human, never run by you.

## Pitfalls
- `Readiness probe failed ... context deadline exceeded` with `ready=True` and `restarts=0`: the probe sometimes takes longer than its `timeout`. On this cluster the usual reason is slow IO on host2's single HDD (cold start, backups at 16:45, image pulls). Say so as a possibility, not as a fact.
- `LAST TERMINATED: reason=OOMKilled`: the container hit its memory limit; compare with `RESOURCES lim`.
- `exit=137` without OOMKilled: killed from outside (liveness probe or node pressure). `exit=143`: normal SIGTERM on shutdown or rollout.
- `Pending` with `PodScheduled=False`: scheduling (taints, w3 `cloud=gcp:NoSchedule`, resources). Events show the scheduler message.
- `ImagePullBackOff`: registry or tag; logs are empty in that case.
- w3 (GCP) runs 08:15–17:15. Pods on w3 outside these hours are expected to be unreachable.
- Logs show at most 12 lines (error-like lines first). If the cause is not there, suggest `kubectl logs --previous --tail=200` for a human instead of guessing.
- Longhorn `Error during scrape ... metrics.k8s.io`: the cluster has no metrics-server; harmless noise, not the cause of anything.
- Keycloak `REFRESH_TOKEN_ERROR ... Token is not active`: a browser tab kept refreshing after its session expired; harmless unless users report they cannot log in.
- `LAST TERMINATED ... (old, e.g. evening shutdown)`: the cluster is powered off every evening, so most pods show 1 old restart. Ignore it.
- Do not invent a rollout, cold start or upgrade unless the output shows one (container `since` a few minutes, restarts, events).

## Verification
- Every problem mentioned is backed by a quoted line of the script output.
- No write command was run.

## Security
- Lines are redacted before printing (company LAN IPs, tokens, passwords, JWT/base64 blobs, keys). Do not try to get the unredacted value.
- The script never reads env values, Secrets or ConfigMaps. Do not run `kubectl get secret`, `kubectl exec` or `describe` on Secrets: the read-only ServiceAccount cannot, and the output would go to a cloud LLM.
- Use the `hermes-readonly` kubeconfig (platform/hermes), not the admin kubeconfig.
