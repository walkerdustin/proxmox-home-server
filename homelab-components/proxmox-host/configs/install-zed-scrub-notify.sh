#!/bin/bash
#
# Install the custom scrub-finish zedlet and stop Debian's monthly cron from
# also scrubbing tank (tank already has a weekly Sunday 03:00 job).
#
# Run as root on pve, from this directory:
#   ./install-zed-scrub-notify.sh

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src=$here/zed-scrub-finish-notify.sh
dst=/usr/local/sbin/zed-scrub-finish-notify.sh
zedlet=/etc/zfs/zed.d/scrub_finish-notify.sh
diverted=/etc/zfs/zed.d/scrub_finish-notify.sh.dist

[[ -f $src ]] || { echo "missing $src" >&2; exit 1; }

install -m 755 "$src" "$dst"

if [[ -L $zedlet ]] && [[ $(readlink -f "$zedlet") == "$dst" ]]; then
  :
else
  if ! dpkg-divert --list "$zedlet" | grep -q .; then
    dpkg-divert --local --rename --divert "$diverted" --add "$zedlet"
  fi
  rm -f "$zedlet"
  ln -s "$dst" "$zedlet"
fi

# Debian's /etc/cron.d/zfsutils-linux scrubs every ONLINE pool on the second
# Sunday at 00:24 unless this user property is disable. tank already scrubs
# every Sunday at 03:00 via /etc/cron.d/zfs-scrub-tank; leaving auto on means
# two tank scrubs (and a heat spike) on that overlap week.
zfs set org.debian:periodic-scrub=disable tank

echo "installed $zedlet -> $dst"
echo "tank org.debian:periodic-scrub=$(zfs get -H -o value org.debian:periodic-scrub tank)"
echo "test: $dst --test tank"
