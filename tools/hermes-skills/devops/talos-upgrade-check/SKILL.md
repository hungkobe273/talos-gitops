---
name: talos-upgrade-check
description: Before/after check for a Talos or Kubernetes upgrade of one node of the talos-kvm cluster (node versions, Longhorn replicas, PodDisruptionBudgets that would block the drain, stuck pods, Argo CD apps, what goes down during the reboot, pods that left w3) with one read-only script. Use when the user plans or has just finished an upgrade, asks "can I upgrade w1 now", or asks whether the cluster recovered after an upgrade.
version: 1.0.0
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
1. Find the node. Accepted: node name, IP, or `w3`. Known: cp1 = `talos-w9b-tsv` 10.10.10.11 (only control plane), w1 = `talos-hdl-7jo` 10.10.10.21, w2 = `talos-iv6-z5m` 10.10.10.22, w3 = GCP VM 10.148.0.4. If the user gives no node, run without one (cluster-wide check).
2. Before: `bash scripts/upgrade-check.sh pre <node> [--expect vX.Y.Z]`. After: `bash scripts/upgrade-check.sh post <node> --expect vX.Y.Z`. The version is the Talos version the user named; without one, leave `--expect` out. Run only this script.
3. Answer in the language the user wrote in:
   - `GO (Kubernetes side)` or `OK`: one or two sentences, quote the NODES and LONGHORN lines.
   - `NO-GO n item(s)` or `CHECK n item(s)`: quote every `- ` item first, then at most 3 points on what a human should look at.
   - Then the `NOTE` lines that matter for this node (what goes down, vault-0, control plane), shortened.
4. For `pre`, always end with the `TALOS SIDE` line, quoted. That command is the upgrade script in plan mode: it reads talosctl (version, extensions, schematic) and changes nothing without `--yes`. You cannot run it (it needs talosconfig, which this account does not have, on purpose). Tell the user to run it on host2 and compare its plan with your output. Never add `--yes` to it.
5. `API: UNREACHABLE` or `NODE:`: quote it and stop. If the node is cp1 and the user is mid-upgrade, the API is expected to be down for a few minutes; say so.
6. Never cordon, drain, delete pods, restart rollouts, or run talosctl. Every fix the script suggests is for a human.

## Pitfalls
- `instance-manager-*` PDBs in longhorn-system always show 0 allowed disruptions in a dry run. Longhorn removes them when the node is really cordoned (seen 13/11). The script labels them `known`; do not call them blockers.
- `csi-attacher` / `csi-provisioner` PDBs: the upgrade script deletes these pods on the node before upgrading. Labelled `handled`; not blockers.
- w3 runs only 08:15-17:15 Mon-Fri (GCP schedule) and also stops at 10:40 on Monday and Wednesday. Outside those hours w3 NotReady is the schedule, not a fault; do not plan a w3 upgrade then.
- Pods that prefer w3 pile onto w1/w2 while w3 is drained and do not move back by themselves. `post` lists them; the human runs `kubectl -n <ns> rollout restart` for each. `argo-rollouts` may show there on any day (one replica sits on w2); mention it but it is not urgent.
- Vault is a StatefulSet with `updateStrategy: OnDelete`: the node reboot restarts vault-0, an image change does not. After the reboot vault-0 auto-unseals through GCP KMS; if it stays sealed, that is the item to report.
- cp1 is the only control plane: during its reboot every kubectl call fails. Run `post` a few minutes after the node is back.
- A Talos upgrade does not change Kubernetes. Flannel, CoreDNS and kube-proxy change only with `talosctl upgrade-k8s`; do not expect new versions of them after a node upgrade.
- Longhorn `degraded` right after `post` usually means a replica is rebuilding. Suggest re-running in 5-10 minutes before calling it a problem.

## Verification
- Every statement is backed by a quoted line of the script output.
- No command other than the script was run.

## Security
- The script only uses `kubectl get` with the read-only `hermes-readonly` account (no Secrets, no exec). Do not ask for talosconfig or admin kubeconfig.
