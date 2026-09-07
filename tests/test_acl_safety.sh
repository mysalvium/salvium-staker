#!/bin/sh
set -eu

# shellcheck source=scripts/acl-safety.sh
. "$(dirname "$0")/../scripts/acl-safety.sh"

getfacl() {
  printf '%s\n' 'user::rw-' 'group::---' 'other::---'
}
nfs4xdr_getfacl() {
  printf '%s\n' '# trivial_acl: true'
}
path_has_trivial_acl /test/path

nfs4xdr_getfacl() {
  printf '%s\n' '# trivial_acl: false' 'user:apps:rwxpDdaARWc--s:------I:allow'
}
if path_has_trivial_acl /test/path; then
  echo 'non-trivial NFSv4 ACL was accepted' >&2
  exit 1
fi

nfs4xdr_getfacl() {
  return 1
}
getfacl() {
  printf '%s\n' 'user::rw-' 'user:apps:rw-' 'group::---' 'mask::rw-' 'other::---'
}
if path_has_trivial_acl /test/path; then
  echo 'extended POSIX ACL was accepted' >&2
  exit 1
fi

nfs4xdr_getfacl() {
  return 1
}
getfacl() {
  return 1
}
if path_has_trivial_acl /test/path; then
  echo 'uninspectable ACL was accepted' >&2
  exit 1
fi

echo 'ACL safety tests passed.'
