#!/bin/sh
# Creates a user in realm "talos" of the RUNNING Keycloak and puts it in one group.
# Usage on host2: sh platform/keycloak/add-user.sh <username> <talos-viewers|talos-admins> [email]
#
# - Rights come only from the group: talos-viewers = read-only in every SSO tool,
#   talos-admins = admin (see docs/truy-cap.md). The user gets no direct roles.
# - A random temporary password is written to ~/talos-kvm/user-<username>-password.txt (600) and
#   never printed; Keycloak forces a new password at first login. Send it over a private channel.
# - Admin login: hung-admin (realm master), password from ~/talos-kvm/keycloak-admin-password.txt.
#   Passwords travel over stdin only; kcadm runs with --no-config (no token left in the pod).
# - Re-running for an existing user only checks the group membership; it does not reset the password.
set -eu
export KUBECONFIG="$HOME/talos-kvm/kubeconfig"
user=${1:?usage: add-user.sh <username> <group> [email]}
group=${2:?usage: add-user.sh <username> <group> [email]}
email=${3:-$user@talos.internal}
case "$group" in talos-viewers|talos-admins) ;; *) echo "group must be talos-viewers or talos-admins" >&2; exit 1;; esac

admin=$(head -n 1 "$HOME/talos-kvm/keycloak-admin-password.txt" | tr -d '\r\n')
pwfile="$HOME/talos-kvm/user-$user-password.txt"
umask 077
[ -s "$pwfile" ] || head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16 > "$pwfile"
newpw=$(cat "$pwfile")

printf '%s\n%s\n' "$admin" "$newpw" | kubectl -n keycloak exec -i keycloak-0 -c keycloak -- sh -c '
set -eu
read -r A; read -r P
K="/opt/keycloak/bin/kcadm.sh"
o="--no-config --server http://localhost:8080 --realm master --user hung-admin --password $A"
uid=$($K get users $o -r talos -q username="$1" -q exact=true --fields id --format csv --noquotes)
if [ -z "$uid" ]; then
  $K create users $o -r talos -s username="$1" -s email="$3" -s emailVerified=true -s enabled=true \
    -s firstName="$(echo "$1" | tr _ " ")" -s lastName=Talos -s "requiredActions=[\"UPDATE_PASSWORD\"]" >/dev/null
  uid=$($K get users $o -r talos -q username="$1" -q exact=true --fields id --format csv --noquotes)
  $K set-password $o -r talos --userid "$uid" --new-password "$P" --temporary
  echo "created user $1"
else
  echo "user $1 exists (password unchanged)"
fi
gid=$($K get groups $o -r talos -q search="$2" -q exact=true --fields id --format csv --noquotes)
[ -n "$gid" ] || { echo "group $2 not found" >&2; exit 1; }
$K update users/$uid/groups/$gid $o -r talos -s realm=talos -s userId=$uid -s groupId=$gid -n
echo "groups of $1:"; $K get users/$uid/groups $o -r talos --fields name --format csv --noquotes
' sh "$user" "$group" "$email"
echo "temporary password: $pwfile (600, not printed)"
