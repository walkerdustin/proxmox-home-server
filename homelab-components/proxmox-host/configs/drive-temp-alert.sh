#!/bin/bash
#
# /usr/local/sbin/drive-temp-alert.sh  --  Proxmox host `pve`
#
# Emails an HTML table of ALL drive temperatures whenever any drive is at or
# above its ceiling. Fills the SMART gap: ZED reacts only to ZFS-level
# failures, so a disk can run hot for weeks while `zpool status` says ONLINE.
#
# Why its own script and its own cron rather than Scrutiny's:
#   - Reading Scrutiny's API would make this depend on LXC 102 being up to
#     tell you a disk is overheating.
#   - Sharing a cron line couples two unrelated jobs: one failure kills both,
#     and a change to the collector's schedule silently changes this alert.
#   SMART attribute reads are cheap (no seek, no spin-up), so polling
#   independently costs nothing.
#
# Temperature source, verified against these exact six drives 2026-08-22:
#   194 Temperature_Celsius      -> Crucial BX500, both Seagates
#   190 Airflow_Temperature_Cel  -> Samsung 850 EVO, 860 EVO, both Seagates
#   Field 10 is the raw value in both cases. 194 preferred, 190 fallback.
#   A script checking only ONE of these would silently report nothing for
#   half of these disks.
#   PEAK comes from whichever line carries "Min/Max a/b" (not all do).
#
# Thresholds are chosen by SPINNING vs SOLID STATE via
# /sys/block/*/queue/rotational, with optional per-SERIAL overrides. Keyed on
# serial, not /dev/sdX, because device letters can move between reboots.
#
# IMPORTANT: smartctl returns a BITMASK exit status and is non-zero on
# perfectly healthy drives (bit 6 = an attribute is in its "old age" range,
# true for every drive here). Every smartctl call therefore ends in
# `|| true`; without it `set -e` aborts on a healthy disk.
#
# Mail is text/html with inline styles only -- no <style> block, no external
# CSS, no images, because mail clients strip all three. Plain-text columns were
# tried first and were unreadable: every client renders mail in a proportional
# font, so fixed-width alignment collapses.
#
# Credentials: /etc/zfs-capacity-alert.cred, shared with the capacity alert so
# there is no second copy of the password. curl config format, root-only, NOT
# in git. (Rename to something neutral during the password rotation.)
#
# Mails when the SET of over-limit drives changes, then every REMIND_AFTER
# while it persists, and once when everything is back under its limit.
#
# Test:  drive-temp-alert.sh --test     (always mails, ignores thresholds)

set -euo pipefail

# --- thresholds, degrees Celsius -------------------------------------------
# TEMPORARY validation values. Observed idle: HDD 35-39, SSD 27-32.
# Peaks on record: sda 43, sde 47, sdf 42, sdc 41.
# Sensible long-term once the mails look right: HDD 45, SSD 50.
TEMP_MAX_HDD=40
TEMP_MAX_SSD=40
declare -A TEMP_MAX_SERIAL=()      # per-drive exceptions, e.g. [Z4Z2CNQR]=48

RCPT='mail@dustinwalker.de'
FROM='zfs.notification@dustinwalker.de'
SMTP_URL='smtps://smtp.zoho.eu:465'
CRED_FILE='/etc/zfs-capacity-alert.cred'
STATE_FILE='/var/lib/drive-temp-alert/state'
REMIND_AFTER=$((6 * 3600))

TEST_MODE=no
[[ ${1:-} == --test ]] && TEST_MODE=yes

mkdir -p "$(dirname "$STATE_FILE")"
now=$(date +%s)
host=$(hostname -s)

FONT='font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif'

