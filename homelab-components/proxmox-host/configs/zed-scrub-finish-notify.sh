#!/bin/bash
#
# /usr/local/sbin/zed-scrub-finish-notify.sh  --  Proxmox host `pve`
#
# ZED hook for scrub_finish. Replaces the stock plain-text zedlet so the
# subject is readable in a mailbox list:
#
#   scrub on "rpool" -> no error
#   scrub on "tank" -> ERROR!!
#
# Body is HTML (inline styles only, same constraints as drive-temp-alert.sh):
# one green or red line, then the scan summary, then `zpool status`.
#
# Sends with curl straight to Zoho, sharing /etc/zfs-capacity-alert.cred with
# the other host alerts. Deliberately not the mail-to-root path: proxmox-mail-
# forward treats the body as plain text, so colour would never survive it.
# Pool-degraded / checksum events still use that path via the stock zedlets.
#
# Installed as /etc/zfs/zed.d/scrub_finish-notify.sh (see
# install-zed-scrub-notify.sh). ZED execs the zedlet; the shebang is honoured.
#
# Test (mails using the pool's last real scrub, does not start one):
#   zed-scrub-finish-notify.sh --test tank
#   zed-scrub-finish-notify.sh --test rpool

set -euo pipefail

RCPT='mail@dustinwalker.de'
FROM='zfs.notification@dustinwalker.de'
SMTP_URL='smtps://smtp.zoho.eu:465'
CRED_FILE='/etc/zfs-capacity-alert.cred'
FONT='font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif'

TEST_MODE=no
if [[ ${1:-} == --test ]]; then
  TEST_MODE=yes
  shift
fi

host=$(hostname -s)

if [[ $TEST_MODE == yes ]]; then
  pool=${1:-tank}
  eid='(test)'
  when=$(date '+%Y-%m-%d %H:%M:%S%z')
else
  pool=${ZEVENT_POOL:-}
  [[ -n $pool ]] || exit 9
  [[ ${ZEVENT_SUBCLASS:-} == scrub_finish ]] || exit 9
  eid=${ZEVENT_EID:-?}
  when=${ZEVENT_TIME_STRING:-$(date '+%Y-%m-%d %H:%M:%S%z')}
fi

status=$(zpool status "$pool")
health=$(zpool get -H -o value health "$pool")
scan=$(printf '%s\n' "$status" | sed -n 's/^[[:space:]]*scan: //p')
[[ -n $scan ]] || scan='(no scan line in zpool status)'

repaired=$(printf '%s\n' "$scan" | sed -n 's/.*repaired \([^ ]*\) in.*/\1/p')
err_n=$(printf '%s\n' "$scan" | sed -n 's/.* with \([0-9][0-9]*\) errors.*/\1/p')

failed=no
[[ $health == ONLINE ]] || failed=yes
[[ -z $err_n || $err_n == 0 ]] || failed=yes
case $repaired in
  ''|0|0B|0b) ;;
  *) failed=yes ;;
esac
printf '%s\n' "$status" | grep -q '^errors: No known data errors' || failed=yes

if [[ $failed == yes ]]; then
  verdict="scrub on \"$pool\" -> ERROR!!"
  color='#c62828'
else
  verdict="scrub on \"$pool\" -> no error"
  color='#1a7f37'
fi

esc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

status_html=$(esc "$status")
scan_html=$(esc "$scan")
verdict_html=$(esc "$verdict")
when_html=$(esc "$when")
eid_html=$(esc "$eid")
health_html=$(esc "$health")

body=$(cat <<EOF
<p style="margin:0 0 12px;font-size:18px;font-weight:700;color:${color}">${verdict_html}</p>
<p style="margin:0 0 16px;color:#444">${scan_html}</p>
<p style="margin:0 0 8px;color:#666;font-size:13px">host ${host} · health ${health_html} · eid ${eid_html} · ${when_html}</p>
<pre style="margin:0;padding:12px;background:#f4f4f4;border:1px solid #e0e0e0;font-size:12px;line-height:1.4;overflow:auto">${status_html}</pre>
EOF
)

msg=$(mktemp)
trap 'rm -f "$msg"' EXIT
{
  printf 'From: ZFS scrub on %s <%s>\n' "$host" "$FROM"
  printf 'To: %s\n' "$RCPT"
  printf 'Subject: %s\n' "$verdict"
  printf 'Date: %s\n' "$(date -R)"
  printf 'MIME-Version: 1.0\n'
  printf 'Content-Type: text/html; charset=utf-8\n'
  printf '\n<html><body style="%s;font-size:14px;color:#222">\n%s\n</body></html>\n' \
    "$FONT" "$body"
} >"$msg"

curl --silent --show-error --ssl-reqd \
  --url "$SMTP_URL" \
  --config "$CRED_FILE" \
  --mail-from "$FROM" \
  --mail-rcpt "$RCPT" \
  --upload-file "$msg"

logger -t zed-scrub-notify -- "$verdict (eid=$eid)"
exit 0
