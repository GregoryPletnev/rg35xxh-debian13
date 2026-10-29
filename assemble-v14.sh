#!/bin/bash
# RG35XXH MVP v14: same layout and artifacts as v12/v13 (mainline SPL+ATF+U-Boot
# @8KiB, MBR p1 FAT BOOT + p2 ext4 rootfs), with the root= fix:
#  - root=/dev/mmcblk0p2 instead of LABEL=rootfs (kernel without initramfs
#    cannot resolve LABEL=, v13 panicked with "root= is invalid")
#  - non-zero MBR disk id, so PARTUUID=35a70014-02 is usable later
#  - ext4 grown to the full p2 (1 GiB -> 2056 MiB)
set -euo pipefail
W=/home/builder/work
OUT=$W/out
KDIR=$W/build/k712
UB=$W/build/u-boot-2026.01
ROOTFS_IMG=$W/buildroot/output/images/rootfs.ext2
DTB=$KDIR/arch/arm64/boot/dts/allwinner/sun50i-h700-anbernic-rg35xx-h.dtb
IMG=$OUT/rg35xxh-mvp-v14.img
DISK_ID=0x35a70014

# v12 layout, in 512-byte sectors
P1_START=2048;   P1_SIZE=524288      # 256 MiB FAT32
P2_START=526336; P2_SIZE=4210688     # 2056 MiB ext4
TOTAL=4802560                        # + 32 MiB tail

test -f "$UB/u-boot-sunxi-with-spl.bin"
test -f "$KDIR/arch/arm64/boot/Image"
test -f "$DTB"
test -f "$ROOTFS_IMG"

cat > $W/boot.scr.cmd <<'EOF'
# RG35XXH MVP boot - earlycon only for full log
setenv bootargs "earlycon=uart8250,mmio32,0x05000000 console=ttyS0,115200 root=/dev/mmcblk0p2 rootfstype=ext4 rootwait rw ignore_loglevel loglevel=8"
echo "=== BOOT: loading dtb ==="
fatload mmc 0:1 0x4a000000 sun50i-h700-anbernic-rg35xx-h.dtb
echo "=== BOOT: dtb size=${filesize} ==="
echo "=== BOOT: loading Image ==="
fatload mmc 0:1 0x42000000 Image
echo "=== BOOT: Image size=${filesize} ==="
echo "=== BOOT: booti ==="
booti 0x42000000 - 0x4a000000
EOF
mkimage -A arm64 -O linux -T script -C none -n "RG35XXH v14" -d $W/boot.scr.cmd $W/boot.scr >/dev/null

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
M1=$(mktemp -d)
cleanup() {
  sudo umount "$M1" 2>/dev/null || true
  sudo losetup -d "$LOOP" 2>/dev/null || true
  rmdir "$M1" 2>/dev/null || true
}
trap cleanup EXIT
sleep 1

sudo mkfs.vfat -n BOOT -F 32 "${LOOP}p1" >/dev/null
sudo mount -t vfat "${LOOP}p1" "$M1"
sudo cp "$KDIR/arch/arm64/boot/Image" "$DTB" $W/boot.scr "$M1/"
sudo umount "$M1"

sudo dd if="$ROOTFS_IMG" of="${LOOP}p2" bs=8M status=none
sudo e2fsck -fy "${LOOP}p2" >/dev/null || [ $? -le 1 ]
sudo resize2fs "${LOOP}p2" >/dev/null 2>&1
sync

sfdisk -d "$IMG"
sha256sum "$IMG"
ls -la "$IMG"
echo DONE_V14_IMAGE