send_mail() {
  local subject=$1 body=$2 msg
  msg=$(mktemp)
  {
    printf 'From: Drive temps on %s <%s>\n' "$host" "$FROM"
    printf 'To: %s\n' "$RCPT"
    printf 'Subject: %s\n' "$subject"
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
  rm -f "$msg"
}

# SMART strings are tame, but escape anyway rather than trust device firmware.
esc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

TD='padding:7px 12px;border-bottom:1px solid #e3e3e3'
TDR="$TD;text-align:right;font-variant-numeric:tabular-nums"
ROW_FMT='<tr style="%s"><td style="'"$TD"'"><code>%s</code></td><td style="'"$TD"'">%s</td><td style="'"$TD"'"><code>%s</code></td><td style="'"$TD"'">%s</td><td style="'"$TDR"'">%s</td><td style="'"$TDR"';color:#777">%s</td><td style="'"$TDR"';color:#777">%s</td><td style="'"$TD"'">%s</td></tr>\n'

rows_html=()
hot=()

for dev in $(smartctl --scan | awk '{print $1}'); do
  name=${dev#/dev/}

  # -n standby: never spin up a sleeping disk just to read a temperature.
  # No spindown is configured today; this costs nothing and future-proofs it.
  info=$(smartctl -n standby -i "$dev" 2>&1 || true)
  attrs=$(smartctl -n standby -A "$dev" 2>&1 || true)

  model=$(sed -n 's/^Device Model: *//p; s/^Model Number: *//p' <<<"$info" | head -1)
  serial=$(sed -n 's/^Serial Number: *//p' <<<"$info" | head -1)
  [ -n "$model" ] || model='(unknown)'
  [ -n "$serial" ] || serial="$name"

  rota=$(cat "/sys/block/$name/queue/rotational" 2>/dev/null || echo 1)
  if [ "$rota" = 1 ]; then
    type=HDD
    limit=$TEMP_MAX_HDD
  else
    type=SSD
    limit=$TEMP_MAX_SSD
  fi
  limit=${TEMP_MAX_SERIAL[$serial]:-$limit}

  temp=$(awk '$1==194 {print $10; exit}' <<<"$attrs")
  [ -n "$temp" ] || temp=$(awk '$1==190 {print $10; exit}' <<<"$attrs")

  peak=$(sed -n 's/.*Min\/Max [0-9]\+\/\([0-9]\+\).*/\1/p' <<<"$attrs" | sort -n | tail -1)
  [ -n "$peak" ] || peak='&ndash;'

  if [ -z "$temp" ]; then
    rows_html+=("$(printf "$ROW_FMT" 'color:#a06000' "$name" "$(esc "$model")" \
      "$(esc "$serial")" "$type" '&ndash;' "$limit" "$peak" 'no reading (standby?)')")
    continue
  fi

  if [ "$temp" -ge "$limit" ]; then
    hot+=("$serial")
    rows_html+=("$(printf "$ROW_FMT" 'background:#fdecea;color:#b3261e;font-weight:600' \
      "$name" "$(esc "$model")" "$(esc "$serial")" "$type" "$temp" "$limit" "$peak" 'OVER LIMIT')")
  else
    rows_html+=("$(printf "$ROW_FMT" '' "$name" "$(esc "$model")" "$(esc "$serial")" \
      "$type" "$temp" "$limit" "$peak" '<span style="color:#1e7c3c">ok</span>')")
  fi
done

table_html() {
  local th="padding:7px 12px;border-bottom:2px solid #999;text-align:left;font-size:12px;letter-spacing:.04em;text-transform:uppercase;color:#555"
  local thr="$th;text-align:right"
  printf '<table cellspacing="0" cellpadding="0" style="border-collapse:collapse;%s;font-size:14px">\n' "$FONT"
  printf '<tr><th style="%s">Device</th><th style="%s">Model</th><th style="%s">Serial</th><th style="%s">Type</th><th style="%s">Temp</th><th style="%s">Limit</th><th style="%s">Peak</th><th style="%s">State</th></tr>\n' \
    "$th" "$th" "$th" "$th" "$thr" "$thr" "$thr" "$th"
  printf '%s\n' "${rows_html[@]}"
  printf '</table>\n'
  printf '<p style="color:#777;font-size:12px;margin-top:14px">All values in &deg;C. '
  printf '<b>Peak</b> is the highest temperature the drive itself has ever recorded '
  printf '(SMART Min/Max); &ndash; means the drive does not report it.<br>'
  printf 'Host <b>%s</b> &middot; %s</p>\n' "$host" "$(date '+%Y-%m-%d %H:%M %Z')"
}

if ((${#hot[@]} == 0)); then
  hot_key=''
else
  hot_key=$(printf '%s\n' "${hot[@]}" | sort | paste -sd,)
fi

prev_time=0
prev_key=''
if [ -f "$STATE_FILE" ]; then
  read -r prev_time prev_key <"$STATE_FILE" || true
  [ -n "$prev_time" ] || prev_time=0
fi

if [ "$TEST_MODE" = yes ]; then
  send_mail "[$host] Drive temperature test" "$(
    printf '<p style="margin:0 0 14px"><b>Test notification.</b> Limits are shown but not acted on.</p>\n'
    table_html
  )"
  exit 0
fi

mail_time=$prev_time

if [ -n "$hot_key" ]; then
  if [ "$hot_key" != "$prev_key" ] || ((now - prev_time >= REMIND_AFTER)); then
    send_mail "[$host] Drive temperature over limit: $hot_key" "$(
      printf '<p style="margin:0 0 14px;font-size:15px">At or above limit: <b style="color:#b3261e">%s</b></p>\n' "$hot_key"
      table_html
      printf '<p style="margin-top:16px"><b>Worth checking, most likely first</b></p>\n'
      printf '<ul style="margin:6px 0 0;padding-left:20px;color:#444">\n'
      printf '<li>Case fans and dust, and airflow across the drive cage</li>\n'
      printf '<li>A scrub, resilver or large upload running right now</li>\n'
      printf '<li>Ambient room temperature</li>\n'
      printf '</ul>\n'
    )"
    mail_time=$now
  fi
elif [ -n "$prev_key" ]; then
  send_mail "[$host] Drive temperatures back to normal" "$(
    printf '<p style="margin:0 0 14px"><b style="color:#1e7c3c">All drives are below their limits again.</b></p>\n'
    table_html
  )"
  mail_time=$now
fi

printf '%s %s\n' "$mail_time" "$hot_key" >"$STATE_FILE"

[ -z "$hot_key" ]
