#!/bin/bash
#
# /usr/local/sbin/zfs-capacity-alert.sh  --  Proxmox host `pve`
#
# Mails when a ZFS pool is running out of space. ZED and Proxmox's built-in
# notifications cover pool *health* (degraded vdev, scrub errors, checksum
# errors) but emit nothing at all for a pool that is simply filling up.
#
# Two independent triggers, because on this host the two numbers mean
# different things:
#
#   1. zpool allocation >= CAP_PCT_MAX
#      Raw allocated blocks. Ignores reservations, so on `tank` this stays
#      low (~11%) even while `zfs list` shows little AVAIL. Catches genuine
#      fill-up and the ~80% fragmentation/performance cliff.
#
#   2. root-dataset AVAIL < FREE_MIN[pool]
#      Accounts for refreservation. `tank/vm-101-disk-0` is thick-provisioned
#      (refreservation ~2.98T), so tank's ~166G AVAIL is the *entire* headroom
#      left for snapshot divergence. Hitting the floor means most of that
#      headroom is gone -- either prune snapshots or drop the reservation.
#
# Mails once when a pool goes bad, again every REMIND_AFTER while it stays
# bad, and once more when it recovers. State in $STATE_DIR.
#
# Sends with curl straight to Zoho SMTP: this host has no local MTA, and
# Proxmox's notification targets cannot be invoked with an arbitrary message
# from a script.
#
# Credentials live in /etc/zfs-capacity-alert.cred -- root-only, curl config
# file format, NOT in git:
#
#     user = "zfs.notification@dustinwalker.de:<app-password>"
#
# Using --config rather than --user keeps the password out of `ps` output.
#
# Test:   /usr/local/sbin/zfs-capacity-alert.sh --test
#         Always mails, ignores thresholds, does not touch state.

set -euo pipefail

CAP_PCT_MAX=85
DEFAULT_FREE_MIN=$((20 * 1024 ** 3))
declare -A FREE_MIN=(
  [tank]=$((40 * 1024 ** 3))   # of ~166G headroom left by the thick zvol
  [rpool]=$((30 * 1024 ** 3))
)

RCPT='mail@dustinwalker.de'
FROM='zfs.notification@dustinwalker.de'
SMTP_URL='smtps://smtp.zoho.eu:465'
CRED_FILE='/etc/zfs-capacity-alert.cred'
STATE_DIR='/var/lib/zfs-capacity-alert'
REMIND_AFTER=$((24 * 3600))

TEST_MODE=no
[[ ${1:-} == --test ]] && TEST_MODE=yes

mkdir -p "$STATE_DIR"
now=$(date +%s)
host=$(hostname -s)

send_mail() {
  local subject=$1 body=$2 msg
  msg=$(mktemp)
  {
    printf 'From: ZFS on %s <%s>\n' "$host" "$FROM"
    printf 'To: %s\n' "$RCPT"
    printf 'Subject: %s\n' "$subject"
    printf 'Date: %s\n' "$(date -R)"
    printf 'Content-Type: text/plain; charset=utf-8\n'
    printf '\n%s\n' "$body"
  } >"$msg"
  curl --silent --show-error --ssl-reqd \
    --url "$SMTP_URL" \
    --config "$CRED_FILE" \
    --mail-from "$FROM" \
    --mail-rcpt "$RCPT" \
    --upload-file "$msg"
  rm -f "$msg"
}

pool_report() {
  local pool=$1
  printf 'zpool list:\n'
  zpool list -o name,size,alloc,free,capacity,fragmentation,health "$pool"
  printf '\nzfs list (pool + direct children):\n'
  zfs list -d 1 -o name,used,avail,refer,usedbysnapshots,refreservation "$pool"
  printf '\nSnapshot count: %s\n' "$(zfs list -H -t snapshot -r "$pool" | wc -l)"
}

alerted=0

while read -r pool cap; do
  cap=${cap%\%}
  free=$(zfs get -Hp -o value available "$pool")
  min=${FREE_MIN[$pool]:-$DEFAULT_FREE_MIN}

  reasons=()
  if ((cap >= CAP_PCT_MAX)); then
    reasons+=("pool allocation ${cap}% has reached ${CAP_PCT_MAX}%")
  fi
  if ((free < min)); then
    reasons+=("free space $(numfmt --to=iec "$free") is below $(numfmt --to=iec "$min")")
  fi

  state_file="$STATE_DIR/$pool"
  prev_state=OK
  prev_time=0
  if [[ -f $state_file ]]; then
    read -r prev_state prev_time <"$state_file" || true
  fi

  if [[ $TEST_MODE == yes ]]; then
    body=$(
      printf 'Test notification -- thresholds not evaluated.\n\n'
      printf 'Pool %s: allocation %s%%, AVAIL %s (alert below %s)\n\n' \
        "$pool" "$cap" "$(numfmt --to=iec "$free")" "$(numfmt --to=iec "$min")"
      pool_report "$pool"
    )
    send_mail "[$host] ZFS capacity alert test -- $pool" "$body"
    continue
  fi

  if ((${#reasons[@]} > 0)); then
    alerted=1
    if [[ $prev_state != ALERT ]] || ((now - prev_time >= REMIND_AFTER)); then
      body=$(
        printf 'Pool %s is low on space:\n\n' "$pool"
        printf '  - %s\n' "${reasons[@]}"
        printf '\n'
        pool_report "$pool"
        printf '\nUsual causes, most likely first:\n'
        printf '  - snapshot divergence after a large delete + Seafile GC\n'
        printf '  - guest wrote more data than planned\n'
        printf '  - a manual or Proxmox (qm snapshot) snapshot left behind\n'
      )
      send_mail "[$host] ZFS pool $pool is low on space" "$body"
      prev_time=$now
    fi
    printf 'ALERT %s\n' "$prev_time" >"$state_file"
  else
    if [[ $prev_state == ALERT ]]; then
      body=$(
        printf 'Pool %s is back within thresholds.\n\n' "$pool"
        pool_report "$pool"
      )
      send_mail "[$host] ZFS pool $pool recovered" "$body"
    fi
    printf 'OK %s\n' "$now" >"$state_file"
  fi
done < <(zpool list -H -o name,capacity)

exit $alerted
