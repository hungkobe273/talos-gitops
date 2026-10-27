#!/bin/sh
# Creates the token the 16:45 backup uses for `vault operator raft snapshot save`.
# Runs INSIDE vault-0 via run-configure.sh; prints ONLY the new token on stdout, so run:
#   sh platform/vault/run-configure.sh snapshot-token.sh > ~/talos-kvm/vault-snapshot-token
# Policy "raft-snapshot" can read the snapshot endpoint and nothing else.
# Periodic token (720h): it never expires as long as it is renewed within 30 days;
# ~/bin/vault-snapshot.sh renews it on every run.
set -eu
vault policy write raft-snapshot - >/dev/null <<'EOF'
path "sys/storage/raft/snapshot" { capabilities = ["read"] }
path "auth/token/renew-self"     { capabilities = ["update"] }
EOF
vault token create -orphan -policy=raft-snapshot -period=720h \
  -display-name=host2-backup -field=token
