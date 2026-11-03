#!/bin/sh
# Creates an administrator in realm "master" of the RUNNING Keycloak (Keycloak admin console,
# https://keycloak.talos.internal/admin/). Same pattern as add-user.sh, which only handles realm talos.
# Usage on host2: sh platform/keycloak/add-master-admin.sh <username> [email]
#
# - The user gets realm role "admin" of realm master = full rights on every realm (same as hung-admin).
# - A random temporary password is written to ~/talos-kvm/user-master-<username>-password.txt (600) and
#   never printed; Keycloak forces a new password at first login. Send it over a private channel.
# - Admin login: hung-admin (realm master), password from ~/talos-kvm/keycloak-admin-password.txt.
#   Passwords travel over stdin only; kcadm runs with --no-config (no token left in the pod).
# - Re-running for an existing user only checks the role; it does not reset the password.
set -eu
export KUBECONFIG="$HOME/talos-kvm/kubeconfig"
user=${1:?usage: add-master-admin.sh <username> [email]}
email=${2:-$user@talos.internal}

admin=$(head -n 1 "$HOME/talos-kvm/keycloak-admin-password.txt" | tr -d '\r\n')
pwfile="$HOME/talos-kvm/user-master-$user-password.txt"
umask 077
[ -s "$pwfile" ] || head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16 > "$pwfile"
newpw=$(cat "$pwfile")

printf '%s\n%s\n' "$admin" "$newpw" | kubectl -n keycloak exec -i keycloak-0 -c keycloak -- sh -c '
set -eu
read -r A; read -r P
K="/opt/keycloak/bin/kcadm.sh"
o="--no-config --server http://localhost:8080 --realm master --user hung-admin --password $A"
uid=$($K get users $o -r master -q username="$1" -q exact=true --fields id --format csv --noquotes)
if [ -z "$uid" ]; then
  $K create users $o -r master -s username="$1" -s email="$2" -s emailVerified=true -s enabled=true \
    -s firstName="$(echo "$1" | tr _ " ")" -s lastName=Admin -s "requiredActions=[\"UPDATE_PASSWORD\"]" >/dev/null
  uid=$($K get users $o -r master -q username="$1" -q exact=true --fields id --format csv --noquotes)
  $K set-password $o -r master --userid "$uid" --new-password "$P" --temporary
  echo "created user $1 in realm master"
else
  echo "user $1 exists in realm master (password unchanged)"
fi
$K add-roles $o -r master --uusername "$1" --rolename admin
echo "realm roles of $1:"; $K get-roles $o -r master --uusername "$1" --effective --fields name --format csv --noquotes | grep -x -E "admin|create-realm" || true
' sh "$user" "$email"
echo "temporary password: $pwfile (600, not printed)"
