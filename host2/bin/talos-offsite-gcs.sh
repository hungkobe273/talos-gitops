#!/bin/bash
# Copy the newest encrypted bundle to Google Cloud Storage (second offsite copy next to B2).
# Runs as an ExecStart of talos-etcd-backup.service (drop-in 35-gcs.conf), after 20-offsite.conf.
# Credential: service account talos-backup-writer, roles/storage.objectCreator on the bucket only
# (can add objects, cannot read, overwrite or delete them). Old bundles expire by bucket lifecycle (30 days).
# Only curl, openssl and python3 are needed (no gcloud on host2).
set -euo pipefail
C=${CREDENTIALS_DIRECTORY:?run via talos-etcd-backup.service}
BUCKET=talos-kvm-offsite-gcs-vtc
F=$(ls -1t "$HOME"/talos-kvm/offsite/talos-offsite-*.tar.gz.gpg | head -n1)

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
EMAIL=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["client_email"])' "$C/gcs-sa")
NOW=$(date +%s)
HDR=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
CLM=$(printf '{"iss":"%s","scope":"https://www.googleapis.com/auth/devstorage.read_write","aud":"https://oauth2.googleapis.com/token","iat":%d,"exp":%d}' \
  "$EMAIL" "$NOW" $((NOW + 600)) | b64url)
SIG=$(printf '%s.%s' "$HDR" "$CLM" | openssl dgst -sha256 -sign \
  <(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["private_key"])' "$C/gcs-sa") | b64url)
TOK=$(curl -fsS --max-time 30 -d "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=$HDR.$CLM.$SIG" \
  https://oauth2.googleapis.com/token | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

NAME="bundles/$(basename "$F")"
curl -fsS --max-time 600 -H @<(printf 'Authorization: Bearer %s' "$TOK") \
  -H "Content-Type: application/octet-stream" --data-binary "@$F" \
  "https://storage.googleapis.com/upload/storage/v1/b/$BUCKET/o?uploadType=media&name=${NAME//\//%2F}&ifGenerationMatch=0" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("OK: GCS uploaded",d["name"],d["size"],"bytes md5",d["md5Hash"])'
