# rg35xxh-debian13

Debian 13 (trixie) for the Anbernic RG35XX-H, booted by mainline U-Boot and a
mainline Linux kernel with the ROCKNIX H700 display patch set.

The board is an Allwinner H700 (sun50i-h700). The vendor firmware boots a
proprietary kernel from a locked boot chain. This project replaces the whole
stack: U-Boot as the first-stage payload, a 7.1.2 kernel with the display and
USB patches, and a Debian trixie arm64 rootfs. The result is a plain Debian
system on the SD card, reachable over the LCD console and over the network.

## What works

- **LCD console.** Kernel framebuffer console on `tty0`, text on the built-in
  640x480 panel. Both panel revisions are supported (default and rev6); the
  boot script selects the right device tree at runtime.
- **UART console.** `ttyS0` at 115200 stays `/dev/console`, so the kernel log
  and a getty are visible on the serial header from the first line.
- **Wi-Fi.** RTL8821CS over SDIO, `wpa_supplicant` + `systemd-networkd` DHCP.
  Supply the credentials on the FAT boot partition in `/boot/wifi.txt`.
- **Sound.** H616 codec through the internal speaker, side volume keys wired to
  the Line Out mixer through `triggerhappy`.
- **SSH.** `openssh-server` with host keys generated on first boot. Root login
  works with a password and with the public key baked into the image.
