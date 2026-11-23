---
name: talos-upgrade-check
description: Before/after check for a Talos or Kubernetes upgrade of one node of the talos-kvm cluster (node versions, Longhorn replicas, PodDisruptionBudgets that would block the drain, stuck pods, Argo CD apps, what goes down during the reboot, pods that left w3) with one read-only script. Use when the user plans or has just finished an upgrade, asks "can I upgrade w1 now", or asks whether the cluster recovered after an upgrade.
version: 1.0.7
platforms: [linux]
metadata:
  hermes:
    tags: [upgrade, talos, kubernetes, longhorn, pdb, drain]
    category: devops
---
# talos-kvm upgrade check (before / after)

## When to Use
- Before upgrading one node (Talos image or Kubernetes): `pre`.
- After the upgrade of that node finished: `post`, with the version that should now run.
- The user asks if the cluster is ready for, or recovered from, an upgrade or a node reboot.

## Procedure
Write the whole answer in the user's language: if the user wrote Vietnamese, answer in Vietnamese (keep the quoted script lines as they are).

1. Pass the node exactly as the user wrote it: the script accepts `cp1`, `w1`, `w2`, `w3`, a node name or an IP. (cp1 = `talos-w9b-tsv` 10.10.10.11, the only control plane; w1 = `talos-hdl-7jo` 10.10.10.21; w2 = `talos-iv6-z5m` 10.10.10.22; w3 = GCP VM 10.148.0.4.) No node given: run without one (cluster-wide check).
2. Run the script right away, as your first tool call. Do not open or read the script files first; this page is all you need. Before: `bash scripts/upgrade-check.sh pre <node> [--expect vX.Y.Z]`. After: `bash scripts/upgrade-check.sh post <node> --expect vX.Y.Z`. Pick the flag by what is upgraded: a Talos node upgrade (Talos versions look like v1.14.x / v1.15.x) uses `--expect`; a Kubernetes upgrade (`talosctl upgrade-k8s`, versions like v1.37.x) uses `--expect-k8s vX.Y.Z` instead, which checks the kubelet of every node. Without a version, leave both out. Run only this script, once.
3. Answer:
   - `GO (Kubernetes side)` or `OK`: one or two sentences, quote the NODES and LONGHORN lines.
   - `NO-GO n item(s)` or `CHECK n item(s)`: quote every `- ` item first, then at most 3 points on what a human should look at.
   - Then the `NOTE` lines that matter for this node (what goes down, vault-0, control plane), shortened.
4. For `pre`, always end with the `TALOS SIDE` line (or `K8S SIDE` for a Kubernetes upgrade), quoted. That command is the upgrade script in plan mode: it reads talosctl (version, extensions, schematic) and changes nothing without `--yes`. You cannot run it (it needs talosconfig, which this account does not have, on purpose). Tell the user to run it on host2 and compare its plan with your output. Never add `--yes` to it, and never remove `--dry-run` from the K8S SIDE line.
5. `API: UNREACHABLE`, `NODE:` or `usage:`: quote it and stop. If the node is cp1 and the user is mid-upgrade, the API is expected to be down for a few minutes; say so.
6. Never cordon, drain, delete pods, restart rollouts, or run talosctl. Every fix the script suggests is for a human.

## Pitfalls
- `instance-manager-*` PDBs in longhorn-system always show 0 allowed disruptions in a dry run. Longhorn removes them when the node is really cordoned (seen 13/11). The script labels them `known`; do not call them blockers.
- `csi-attacher` / `csi-provisioner` PDBs: the upgrade script deletes these pods on the node before upgrading. Labelled `handled`; not blockers.
- w3 runs only 08:15-17:15 Mon-Fri (GCP schedule) and also stops at 10:40 on Monday and Wednesday. Outside those hours w3 NotReady is the schedule, not a fault; do not plan a w3 upgrade then.
- Pods that prefer w3 pile onto w1/w2 while w3 is drained or off. The CronJob `descheduler-w3` moves them back hourly at :45 (08:45-16:45 Mon-Fri). `post` shows them as a `NOTE` while they have been off w3 for less than 75 minutes (plus 1 hour per extra batch of 5, since descheduler-w3 moves at most 5 pods per run) (a human may run `kubectl -n <ns> rollout restart` now, or wait for :45), and as a CHECK item only after that.
- `TARGET READY since HH:MM` is when the node came back. Container restarts listed as `during the node boot (expected, not a problem)` happened in the first 10 minutes after the node or the control plane became Ready (reboot, morning cold start): do not report them as a problem. Restarts `after the nodes were up` are worth a sentence. A pod counts as stuck only if it is Pending, starting or not Ready more than 10 minutes after both its start and its node's boot; image and config errors (ImagePullBackOff, CreateContainerConfigError) count at once.
- `could not read ... (kubectl failed or timed out)`: part of the cluster could not be read, so GO/OK cannot be trusted. Quote it, say the check is incomplete and suggest re-running in a few minutes.
- Vault is a StatefulSet with `updateStrategy: OnDelete`: the node reboot restarts vault-0, an image change does not. After the reboot vault-0 auto-unseals through GCP KMS; if it stays sealed, that is the item to report.
- cp1 is the only control plane: during its reboot every kubectl call fails. Run `post` a few minutes after the node is back.
- A Talos upgrade does not change Kubernetes. Flannel, CoreDNS and kube-proxy change only with `talosctl upgrade-k8s`; do not expect new versions of them after a node upgrade.
- Longhorn `degraded` right after `post` usually means a replica is rebuilding. Suggest re-running in 5-10 minutes before calling it a problem.
- `NOTE w3 not Ready (GCP VM off on its schedule)`: normal outside 08:15-17:15 and after 10:40 Mon/Wed. It does not block upgrading cp1, w1 or w2. For a Kubernetes upgrade (`--expect-k8s`) or for w3 itself, w3 must be up: a human starts it with `gcloud compute instances start w3 --zone asia-southeast1-b`.

## Verification
- Every statement is backed by a quoted line of the script output.
- No command other than the script was run.

## Security
- The script only uses `kubectl get` with the read-only `hermes-readonly` account (no Secrets, no exec). Do not ask for talosconfig or admin kubeconfig.
