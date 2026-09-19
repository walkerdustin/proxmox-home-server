#!/bin/bash
#
# /usr/local/sbin/seafile-sql-dump-alert.sh  --  Proxmox host `pve`
#
# Mails if today's Seafile SQL dump is missing, incomplete, or too small.
# The dump itself runs inside VM 101 (seafile-backup-sql.timer, 03:15). That
# timer is silent on failure, so this host-side check is the only signal.
#
# Why here, not OnFailure= on the guest:
#   - Reuses /etc/zfs-capacity-alert.cred. No SMTP password copy in the DMZ.
#   - Catches a disabled timer, a VM that stayed down, and a dump that exited
#     0 with empty files. OnFailure= misses all three.
#
# How it looks: qm guest exec into VM 101 (agent is enabled). LAN→DMZ SSH is
# not used. Guest-agent down is treated as a failed check, which is the point:
# we cannot see the dumps.
#
# Cron is noon Europe/Berlin, well after 03:15. "Today" is the guest's date.
# Observed dump sizes 2026-09-17: ccnet 13K, seafile 46K, seahub 48M. Floors
# below are just "not empty / not a stub".
#
# Mails every failed noon check, and once when it recovers. State in
# /var/lib/seafile-sql-dump-alert/state.
#
# Test:  seafile-sql-dump-alert.sh --test     (always mails, does not touch state)

set -euo pipefail

VMID=101
DUMP_ROOT='/mnt/data/seafile/backup-sql'
MIN_CCNET=1000
MIN_SEAFILE=1000
MIN_SEAHUB=10000

RCPT='mail@dustinwalker.de'
FROM='zfs.notification@dustinwalker.de'
SMTP_URL='smtps://smtp.zoho.eu:465'
CRED_FILE='/etc/zfs-capacity-alert.cred'
STATE_FILE='/var/lib/seafile-sql-dump-alert/state'

TEST_MODE=no
[[ ${1:-} == --test ]] && TEST_MODE=yes

mkdir -p "$(dirname "$STATE_FILE")"
host=$(hostname -s)

send_mail() {
  local subject=$1 body=$2 msg
  msg=$(mktemp)
  {
    printf 'From: Seafile dumps on %s <%s>\n' "$host" "$FROM"
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

# Decode `qm guest exec` JSON. Prints guest stdout; exits with the guest's
# exitcode (or 2 if qm returned no usable result).
decode_guest_exec() {
  python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    j = json.loads(raw)
except Exception as e:
    sys.stderr.write("not JSON from qm guest exec: %s\n%s\n" % (e, raw[:800]))
    sys.exit(2)
if not j.get("exited"):
    sys.stderr.write("guest exec did not finish (timeout? pid=%s)\n" % (j.get("pid"),))
    sys.exit(2)
sys.stdout.write(j.get("out-data") or "")
err = j.get("err-data") or ""
if err:
    sys.stderr.write(err)
if j.get("out-truncated") or j.get("err-truncated"):
    sys.stderr.write("guest exec output was truncated\n")
code = j.get("exitcode")
sys.exit(int(code) if code is not None else 2)
'
}

qm_err=$(mktemp)
trap 'rm -f "$qm_err"' EXIT

set +e
guest_out=$(
  qm guest exec "$VMID" --pass-stdin --timeout 30 -- /bin/bash <<GUEST 2>"$qm_err" | decode_guest_exec
set -euo pipefail
ROOT='$DUMP_ROOT'
MIN_CCNET=$MIN_CCNET
MIN_SEAFILE=$MIN_SEAFILE
MIN_SEAHUB=$MIN_SEAHUB
today=\$(date +%F)

if [ ! -d "\$ROOT" ]; then
  printf 'FAIL dump dir missing: %s\n' "\$ROOT"
  exit 1
fi

latest=\$(find "\$ROOT" -mindepth 1 -maxdepth 1 -type d -name "\${today}-*" -printf '%T@\\t%p\\n' | sort -nr | awk -F'\\t' 'NR==1 {print \$2; exit}')

if [ -z "\$latest" ]; then
  printf 'FAIL no dump directory for %s in %s\n' "\$today" "\$ROOT"
  printf 'newest existing:\\n'
  ls -ltr "\$ROOT" | tail -5
  printf '\\nlast dump unit journal:\\n'
  journalctl -u seafile-backup-sql.service -n 20 --no-pager || true
  exit 1
fi

fail=
check() {
  local name=\$1 min=\$2 f size
  f="\$latest/\$name"
  size=\$(stat -c %s "\$f" 2>/dev/null || echo 0)
  if [ "\$size" -lt "\$min" ]; then
    fail="\$fail \$name=\${size}b(need \${min})"
  fi
}
check ccnet_db.sql "\$MIN_CCNET"
check seafile_db.sql "\$MIN_SEAFILE"
check seahub_db.sql "\$MIN_SEAHUB"

printf 'dump=%s\\n' "\$(basename "\$latest")"
ls -l "\$latest"

if [ -n "\$fail" ]; then
  printf 'FAIL files too small or missing:%s\\n' "\$fail"
  printf '\\nlast dump unit journal:\\n'
  journalctl -u seafile-backup-sql.service -n 20 --no-pager || true
  exit 1
fi

printf 'OK\\n'
GUEST
)
guest_rc=$?
set -e

qm_stderr=$(cat "$qm_err" 2>/dev/null || true)

if [[ $guest_rc -ne 0 && -z $guest_out && -n $qm_stderr ]]; then
  guest_out="FAIL qm guest exec VM $VMID: $qm_stderr"
fi

prev=OK
if [[ -f $STATE_FILE ]]; then
  read -r prev _ <"$STATE_FILE" || true
fi

if [[ $TEST_MODE == yes ]]; then
  body=$(
    printf 'Test notification -- dump is not being judged.\n\n'
    printf 'Guest check (VM %s):\n%s\n' "$VMID" "$guest_out"
    if [[ -n $qm_stderr ]]; then
      printf '\nqm stderr:\n%s\n' "$qm_stderr"
    fi
  )
  send_mail "[$host] Seafile SQL dump alert test" "$body"
  exit 0
fi

if [[ $guest_rc -ne 0 ]]; then
  body=$(
    printf 'Today'\''s Seafile SQL dump on VM %s is missing or incomplete.\n\n' "$VMID"
    printf '%s\n' "$guest_out"
    if [[ -n $qm_stderr ]]; then
      printf '\nqm stderr:\n%s\n' "$qm_stderr"
    fi
    printf '\nDump runs at 03:15 on the guest:\n'
    printf '  journalctl -u seafile-backup-sql.service -n 50\n'
    printf '  ls -ltr %s\n' "$DUMP_ROOT"
  )
  send_mail "[$host] Seafile SQL dump missing or incomplete" "$body"
  printf 'FAIL %s\n' "$(date +%s)" >"$STATE_FILE"
  exit 1
fi

if [[ $prev == FAIL ]]; then
  body=$(
    printf 'Seafile SQL dump on VM %s is present again.\n\n' "$VMID"
    printf '%s\n' "$guest_out"
  )
  send_mail "[$host] Seafile SQL dump resumed" "$body"
fi

printf 'OK %s\n' "$(date +%s)" >"$STATE_FILE"
exit 0
