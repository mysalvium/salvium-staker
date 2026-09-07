#!/bin/sh
# Shared host-side checks for ACLs that cannot be represented by Unix mode bits.

path_has_trivial_acl() {
  acl_path=$1
  acl_inspected=0

  # TrueNAS exposes native ZFS/NFSv4 ACLs through this helper.  getfacl(1)
  # presents only a lossy mode-bit view for those ACLs, so a non-trivial native
  # ACL must be rejected before consulting the POSIX view.
  if command -v nfs4xdr_getfacl >/dev/null 2>&1; then
    if native_acl=$(nfs4xdr_getfacl "$acl_path" 2>/dev/null); then
      acl_inspected=1
      printf '%s\n' "$native_acl" | grep -q '^# trivial_acl: true$' || return 1
    fi
  fi

  # Reject named users/groups, masks, and default ACLs on POSIX filesystems.
  # owner::, group::, and other:: are the ordinary mode-bit entries.
  if command -v getfacl >/dev/null 2>&1; then
    posix_acl=$(getfacl -cp "$acl_path" 2>/dev/null) || return 1
    acl_inspected=1
    if printf '%s\n' "$posix_acl" \
      | grep -Eq '^(default:|user:[^:]|group:[^:]|mask::)'; then
      return 1
    fi
  fi

  [ "$acl_inspected" -eq 1 ]
}

require_trivial_acl() {
  acl_path=$1
  acl_label=${2:-path}
  if ! path_has_trivial_acl "$acl_path"; then
    printf '%s has a non-trivial or unreadable ACL: %s\n' "$acl_label" "$acl_path" >&2
    printf '%s\n' 'Use a dedicated non-shared dataset and remove inherited/named ACL entries.' >&2
    return 1
  fi
}
