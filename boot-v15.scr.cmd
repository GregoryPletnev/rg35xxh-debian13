# RG35XXH MVP boot: LCD console (tty0) + UART (ttyS0 = /dev/console)
setenv bootargs "earlycon=uart8250,mmio32,0x05000000 console=tty0 console=ttyS0,115200 root=/dev/mmcblk0p2 rootfstype=ext4 rootwait rw ignore_loglevel loglevel=8"
setenv fdtfile sun50i-h700-anbernic-rg35xx-h.dtb
if test -e mmc 0:1 panel-rev6; then setenv fdtfile sun50i-h700-anbernic-rg35xx-h-rev6-panel.dtb; fi
echo "=== BOOT: loading ${fdtfile} ==="
fatload mmc 0:1 0x4a000000 ${fdtfile}
echo "=== BOOT: dtb size=${filesize} ==="
echo "=== BOOT: loading Image ==="
fatload mmc 0:1 0x42000000 Image
echo "=== BOOT: Image size=${filesize} ==="
echo "=== BOOT: booti ==="
booti 0x42000000 - 0x4a000000
