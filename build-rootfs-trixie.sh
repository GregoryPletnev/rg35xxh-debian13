#!/bin/bash
# Debian Trixie arm64 rootfs for RG35XXH (replaces the Buildroot rootfs on p2).
# Kernel, modules, DTB and boot chain stay from build-kernel-v15.sh; modules are
# added by assemble-v15.sh. Needs: mmdebstrap qemu-user-static binfmt-support.
# Output: $W/rootfs-trixie/rootfs.ext4
set -euo pipefail
W=${W:-/home/builder/work}
OUT=$W/rootfs-trixie
ROOT=$OUT/root
IMG=$OUT/rootfs.ext4
KEYS=${KEYS:-$W/authorized_keys}
ROOT_PASSWD=${ROOT_PASSWD:-rg35xxh}
MIRROR=http://deb.debian.org/debian

PKGS=(
  systemd-sysv udev dbus libpam-systemd systemd-resolved systemd-timesyncd
  systemd-zram-generator
  openssh-server wpasupplicant iw wireless-regdb iproute2 iputils-ping
  ca-certificates curl wget rsync
  sudo bash-completion less nano mc htop tmux procps psmisc file
  kbd usbutils dosfstools e2fsprogs fdisk cloud-guest-utils gpm
  alsa-utils triggerhappy
)
# Mesa from trixie-backports (26.x): panvk caches pipelines on disk and draws
# Shadeburn ~3x faster on the Mali-G31 than trixie's 25.0.7.  The loaders
# (glvnd, vulkan-loader) come from trixie main.
MESA_PKGS=(
  mesa-vulkan-drivers mesa-libgallium libgl1-mesa-dri libegl-mesa0 libgbm1
  libglx-mesa0 libegl1 libgles2 libgl1 libvulkan1
)
# Wayland kiosk for full-screen apps (Shadeburn runs under cage) + screenshots;
# installed after Mesa so wlroots resolves to the backports Mesa
GUI_PKGS=(cage grim)
RGPAD_SRC=${RGPAD_SRC:-$W/rgpad}

test -f "$KEYS"
test -x "$W/out/rgpad"   # rgpad/build-rgpad.sh
sudo rm -rf "$OUT"; mkdir -p "$ROOT"

sudo mmdebstrap --architectures=arm64 --variant=minbase \
  --components="main contrib non-free non-free-firmware" \
  --include="$(IFS=,; echo "${PKGS[*]}")" \
  --customize-hook="chroot \"\$1\" apt-get install -y -q --no-install-recommends -t trixie-backports ${MESA_PKGS[*]}" \
  --customize-hook="chroot \"\$1\" apt-get install -y -q ${GUI_PKGS[*]}" \
  --customize-hook='echo "deb http://deb.debian.org/debian-security trixie-security main contrib non-free non-free-firmware" >> "$1/etc/apt/sources.list"' \
  trixie "$ROOT" \
  "deb $MIRROR trixie main contrib non-free non-free-firmware" \
  "deb $MIRROR trixie-updates main contrib non-free non-free-firmware" \
  "deb $MIRROR trixie-backports main contrib non-free non-free-firmware"

R() { sudo tee "$ROOT/$1" >/dev/null; }

echo rg35xxh | R etc/hostname
R etc/hosts <<'EOF'
127.0.0.1	localhost
127.0.1.1	rg35xxh
::1		localhost ip6-localhost ip6-loopback
EOF
R etc/fstab <<'EOF'
/dev/mmcblk0p2	/	ext4	defaults,noatime,commit=60	0 1
/dev/mmcblk0p1	/boot	vfat	defaults,nofail,umask=0022	0 2
EOF
echo 'LANG=C.UTF-8' | R etc/default/locale

# --- network: wpa_supplicant@wlan0 + systemd-networkd DHCP + resolved
R etc/systemd/network/80-wlan0.network <<'EOF'
[Match]
Name=wlan0

