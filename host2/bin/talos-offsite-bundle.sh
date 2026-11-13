#!/bin/bash
# Encrypted off-host bundle (2026-10-22): newest etcd snapshot + newest Keycloak pg_dump + Vault snapshot + cluster
# secrets and configs, encrypted to the laptop's GPG key (host2 holds only the public key). Laptop pulls ~/talos-kvm/offsite/.
# 2026-11-13 (audit S3 buoc 3 + #18 + dr3 buoc 2):
#   - Xuat moi lan: tat ca khoa Sealed Secrets (nhan sealedsecrets.bitnami.com/sealed-secrets-key, khoa tu xoay 30 ngay,
#     ban xuat tay 15/10 khong du), Secret talos-internal-ca (cert-manager) va velero-repo-credentials (velero).
#     Ghi vao thu muc tam tren /dev/shm (RAM, umask 077), xoa khi thoat; khong ghi ban ro ra HDD.
#     kubectl loi -> backup Failed (OnFailure bao Telegram): khong co khoa thi bundle khong dung de khoi phuc.
#   - Them file dung lai host2/w3: w3.yaml, patches/, vault-snapshot-token, coldstart-watch.sh, unit gcp-tunnel,
#     coldstart, resume, watchdog, khoa ~/.ssh/gcp-tunnel.
#   - Bo $HARBOR (Harbor go 09/11).
#   - KHONG them /etc/talos-* (root 700: tar loi -> backup loi -> stop script khong tat duoc cum).
set -euo pipefail
umask 077
K=18EB2C2685E44E04420E4FA8E84A7734379A711E
ENC_SUB=A3A3652F43CEBFFD
B=$HOME/talos-kvm; OUT=$B/offsite; KEEP=3
export KUBECONFIG="${KUBECONFIG:-$B/kubeconfig}"
KC="kubectl --request-timeout=20s"
mkdir -p "$OUT"
ETCD=$(ls -1t "$B"/etcd-backups/* 2>/dev/null | head -1 || true)
PG=$(ls -1t "$B"/keycloak-backups/keycloak-*.dump 2>/dev/null | head -1 || true)
VAULT=$(ls -1t "$B"/vault-backups/vault-*.snap 2>/dev/null | head -1 || true)
[ -s "$ETCD" ] || { echo "ERROR: no etcd snapshot" >&2; exit 1; }
[ -s "$PG" ] || { echo "ERROR: no keycloak dump" >&2; exit 1; }
[ -s "$VAULT" ] || { echo "ERROR: no vault snapshot" >&2; exit 1; }

LIST=$(mktemp); KD=$(mktemp -d /dev/shm/talos-bundle.XXXXXX)
trap 'rm -f "$LIST"; rm -rf "$KD"' EXIT
$KC -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > "$KD/sealed-secrets-keys.yaml"
NKEYS=$(grep -c '^- apiVersion' "$KD/sealed-secrets-keys.yaml" || true)
(( NKEYS >= 1 )) || { echo "ERROR: no sealed-secrets key exported" >&2; exit 1; }
$KC -n cert-manager get secret talos-internal-ca -o yaml > "$KD/talos-internal-ca.yaml"
$KC -n velero get secret velero-repo-credentials -o yaml > "$KD/velero-repo-credentials.yaml"

for f in "$ETCD" "$PG" "$VAULT" "$B"/vault-init.json "$B"/vault-snapshot-token "$B"/secrets.yaml "$B"/talosconfig "$B"/kubeconfig \
         "$B"/cp1.yaml "$B"/w1.yaml "$B"/w2.yaml "$B"/w3.yaml "$B"/patch-*.yaml "$B"/patches/*.yaml \
         "$B"/sealed-secrets-key-backup-*.yaml "$B"/argocd-deploy-key "$B"/argocd-deploy-key.pub "$B"/*-password.txt \
         "$B"/coldstart-watch.sh "$HOME"/bin/*.sh "$HOME"/.ssh/gcp-tunnel "$HOME"/.ssh/gcp-tunnel.pub \
         /etc/systemd/system/talos-etcd-backup* /etc/systemd/system/talos-watchdog* /etc/systemd/system/talos-cluster-resume.service \
         /etc/systemd/system/gcp-tunnel-*.service /etc/systemd/system/coldstart-watch.service /etc/haproxy/haproxy.cfg; do
  [ -n "$f" ] && [ -e "$f" ] && echo "${f#/}"
done > "$LIST"
F="$OUT/talos-offsite-$(date +%Y%m%d-%H%M).tar.gz.gpg"
# Hai phan: file tren dia (duong dan tuyet doi bo "/") va thu muc khoa tren RAM (vao bundle duoi ten k8s-secrets/).
tar -czf - -C / -T "$LIST" --transform "s,^${KD#/},k8s-secrets," "${KD#/}" \
  | gpg --batch --yes --trust-model always -r "$K" --encrypt -o "$F.part"
PK=$(gpg --batch --list-packets "$F.part" 2>&1 || true); grep -q "keyid $ENC_SUB" <<< "$PK" || { echo "ERROR: not encrypted to $ENC_SUB" >&2; rm -f "$F.part"; exit 1; }
mv "$F.part" "$F"
ls -1t "$OUT"/talos-offsite-*.tar.gz.gpg | tail -n +$((KEEP+1)) | xargs -r rm -f
echo "OK: offsite $(basename "$F") $(du -h "$F" | cut -f1) $(( $(wc -l < "$LIST") + 3 )) files, $NKEYS sealed-secrets key (etcd $(basename "$ETCD"), pg $(basename "$PG"), vault $(basename "$VAULT"))"
