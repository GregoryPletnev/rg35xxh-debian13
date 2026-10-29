#!/bin/bash
# Kernel for v15: vanilla 7.1.2 + ROCKNIX H700 patch set (display pipeline:
# DE33/TCON/PWM/backlight/panel-mipi, USB OTG host), applied in ROCKNIX order.
# Skipped: 0140 (needs out-of-tree rocknix-singleadc-joypad driver; mainline
# adc-joystick + gpio-keys keep working) and 0150 (forcefeedback for that joypad).
# Panel init sequences (panels/*.panel) are built in via EXTRA_FIRMWARE: the panel
# driver probes before the rootfs is mounted and there is no initramfs.
set -euo pipefail
W=${W:-/home/builder/work}
K=$W/build/k712rk
P=$W/rocknix-full/projects/ROCKNIX/devices/H700/patches/linux
RK_DTS=$W/rocknix-full/projects/ROCKNIX/devices/H700/linux/dts/allwinner
SKIP="0140-|0150-"
X=aarch64-linux-gnu-
export ARCH=arm64 CROSS_COMPILE=$X

rm -rf "$K"; mkdir -p "$K"
tar xJf $W/src/linux-7.1.2.tar.xz -C "$K" --strip-components=1
cd "$K"

for p in $P/*.patch; do
  b=$(basename "$p")
  if echo "$b" | grep -qE "$SKIP"; then echo "SKIP $b"; continue; fi
  patch -p1 --forward -s < "$p" || { echo "PATCH FAILED: $b"; exit 1; }
done

# Our own fixes (patches/linux/ in the repo), on top of ROCKNIX
for p in $W/patches/linux/*.patch; do
  patch -p1 --forward -s < "$p" || { echo "PATCH FAILED: $(basename "$p")"; exit 1; }
done

# ROCKNIX targets 7.2, where sram_c labels an "allwinner,sun50i-a64-sram-c"
# section inside the SRAM C mmio-sram node. In 7.1.2 the label sits on the bare
# mmio-sram node, so sunxi_sram_claim() fails with -EINVAL and the DE33 bus
# (and the whole display pipeline) never probes. Backport the 7.2 layout.
perl -0pi -e 's/sram_c: (sram\@28000 \{\n\t+compatible = "mmio-sram";\n\t+reg = <0x00028000 0x30000>;\n\t+#address-cells = <1>;\n\t+#size-cells = <1>;\n\t+ranges = <0 0x00028000 0x30000>;\n)/$1\n\t\t\t\tsram_c: sram-section\@0 {\n\t\t\t\t\tcompatible = "allwinner,sun50i-h616-sram-c",\n\t\t\t\t\t\t     "allwinner,sun50i-a64-sram-c";\n\t\t\t\t\treg = <0x00000 0x30000>;\n\t\t\t\t};\n/' \
  arch/arm64/boot/dts/allwinner/sun50i-h616.dtsi
grep -q 'sram_c: sram-section@0' arch/arm64/boot/dts/allwinner/sun50i-h616.dtsi

# 0144 references &joypad, which only exists with 0140
perl -0pi -e 's/\n&joypad \{\n\tamux-count = <4>;\n\};\n//' \
  arch/arm64/boot/dts/allwinner/sun50i-h700-anbernic-rg35xx-h.dts
! grep -q '&joypad' arch/arm64/boot/dts/allwinner/sun50i-h700-anbernic-rg35xx-h.dts

# RG35XX-H with the newer (rev6) panel: separate DTB from ROCKNIX
cp $RK_DTS/sun50i-h700-anbernic-rg35xx-h-rev6-panel.dts arch/arm64/boot/dts/allwinner/
echo 'dtb-$(CONFIG_ARCH_SUNXI) += sun50i-h700-anbernic-rg35xx-h-rev6-panel.dtb' \
  >> arch/arm64/boot/dts/allwinner/Makefile

mkdir -p external-firmware
cp -a $W/build/k712/external-firmware/. external-firmware/
cp -a $W/fw/panels external-firmware/
cp $W/buildroot/output/target/lib/firmware/regulatory.db{,.p7s} external-firmware/

cp $W/build/k712/.config .config
CFG=scripts/config
$CFG -e DRM_PANEL_MIPI -d DRM_PANEL_NEWVISION_NV3052C -d DRM_PANEL_MIPI_DBI
$CFG -e PWM_SUN8I
$CFG -e FRAMEBUFFER_CONSOLE -d FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER
$CFG -e FONT_8x16
# /dev/input/mice for gpm (rgpad mouse on the right stick, USB mice)
$CFG -e INPUT_MOUSEDEV --set-val INPUT_MOUSEDEV_SCREEN_X 640 --set-val INPUT_MOUSEDEV_SCREEN_Y 480
$CFG --set-str EXTRA_FIRMWARE "rtl_bt/rtl8821cs_config.bin rtl_bt/rtl8821cs_fw.bin rtw88/rtw8821c_fw.bin panels/anbernic,rg35xx-plus-panel.panel panels/anbernic,rg35xx-plus-rev6-panel.panel regulatory.db regulatory.db.p7s"
make olddefconfig >/dev/null

echo "=== config check ==="
grep -E "^CONFIG_(DRM_PANEL_MIPI|PWM_SUN8I|DRM_SUN4I|DRM_SUN8I_MIXER|DRM_SUN8I_TCON_TOP|BACKLIGHT_PWM|FRAMEBUFFER_CONSOLE|VT_CONSOLE|EXTRA_FIRMWARE|USB_MUSB_DUAL_ROLE)=" .config
grep -q "^# CONFIG_DRM_PANEL_NEWVISION_NV3052C is not set" .config

make -j$(nproc) Image dtbs modules > $W/build/kernel-v15.log 2>&1 || { tail -30 $W/build/kernel-v15.log; exit 1; }
rm -rf $W/build/modules-v15
make modules_install INSTALL_MOD_PATH=$W/build/modules-v15 INSTALL_MOD_STRIP=1 >/dev/null
ls -la arch/arm64/boot/Image arch/arm64/boot/dts/allwinner/sun50i-h700-anbernic-rg35xx-h*.dtb
du -sh $W/build/modules-v15/lib/modules/*
echo DONE_KERNEL_V15
