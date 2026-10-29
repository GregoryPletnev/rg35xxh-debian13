#!/bin/bash
# Rebuild U-Boot exactly like ROCKNIX u-boot-DDR4:
#  - upstream v2026.01 (fresh tarball)
#  - 0001 dram tpr6 fix + 0002 axp717 charge-only-boot
#  - ROCKNIX defconfig (CONFIG_AXP_DCDC2_VOLT=940 DCDC3=1100 LED etc.)
#  - BL31 from our existing ATF build
set -euo pipefail
cd ~/work
X=aarch64-linux-gnu-
UB=build/u-boot-rk
BASE=https://raw.githubusercontent.com/ROCKNIX/distribution/next/projects/ROCKNIX/devices/H700/packages/u-boot-DDR4

echo "=== sources ==="
[ -f src/u-boot-v2026.01.tar.gz ] || curl -sL -o src/u-boot-v2026.01.tar.gz https://github.com/u-boot/u-boot/archive/refs/tags/v2026.01.tar.gz
echo "03bb43c58d2343ee48dd191e0f181f0108425b179d84519add3a977071c3f654  src/u-boot-v2026.01.tar.gz" | sha256sum -c
rm -rf $UB; mkdir -p $UB
tar xzf src/u-boot-v2026.01.tar.gz -C $UB --strip-components=1

echo "=== patches ==="
mkdir -p ~/work/rk-patches
curl -sfL -o ~/work/rk-patches/0001-dram.patch $BASE/patches/0001-Update-dram_sun50i_h616.c.patch
curl -sfL -o ~/work/rk-patches/0002-axp717.patch $BASE/patches/0002-sunxi-axp717-charge-only-boot.patch
cd $UB
patch -p1 --forward -s < ~/work/rk-patches/0001-dram.patch
patch -p1 --forward -s < ~/work/rk-patches/0002-axp717.patch
curl -sfL -o configs/anbernic_rg35xx_h700_lpddr4_defconfig.rk $BASE/sources/configs/anbernic_rg35xx_h700_lpddr4_defconfig
cp configs/anbernic_rg35xx_h700_lpddr4_defconfig.rk configs/anbernic_rg35xx_h700_lpddr4_defconfig

echo "=== build ==="
make ARCH=arm CROSS_COMPILE=$X mrproper >/dev/null
make ARCH=arm CROSS_COMPILE=$X anbernic_rg35xx_h700_lpddr4_defconfig >/dev/null
export BL31=$HOME/work/build/atf/build/sun50i_h616/release/bl31.bin
make ARCH=arm CROSS_COMPILE=$X BL31="$BL31" CONFIG_MKIMAGE_DTC_PATH=$(which dtc) -j14 > ~/work/build/uboot-rk.log 2>&1 || { tail -20 ~/work/build/uboot-rk.log; exit 1; }
grep -E "AXP_DISABLE|AXP717|LED_STATUS" .config | head
ls -la u-boot-sunxi-with-spl.bin
cp u-boot-sunxi-with-spl.bin ~/work/out/u-boot-sunxi-with-spl-rk.bin
echo DONE_RK_UBOOT
