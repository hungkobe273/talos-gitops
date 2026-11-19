---
name: talos-backup-check
description: Check the daily backup of the talos-kvm cluster (etcd snapshot, Keycloak pg_dump, Vault snapshot, encrypted offsite bundle with Sealed Secrets keys, copies on Backblaze B2 and Google Cloud Storage) with one read-only script. Use when the user asks whether backups are OK, before an upgrade or other risky change, or in a morning check.
version: 1.0.0
platforms: [linux]
metadata:
  hermes:
    tags: [backup, etcd, vault, keycloak, offsite, disaster-recovery]
    category: devops
---
# talos-kvm backup check

## When to Use
- The user asks if the backup ran, is recent, or is complete.
- Before a risky change (Talos/Kubernetes upgrade, Vault or Keycloak upgrade): a fresh successful backup should exist.
- As part of a morning check together with `talos-cluster-health`.

## Procedure
1. Run `bash scripts/backup-check.sh` with the terminal tool. No arguments. Do not run other commands first: the script reads the status file that the backup itself writes after every run.
2. First line `OK`: answer in one or two sentences in the language the user wrote in: when the last good backup was (quote the LAST OK line) and that all six parts were present (quote the PARTS line).
3. First line `CHECK n item(s)`: list every `- ` item, quoted, then the lines that support it (LAST RUN, the ERROR line under it, PARTS). Say what a human should look at next, at most 3 points. Suggest only these read-only steps: `journalctl -u talos-etcd-backup.service -n 50` (run by the human on host2), the Telegram alert of that run, or re-running this skill after the next run.
4. First line `SETUP:`: quote it and stop. Do not search for backup files, do not read other users' home directories, do not install anything.
5. Never run the backup, never restart or start any unit, never touch `/var/lib/talos-backup`. Starting a backup is a human decision.

## Pitfalls
- The cluster is off at night and on weekends. The allowed age is 26 h plus 24 h per Saturday/Sunday, already computed in the LAST OK line. Do not apply your own threshold.
- `LAST RUN ... skipped` is normal: the 16:45 timer finds cp1 off after `talos-cluster-stop.sh`, which already made a backup before shutdown.
- `EARLIER FAILURES (recovered)` are past failures followed by successful runs. Mention them only if the user asks for history.
- Sizes: the etcd snapshot is about 65 MiB, the bundle about 15 MiB. Only the script's own size item means a real jump; small day-to-day changes are normal.
- `2 sealed-secrets keys` is expected (the controller rotates keys every 30 days and keeps old ones). `0` would make the bundle useless for SealedSecrets.
- The script proves that files were written and uploads returned OK. It does not prove a restore works; say so if the user asks "can we restore".

## Verification
- Every statement is backed by a quoted line of the script output.
- No command other than the script was run.

## Security
- The status file has only names, sizes, times and OK/ERROR lines; no keys, no file contents. The backups themselves are in ngochung's home (700) and encrypted with a GPG key that is not on host2. Do not try to read them.
