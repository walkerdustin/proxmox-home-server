#!/bin/bash
# Create Proxmox VM 103 (dockploy) on DMZ vmbr3 from the Debian 13 genericcloud image.
# Run as root on pve. Idempotent enough to refuse if VM 103 already exists.
set -euo pipefail

VMID=103
NAME=dockploy
IMAGE=/var/lib/vz/template/iso/debian-13-genericcloud-amd64.qcow2
SNIPPET_SRC="$(dirname "$0")/cloud-init-vendor.yml"
SNIPPET_DST=/var/lib/vz/snippets/dockploy-vendor.yml

if qm status "$VMID" >/dev/null 2>&1; then
  echo "VM $VMID already exists; aborting." >&2
  exit 1
fi

if [[ ! -f "$IMAGE" ]]; then
  echo "Missing cloud image: $IMAGE" >&2
  exit 1
fi

install -d /var/lib/vz/snippets
install -m 644 "$SNIPPET_SRC" "$SNIPPET_DST"

# Match Seafile (VM 101): q35, OVMF, cpu=host, virtio-scsi-single, guest agent, onboot.
qm create "$VMID" \
  --name "$NAME" \
  --memory 8192 \
  --cores 4 \
  --sockets 1 \
  --cpu host \
  --ostype l26 \
  --machine q35 \
  --bios ovmf \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge=vmbr3 \
  --agent enabled=1 \
  --onboot 1 \
  --boot order=scsi0 \
  --serial0 socket \
  --vga serial0

qm set "$VMID" --efidisk0 local-zfs:1,efitype=4m,pre-enrolled-keys=1,ms-cert=2023k

qm importdisk "$VMID" "$IMAGE" local-zfs

DISK=$(qm config "$VMID" | awk -F': ' '/^unused/ {print $2; exit}')
if [[ -z "$DISK" ]]; then
  echo "importdisk did not leave an unused volume" >&2
  exit 1
fi

qm set "$VMID" --scsi0 "${DISK},discard=on,iothread=1,ssd=1"
qm resize "$VMID" scsi0 40G
qm set "$VMID" --ide2 local-zfs:cloudinit
qm set "$VMID" --cicustom "vendor=local:snippets/dockploy-vendor.yml"
qm set "$VMID" --ciuser debian
qm set "$VMID" --sshkeys /etc/pve/priv/authorized_keys
qm set "$VMID" --ipconfig0 ip=10.10.10.20/24,gw=10.10.10.1
qm set "$VMID" --nameserver 10.10.10.1

echo "Created VM $VMID. Config:"
qm config "$VMID"
echo
echo "Start with: qm start $VMID"