[Network]
DHCP=yes
EOF
sudo mkdir -p "$ROOT/etc/wpa_supplicant"
R etc/wpa_supplicant/wpa_supplicant-wlan0.conf <<'EOF'
ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev
update_config=1
country=RU
EOF
sudo chmod 600 "$ROOT/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
# RTL8821CS drops into "ghost connected" with power save on
R etc/udev/rules.d/70-wlan-powersave.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan0", RUN+="/usr/sbin/iw dev wlan0 set power_save off"
EOF

# Wi-Fi from the FAT BOOT partition: /boot/wifi.txt with SSID=... and PASSWORD=...
R usr/local/sbin/rg35xxh-wifi-import <<'EOF'
#!/bin/sh
set -eu
SRC=/boot/wifi.txt
CONF=/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
SSID=$(sed -n 's/\r$//; s/^SSID=//p' "$SRC" | head -n1)
PASS=$(sed -n 's/\r$//; s/^PASSWORD=//p' "$SRC" | head -n1)
[ -n "$SSID" ] || { echo "wifi.txt: no SSID=" >&2; exit 1; }
{
  printf 'ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev\nupdate_config=1\ncountry=RU\n'
  if [ -n "$PASS" ]; then
    wpa_passphrase "$SSID" "$PASS" | grep -v '^\s*#psk='
  else
    printf 'network={\n\tssid="%s"\n\tkey_mgmt=NONE\n}\n' "$SSID"
  fi
} > "$CONF.new"
chmod 600 "$CONF.new"
mv "$CONF.new" "$CONF"
mv "$SRC" "$SRC.applied"
echo "Wi-Fi network '$SSID' imported from $SRC"
EOF
sudo chmod 755 "$ROOT/usr/local/sbin/rg35xxh-wifi-import"
R etc/systemd/system/rg35xxh-wifi-import.service <<'EOF'
[Unit]
Description=Import Wi-Fi settings from /boot/wifi.txt
RequiresMountsFor=/boot
ConditionPathExists=/boot/wifi.txt
Before=wpa_supplicant@wlan0.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rg35xxh-wifi-import

[Install]
WantedBy=multi-user.target
EOF

# --- first boot: grow p2 to the whole card, fresh SSH host keys
R etc/systemd/system/rg35xxh-growfs.service <<'EOF'
[Unit]
Description=Grow root partition and filesystem to the whole SD card
ConditionPathExists=!/var/lib/rg35xxh/grown
After=local-fs.target

[Service]
Type=oneshot
ExecStart=-/usr/bin/growpart /dev/mmcblk0 2
ExecStart=/usr/sbin/resize2fs /dev/mmcblk0p2
ExecStart=/usr/bin/mkdir -p /var/lib/rg35xxh
ExecStart=/usr/bin/touch /var/lib/rg35xxh/grown

[Install]
WantedBy=multi-user.target
EOF
R etc/systemd/system/rg35xxh-ssh-hostkeys.service <<'EOF'
[Unit]
Description=Generate SSH host keys on first boot
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key
Before=ssh.service

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF
sudo rm -f "$ROOT"/etc/ssh/ssh_host_*
# Debian's default is prohibit-password; root also logs in with ROOT_PASSWD
R etc/ssh/sshd_config.d/rg35xxh.conf <<'EOF'
PermitRootLogin yes
EOF

R etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = ram / 2
EOF

# --- sound: the H616 codec powers its DAC (and only then asks for DMA) once
# DAPM sees a path to an output, and every switch on that path boots off.
# Without it playback stalls with hw_ptr stuck.  First boot only; afterwards
# alsa-restore keeps whatever the user set.
R etc/systemd/system/rg35xxh-audio-defaults.service <<'EOF'
[Unit]
Description=Default mixer for the H616 codec: DAC -> Line Out -> speaker
ConditionPathExists=!/var/lib/alsa/asound.state
After=alsa-restore.service sound.target

