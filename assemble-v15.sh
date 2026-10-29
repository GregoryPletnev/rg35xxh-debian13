#!/bin/bash
# RG35XXH MVP v15 = v14 layout + LCD text console:
#  - kernel k712rk (ROCKNIX H700 display patches, see build-kernel-v15.sh)
#  - two DTBs: default panel and rev6 panel; boot.scr picks rev6 when the file
#    "panel-rev6" exists on the BOOT partition
#  - console=tty0 (LCD) + ttyS0 (UART stays /dev/console), getty on tty1
#  - kernel modules in /lib/modules, dhcpcd off (systemd-networkd does DHCP),
#    host SSH key added to root's authorized_keys
set -euo pipefail
W=${W:-/home/builder/work}
OUT=$W/out
KDIR=$W/build/k712rk
MODS=$W/build/modules-v15
UB=$W/build/u-boot-2026.01
# FLAVOR=buildroot (default) or trixie (rootfs from build-rootfs-trixie.sh)
FLAVOR=${FLAVOR:-buildroot}
if [ "$FLAVOR" = trixie ]; then
  ROOTFS_IMG=${ROOTFS_IMG:-$W/rootfs-trixie/rootfs.ext4}
else
  ROOTFS_IMG=${ROOTFS_IMG:-$W/buildroot/output/images/rootfs.ext2}
fi
DTS=$KDIR/arch/arm64/boot/dts/allwinner
DTB=sun50i-h700-anbernic-rg35xx-h.dtb
DTB_REV6=sun50i-h700-anbernic-rg35xx-h-rev6-panel.dtb
HOST_KEY=${HOST_KEY:-$W/host_key.pub}
V=${V:-v15}
IMG=$OUT/rg35xxh-mvp-$V.img
DISK_ID=0x35a700${V#v}

P1_START=2048;   P1_SIZE=524288      # 256 MiB FAT32
P2_START=526336; P2_SIZE=4210688     # 2056 MiB ext4
TOTAL=4802560                        # + 32 MiB tail

test -f "$UB/u-boot-sunxi-with-spl.bin"
test -f "$KDIR/arch/arm64/boot/Image"
test -f "$DTS/$DTB"; test -f "$DTS/$DTB_REV6"
test -d "$MODS/lib/modules"
test -f "$ROOTFS_IMG"

cat > $W/boot.scr.cmd <<EOF
# RG35XXH MVP boot: LCD console (tty0) + UART (ttyS0 = /dev/console)
setenv bootargs "earlycon=uart8250,mmio32,0x05000000 console=tty0 console=ttyS0,115200 root=/dev/mmcblk0p2 rootfstype=ext4 rootwait rw loglevel=4"
setenv fdtfile $DTB
if test -e mmc 0:1 panel-rev6; then setenv fdtfile $DTB_REV6; fi
echo "=== BOOT: loading \${fdtfile} ==="
fatload mmc 0:1 0x4a000000 \${fdtfile}
echo "=== BOOT: dtb size=\${filesize} ==="
echo "=== BOOT: loading Image ==="
fatload mmc 0:1 0x42000000 Image
echo "=== BOOT: Image size=\${filesize} ==="
echo "=== BOOT: booti ==="
booti 0x42000000 - 0x4a000000
EOF
mkimage -A arm64 -O linux -T script -C none -n "RG35XXH $V" -d $W/boot.scr.cmd $W/boot.scr >/dev/null

mkdir -p "$OUT"
rm -f "$IMG"
truncate -s $((TOTAL*512)) "$IMG"

sfdisk -q "$IMG" <<EOF
label: dos
label-id: $DISK_ID
start=$P1_START, size=$P1_SIZE, type=c, bootable
start=$P2_START, size=$P2_SIZE, type=83
EOF

dd if="$UB/u-boot-sunxi-with-spl.bin" of="$IMG" bs=1024 seek=8 conv=notrunc status=none

LOOP=$(sudo losetup -f --show -P "$IMG")
M=$(mktemp -d)
cleanup() {
  sudo umount "$M" 2>/dev/null || true
  sudo losetup -d "$LOOP" 2>/dev/null || true
  rmdir "$M" 2>/dev/null || true
}
trap cleanup EXIT
sleep 1

sudo mkfs.vfat -n BOOT -F 32 "${LOOP}p1" >/dev/null
sudo mount -t vfat "${LOOP}p1" "$M"
sudo cp "$KDIR/arch/arm64/boot/Image" "$DTS/$DTB" "$DTS/$DTB_REV6" $W/boot.scr "$M/"
sudo umount "$M"

sudo dd if="$ROOTFS_IMG" of="${LOOP}p2" bs=8M status=none
sudo e2fsck -fy "${LOOP}p2" >/dev/null || [ $? -le 1 ]
sudo resize2fs "${LOOP}p2" >/dev/null 2>&1

sudo mount "${LOOP}p2" "$M"
sudo cp -a "$MODS/lib/modules" "$M/lib/"
S=$M/etc/systemd/system
if [ "$FLAVOR" = buildroot ]; then
  sudo mkdir -p $S/getty.target.wants
  sudo ln -sf /usr/lib/systemd/system/getty@.service $S/getty.target.wants/getty@tty1.service
  sudo find $S -name 'dhcpcd.service' -path '*.wants/*' -delete
  sudo ln -sf /dev/null $S/dhcpcd.service
  # shadow's /etc/pam.d/{login,passwd} include system-auth, which Buildroot does
  # not ship: without it every login (tty1, ttyS0) fails with "Login incorrect"
  sudo tee $M/etc/pam.d/system-auth >/dev/null <<'EOF'
auth		required	pam_unix.so nullok
account		required	pam_unix.so
password	required	pam_unix.so nullok sha512 shadow
session		required	pam_unix.so
session		required	pam_limits.so
EOF
fi
if [ -f "$HOST_KEY" ] && ! sudo grep -qF "$(cat "$HOST_KEY")" $M/root/.ssh/authorized_keys; then
  cat "$HOST_KEY" | sudo tee -a $M/root/.ssh/authorized_keys >/dev/null
fi
echo "--- rootfs check ($FLAVOR)"
ls $M/lib/modules
ls -la $S/getty.target.wants
sudo wc -l $M/root/.ssh/authorized_keys
sudo umount "$M"
sync

sfdisk -d "$IMG"
sha256sum "$IMG"
ls -la "$IMG"
echo DONE_V15_IMAGE