- **Gamepad as keyboard and mouse.** The [`rgpad`](https://github.com/GregoryPletnev/rg-pad)
  daemon maps the gamepad and both sticks to a virtual keyboard and mouse, so
  the device is usable without an external keyboard.
- **First-boot growth.** The root partition grows to the full SD card on the
  first boot; SSH host keys are regenerated then.

## Layout

The SD image uses an MBR table with two partitions:

| Partition | Start (512 B sectors) | Size | Filesystem | Content |
| --- | --- | --- | --- | --- |
| p1 | 2048 | 256 MiB | FAT32, label `BOOT` | `Image`, device trees, `boot.scr` |
| p2 | 526336 | 2056 MiB | ext4, label `rootfs` | Debian trixie arm64 rootfs |

U-Boot sits at offset 8 KiB. `boot.scr` loads the device tree and the kernel
from p1 and runs `booti`. The root filesystem is found by device path
(`root=/dev/mmcblk0p2`), not by label, because the kernel boots without an
initramfs.

## Requirements

Building needs a Debian or Ubuntu host (x86_64 or arm64) with:

- `qemu-user-static` and `binfmt-support` for the arm64 chroot
- `mmdebstrap`, `debootstrap`-style tooling
- `mkimage` from `u-boot-tools`
- `sfdisk`, `mkfs.vfat`, `e2fsprogs`, `parted`
- `git`, `curl`, `xz-utils`, `patch`, `perl`
- `sudo` for loop mounts and chroot

The Free Pascal compiler for `rgpad` and `uinject` comes from the arm64 chroot
that `build-rgpad.sh` creates; it needs no host FPC.

## Build

The scripts expect a work directory. Set `W` to point at it (default
`/home/builder/work`). The directory holds sources, build trees, and the
output in `$W/out`.

### 1. U-Boot

Build the first-stage payload:

```sh
W=$HOME/rg35xxh-work build-uboot-rk.sh
```

This fetches upstream U-Boot v2026.01, applies the ROCKNIX DRAM and AXP717
patches, uses the ROCKNIX `anbernic_rg35xx_h700_lpddr4_defconfig`, and links
against the ARM Trusted Firmware BL31 at `$W/build/atf/build/sun50i_h616/release/bl31.bin`.
Output: `$W/out/u-boot-sunxi-with-spl-rk.bin`.

`build-hybrid-uboot.sh` is an alternative that probes LPDDR4, LPDDR3, and DDR3
at boot, so one image works on boards with different DRAM. Use it only if you
have mixed hardware; the fixed LPDDR4 build is the normal path.

### 2. Kernel

```sh
W=$HOME/rg35xxh-work build-kernel-v15.sh
```

This unpacks Linux 7.1.2, applies the ROCKNIX H700 patch set in order (skipping
`0140` and `0150`, which need an out-of-tree joypad driver), then applies the
patches in `patches/linux/`. It backports the 7.2 SRAM-C device-tree layout
that the DE33 display pipeline needs on 7.1.2, and it fixes two references that
the skipped patches leave dangling. Panel init sequences are built into the
kernel as `EXTRA_FIRMWARE`, because the panel driver probes before the rootfs
mounts and there is no initramfs.

Output: `$W/build/k712rk/arch/arm64/boot/Image`, the device trees, and stripped
modules in `$W/build/modules-v15`.

### 3. Root filesystem

```sh
W=$HOME/rg35xxh-work KEYS=$HOME/authorized_keys build-rootfs-trixie.sh
```

This runs `mmdebstrap` for `trixie` arm64 and adds:

- systemd, `systemd-networkd`, `systemd-resolved`, zram swap
- `openssh-server`, `wpa_supplicant`, `iw`, `wireless-regdb`
- Mesa from trixie-backports (the 26.x `panvk` is about 3x faster than 25.0.7
  on the Mali-G31 under Shadeburn)
- `cage` and `grim` for a Wayland kiosk and screenshots
- `alsa-utils`, `triggerhappy`, `gpm`, console tools
- the `rgpad` binary, config, and unit from `$RGPAD_SRC` (default `$W/rgpad`)
- first-boot units: grow the root partition, regenerate SSH host keys, set the
  default ALSA mixer, import Wi-Fi from `/boot/wifi.txt`

Set `ROOT_PASSWD` to change the root password (default `rg35xxh`). Put your
public keys in `$KEYS`; they are installed for root.

Output: `$W/rootfs-trixie/rootfs.ext4`.

### 4. Assemble the image

```sh
W=$HOME/rg35xxh-work FLAVOR=trixie build-uboot-rk.sh   # once, if not done
W=$HOME/rg35xxh-work FLAVOR=trixie assemble-v15.sh
```

`assemble-v15.sh` writes the U-Boot payload at offset 8 KiB, creates the two
partitions, copies `Image`, both device trees, and `boot.scr` to p1, copies the
rootfs to p2, installs the kernel modules, and enables the services. Set
`FLAVOR=trixie` to use the Debian rootfs; the default is Buildroot.

Output: `$W/out/rg35xxh-mvp-v15.img`, with a `sha256sum` printed at the end.

## Flash

Write the image to an SD card (8 GB or larger):

```sh
sudo dd if=rg35xxh-mvp-v15.img of=/dev/sdX bs=4M conv=fsync status=progress
```

Replace `/dev/sdX` with the card device. Check the device name first: `dd` to
the wrong disk destroys it.

To get a smaller download, compress the image before publishing:

```sh
gzip -9 -k rg35xxh-mvp-v15.img
```

## First boot

1. If you want Wi-Fi without a cable, create `/boot/wifi.txt` on the FAT
   partition before the first boot:

   ```
   SSID=YourNetwork
   PASSWORD=YourPassword
   ```

   The `rg35xxh-wifi-import` unit reads it once and renames the file to
   `wifi.txt.applied`. For an open network, omit the `PASSWORD` line.

2. Insert the card and power on. The kernel log and a login prompt appear on the
   LCD and on the UART header. Log in as `root`.

3. The root partition grows to the full card on this first boot. Reboot after
   the grow unit finishes if you want the new size in the tools.

The panel revision selects the device tree automatically. To force the rev6
panel, create an empty file named `panel-rev6` on the FAT boot partition.

## Configuration

| What | Where |
| --- | --- |
| Wi-Fi credentials | `/boot/wifi.txt` on p1, imported on first boot |
| Wi-Fi config after import | `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` |
| Network | `/etc/systemd/network/80-wlan0.network` (DHCP on `wlan0`) |
| SSH | `root` with password and `authorized_keys`; keys regenerate on first boot |
| Gamepad mapping | `/etc/rgpad.conf`, apply with `systemctl restart rgpad` |
| Volume keys | `/etc/triggerhappy/triggers.d/rg35xxh-volume.conf` |
| Default mixer | `/etc/systemd/system/rg35xxh-audio-defaults.service` (first boot only) |

## Repository layout

| Path | Purpose |
| --- | --- |
| `build-uboot-rk.sh` | U-Boot v2026.01 + ROCKNIX DRAM/AXP717 patches, LPDDR4 |
| `build-hybrid-uboot.sh` | U-Boot with runtime DRAM type probe |
| `build-kernel-v15.sh` | Linux 7.1.2 + ROCKNIX H700 patch set + local fixes |
| `build-rootfs-trixie.sh` | Debian trixie arm64 rootfs with `mmdebstrap` |
| `assemble-v15.sh` | Assemble the SD image (U-Boot, kernel, rootfs, services) |
| `assemble-v14.sh` | Previous image layout, kept for reference |
| `boot-v15.scr.cmd` | U-Boot boot script source, compiled with `mkimage` |
| `patches/linux/` | Local kernel patches applied on top of ROCKNIX |
| `tools/uinject.pas` | Scripted virtual mouse for testing the TUI mouse path |

## Related

- [`rgpad`](https://github.com/GregoryPletnev/rg-pad): the gamepad to
  keyboard/mouse daemon installed by the rootfs script.

## Notes and limits

- The scripts build for the H700 with LPDDR4. The hybrid U-Boot covers other
  DRAM types; the kernel and rootfs do not depend on the DRAM type.
- The device tree comes from the ROCKNIX H700 tree plus the local patches. The
  upstream mainline device tree for the RG35XX-H is close but does not yet carry
  the full display pipeline for this panel.
- There is no initramfs. Anything the kernel needs before the rootfs mount
  (panel firmware, storage drivers) is built in.
- The root password and any key baked into the image are development defaults.
  Change them before you use the image on an untrusted network.

## License

MIT. See [LICENSE](LICENSE). The kernel, U-Boot, Debian, ROCKNIX patches, and
`rgpad` keep their own licenses.