[Service]
Type=oneshot
ExecStart=/usr/bin/amixer -q -c 0 cset name='DAC Playback Switch' on,on
ExecStart=/usr/bin/amixer -q -c 0 cset name='Line Out Source Playback Route' Stereo,Stereo
ExecStart=/usr/bin/amixer -q -c 0 cset name='Line Out Playback Switch' on,on
ExecStart=/usr/bin/amixer -q -c 0 cset name='Speaker Switch' on
ExecStart=/usr/bin/amixer -q -c 0 cset name='DAC Playback Volume' 100%
ExecStart=/usr/bin/amixer -q -c 0 cset name='Line Out Playback Volume' 80%
ExecStart=/usr/sbin/alsactl store 0

[Install]
WantedBy=multi-user.target
EOF

# side volume keys (gpio-keys-volume) -> Line Out; thd reads without grabbing,
# so they work on the console and under cage alike
R etc/triggerhappy/triggers.d/rg35xxh-volume.conf <<'EOF'
# RG35XX-H side volume keys (gpio-keys-volume): Line Out, 32 steps
KEY_VOLUMEUP	1	/usr/bin/amixer -q -c 0 sset "Line Out" 1+
KEY_VOLUMEUP	2	/usr/bin/amixer -q -c 0 sset "Line Out" 1+
KEY_VOLUMEDOWN	1	/usr/bin/amixer -q -c 0 sset "Line Out" 1-
KEY_VOLUMEDOWN	2	/usr/bin/amixer -q -c 0 sset "Line Out" 1-
EOF
sudo mkdir -p "$ROOT/etc/systemd/system/triggerhappy.service.d"
R etc/systemd/system/triggerhappy.service.d/rg35xxh.conf <<'EOF'
# amixer needs /dev/snd (group audio); nobody has no access to it.
# Only the volume keys: thd 0.5.0 stops handling every device after a few
# hot-unplugs (rgpad's uinput devices come and go), so it never sees those.
[Service]
ExecStart=
ExecStart=/usr/sbin/thd --triggers /etc/triggerhappy/triggers.d/ --socket /run/thd.socket --deviceglob /dev/input/by-path/platform-gpio-keys-volume-event
EOF
# the packaged udev rule hands thd every new input device; the keys are built in
sudo ln -sf /dev/null "$ROOT/etc/udev/rules.d/60-triggerhappy.rules"

# gamepad -> keyboard/mouse daemon (Free Pascal, see rgpad/)
sudo install -m 755 "$W/out/rgpad" "$ROOT/usr/local/bin/rgpad"
sudo install -m 644 "$RGPAD_SRC/rgpad.conf" "$ROOT/etc/rgpad.conf"
sudo install -m 644 "$RGPAD_SRC/rgpad.service" "$ROOT/etc/systemd/system/rgpad.service"

sudo install -d -m 700 "$ROOT/root/.ssh"
sudo install -m 600 "$KEYS" "$ROOT/root/.ssh/authorized_keys"

sudo chroot "$ROOT" /bin/sh -e <<EOF
echo "root:$ROOT_PASSWD" | chpasswd
systemctl enable systemd-networkd systemd-resolved systemd-timesyncd \
  wpa_supplicant@wlan0 rg35xxh-wifi-import rg35xxh-growfs rg35xxh-ssh-hostkeys \
  rgpad rg35xxh-audio-defaults
systemctl disable wpa_supplicant.service || true
# thd makes /run/thd.socket itself; the packaged socket unit only fails on it
systemctl enable triggerhappy.service
systemctl mask triggerhappy.socket
ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
dpkg-query -W mesa-vulkan-drivers | grep -q '~bpo'
apt-get clean
rm -rf /var/lib/apt/lists/*
EOF

SIZE_MB=$(( $(sudo du -sm "$ROOT" | cut -f1) * 13 / 10 + 64 ))
rm -f "$IMG"
sudo mkfs.ext4 -q -L rootfs -m 1 -d "$ROOT" "$IMG" ${SIZE_MB}M
sudo chown "$(id -u):$(id -g)" "$IMG"
sudo du -sh "$ROOT"
ls -la "$IMG"
echo DONE_ROOTFS_TRIXIE
