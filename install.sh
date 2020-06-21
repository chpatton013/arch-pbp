#!/usr/bin/env bash
set -euo pipefail

#
# Booting from live install media `archiso-pbp`:
#   https://github.com/nadiaholmquist/archiso-pbp
#
# This image is configured to use a Nadia's pacman user repository, which hosts
# several useful packages we will be installing. You can check out the contents
# of that repository here:
#   https://nhp.sh/pinebookpro/
#
# Thank you Nadia, your ISO and package repository were incredibly helpful!
#
# Installation will require an internet connection. `dhcpd` should already be
# running, so if you have connected a wired network interface you should be
# fine. But if you want to use wireless you will need to connect explicitly and
# acquire a DHCP lease manually:
#   Open networks:  `iw dev wlan0 connect "SSID"`
#   WEP networks:   `iw dev wlan0 connect "SSID" key "0:KEY"`
#   WPA networks:   `wpa_supplicant -B -iwlan0 -c <(wpa_passphrase "SSID" "KEY")
#   DHCP:           `dhclient`
#
# The Rockchip boot sequence is described in detail on their wiki:
#   http://opensource.rock-chips.com/wiki_Boot_option
#
# We will be implementing "Boot Flow 2", as described on that page. In summary:
#
#   The Rockchip BootRom will invoke the Secondary Program Loader (SPL, also
#   called the "pre-loader" or "loader1") found at sector 0x40 on the boot
#   device. The purpose of this program is to define (or ID) the Trusted
#   Execution Environment (TEE) parameters before yielding to the next boot
#   stage.
#
#   The SPL then invokes the Tertiary Program Loader (TPL, also called the
#   "boot-loader" or "loader2") found at sector 0x4000 on the boot device. The
#   purpose of this program is to initialize the ramdisk with the trusted
#   bootloader.
#
#   The TPL then searches for a filesystem on a partition found at sector 0x8000
#   on the boot device, also called the "boot partition". The filesystem on this
#   partition must have a configuration file that UBoot will read to identify
#   the kernel image (also a file on the same filesystem). The TPL invokes this
#   kernel image, which later completes the boot sequence.
#
# We are going to try to stick to the normal steps laid out in the ArchLinux
# Installation Guide:
#   https://wiki.archlinux.org/index.php/Installation_guide
# I will call out any differences as we go.
#
# Step 1: Prepare Installation Media
#
# We will prepare the install media like-so, using GPT to allocate the
# partitions that will later host filesystems, but leaving enough space at the
# beginning of the device for the bootloader images:
#
#   /dev/mmcblk2
#    |\- 0x00000000: GPT
#    |\- 0x00000040: SPL
#    |\- 0x00004000: TPL
#    |\- 0x00008000: Boot Partition: 128MB
#    |    \- FS: ext4: /boot
#     \- 0x00048800 Root Partition: Remaining Space
#         \- CryptRoot
#             \- FS: ext4: /
#
# Step 2: Install Packages
#
# We will install the packages we need to have an operational system.
# Traditionally this set is just `base` (which is what makes this an ArchLinux
# system), `linux` (the kernel), `linux-firmware` (the firmware for your version
# of the kernel), and whichever bootloader you want to use. However, we are
# going to need to make a few changes to that for the Pinebook Pro.
# * First, we need to make sure we have the `cryptsetup` package installed so we
#   can build an initramfs capable of decrypting our root partition.
# * Next, we need the kernel (and its headers) tailored to the Pinebook Pro. We
#   will use the `linux-pbp` package from NHP's aforementioned repository.
# * Likewise, there are a few Pinebook Pro firmware packages that
#   `linux-firmware` is missing. We will take those from NHP's repository as
#   well.
# * The Pinebook Pro makes the choice of bootloader for us: we have to use
#   UBoot. However just like several other packages, there is a specialized
#   version of UBoot for the Pinebook Pro: `uboot-pbp` (also available in NHP's
#   repository).
#
# Step 3: Configure System
#
# This step is essentially identical to the installation guide. We set up our
# timezone, localization, and network settings.
#
# Step 4: Create Initramfs
#
# We need to customize the configuration for `mkinitcpio`, then invoke it to
# regenerate our initramfs.
#
# Since we are setting up full-disk encryption, we will want our hooks to match
# those described in the ArchWiki:
#   https://wiki.archlinux.org/index.php/Dm-crypt/Encrypting_an_entire_system#Configuring_mkinitcpio
#
# Note that order matters, and I've removed `consolefont` because it raised
# warnings in the creation process
# ```
# HOOKS=(base udev autodetect keyboard keymap modconf block encrypt filesystems fsck)
# ```
#
# The Pinebook Pro is not perfectly-well-supported by mainline-Linux yet, so we
# will need to do a little bit of hand-holding in the process of selecting
# modules. I did not determine this list myself; I stole it from Rudis' blog,
# who in turn took it from a Pine64 forum post:
#   https://rudism.com/installing-arch-linux-on-the-pinebook-pro/
#   https://forum.pine64.org/showthread.php?tid=9052
#
# Note again that the order matters. I've annotated what each module does, but I
# don't know why they are all necessary (or sufficient):
# ```
# MODULES=(
#   panfrost # Panfrost (DRM support for ARM Mali Midgard/Bifrost GPUs)
#   rockchipdrm # DRM Support for Rockchip
#   hantro_vpu # Hantro VPU driver
#   analogix_dp # Analogix Display Port driver
#   rockchip_rga # 2D Graphics Hardware Acceleration
#   panel_simple # DRM panel driver for dumb panels
#   arc_uart # ARC UART driver support
#   cw2015_battery # CW2015 Battery driver
#   i2c-hid # HID over I2C transport layer
#   iscsi_boot_sysfs # iSCSI Boot Sysfs Interface
#   jsm # Digi International NEO and Classic PCI Support
#   pwm_bl # Simple PWM based backlight control
#   uhid # User-space I/O driver support for HID subsystem
# )
# ```
#
# Step 5: Install Bootloader
#
# As we alluded to in the beginning, this is the weird part of setting up the
# Pinebook Pro. Normally you have a certain partition that you install your
# bootloader to, and then you run a tool that configures your bootloader to load
# your kernel correctly. Well with the Pinebook Pro, instead of a partition we
# have sacred disk sectors, and instead of a config tool we have a text file.
#
# We use `dd` to write two different images to specific disk sectors on the boot
# device, and then populate the Syslinux `extlinux.conf` file with relative
# paths to the kernel image, the flattened device tree, and the Linux
# command-line. That command-line is yet-another list of strings you have to get
# just right or your system won't boot.
#
# I referred to that same Pine64 forum post to see what someone else had used:
#   https://forum.pine64.org/showthread.php?tid=9052
#
# Then I referred to the ArchWiki page on relevant kernel parameters to make
# sure there wasn't anything I was missing:
#   https://wiki.archlinux.org/index.php/Kernel_parameters
#
# And briefly entertained the notion of reviewing all the available parameters,
# but the number of them scared me off pretty quickly:
#   https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html
#
# This is the minimal set that I went with:
# ```
# initrd=/initramfs-linux.img
# console=tty1
# cryptdevice=/dev/mmcblk2p2:cryptroot
# root=/dev/mapper/cryptroot
# rw
# rootwait
# video=eDP-1:1920x1080@60
# ```
#
# Step 6. Profit
#
# After shutting down, removing the SD card, and powering the machine back on, I
# was greeted with the familiar output of a botting Linux kernel. I decrypted
# the root volume when-prompted, then logged in as `root`. I've still got loads
# of post-install customization to do, but the hard part is behind me!
#

emmc_device=/dev/mmcblk2
spl_offset=64      # sector 0x40
tpl_offset=16384   # sector 0x4000
boot_offset=32768  # sector 0x8000
boot_end=294912    # boot + 128MB
root_offset=296960 # boot-end + 2048
emmc_boot_partition="${emmc_device}p1"
emmc_root_partition="${emmc_device}p2"
cryptroot_password=hunter2
root_user_password=hunter2
randomize_root=

base_packages=(
  cryptsetup
)
kernel_package=linux-pbp
firmware_packages=(
  linux-firmware
  ap6256-firmware
  linux-atm
  pbp-keyboard-hwdb
  pinebookpro-audio
)
bootloader_package=uboot-pbp

hostname=arch-pbp
locale=en_US.UTF-8
charset=UTF-8
keymap=us
timezone="$(
  curl --silent http://ip-api.com/json |
    sed --expression 's#.*\"timezone\":\"\([^\"]*\)\".*#\1#'
)"

initcpio_modules=(
  panfrost # Panfrost (DRM support for ARM Mali Midgard/Bifrost GPUs)
  rockchipdrm # DRM Support for Rockchip
  hantro_vpu # Hantro VPU driver
  analogix_dp # Analogix Display Port driver
  rockchip_rga # 2D Graphics Hardware Acceleration
  panel_simple # DRM panel driver for dumb panels
  arc_uart # ARC UART driver support
  cw2015_battery # CW2015 Battery driver
  i2c-hid # HID over I2C transport layer
  iscsi_boot_sysfs # iSCSI Boot Sysfs Interface
  jsm # Digi International NEO and Classic PCI Support
  pwm_bl # Simple PWM based backlight control
  uhid # User-space I/O driver support for HID subsystem
)
initcpio_binaries=()
initcpio_files=()
initcpio_hooks=(
  base
  udev
  keyboard
  autodetect
  keymap
  modconf
  block
  encrypt
  filesystems
  fsck
)
initcpio_compression=xz

linux_cmdline=(
  initrd=/initramfs-linux.img
  console=tty1
  cryptdevice=$emmc_root_partition:cryptroot
  root=/dev/mapper/cryptroot
  rw
  rootwait
  video=eDP-1:1920x1080@60
)

echo ::
echo :: Update System Clock
echo ::
(
  set -x
  timedatectl set-ntp true
)

echo ::
echo :: Prepare Installation Media
echo ::
(
  set -x

  # Create the partition table
  parted --script -- "$emmc_device" mklabel gpt
  parted --script -- "$emmc_device" \
    unit s \
    mkpart primary "$boot_offset" "$boot_end" \
    name 1 boot
  parted --script -- "$emmc_device" \
    unit s \
    mkpart primary "$root_offset" 100% \
    name 2 root

  if [ ! -z "$randomize_root" ]; then
    # Randomize the root partition
    cryptsetup --batch-mode --key-file /dev/random \
      open "$emmc_root_partition" randomize_root --type plain
    dd if=/dev/zero of=/dev/mapper/randomize_root bs=16M status=progress
    cryptsetup --batch-mode close randomize_root
  fi

  # Create a persistent encryption key
  dd if=/dev/random of=/tmp/cryptroot.key iflag=fullblock bs=2048 count=1
  chmod 0000 /tmp/cryptroot.key

  # Create an encrypted volume, add a passphrase, and open it
  cryptsetup --batch-mode --key-file /tmp/cryptroot.key \
    luksFormat --type luks2 "$emmc_root_partition"
  echo "$cryptroot_password" |
    cryptsetup --batch-mode --key-file /tmp/cryptroot.key \
      luksAddKey "$emmc_root_partition"
  cryptsetup --batch-mode --key-file /tmp/cryptroot.key \
    open "$emmc_root_partition" cryptroot

  # Make, mount, and populate the root partition
  mkfs --type=ext4 -F /dev/mapper/cryptroot
  mount /dev/mapper/cryptroot /mnt
  mkdir /mnt/boot /mnt/etc /mnt/root /mnt/root/cryptkeys
  chmod 0755 /mnt/boot /mnt/etc
  chmod 0700 /mnt/root /mnt/root/cryptkeys
  cp /tmp/cryptroot.key /mnt/root/cryptkeys/cryptroot.key
  chmod 0000 /mnt/root/cryptkeys/cryptroot.key

  # Make and mount the boot partition
  mkfs --type=ext4 -F "$emmc_boot_partition"
  mount "$emmc_boot_partition" /mnt/boot

  # Write the crypttab and fstab files to the root partition
  cat >/mnt/etc/crypttab <<EOF
cryptroot $emmc_root_partition /root/cryptkeys/cryptroot.key
EOF
  genfstab -U /mnt >/mnt/etc/fstab
)

echo ::
echo :: Install Packages
echo ::
(
  set -x
  pacstrap /mnt \
    base "${base_packages[@]}" \
    "$kernel_package" "$kernel_package-headers" \
    "${firmware_packages[@]}" \
    "$bootloader_package"
)

echo ::
echo :: Configure System
echo ::
(
  set -x

  # Systemd
  systemd-firstboot \
    --setup-machine-id \
    --timezone="$timezone" \
    --locale="$locale" \
    --keymap="$keymap" \
    --hostname="$hostname" \
    --root-password="$root_user_password" \
    --root=/mnt

  # Timezone
  ln --symbolic --force "/usr/share/zoneinfo/$timezone" /mnt/etc/localtime
  arch-chroot /mnt hwclock --systohc

  # Locale
  echo $locale $charset >/mnt/etc/locale.gen
  echo LANG=$locale >/mnt/etc/locale.conf
  echo KEYMAP=$keymap >/mnt/etc/vconsole.conf
  arch-chroot /mnt locale-gen

  # Network
  echo $hostname >/mnt/etc/hostname
  cat >/mnt/etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 $hostname.localdomain $hostname
EOF
)

echo ::
echo :: Create Initramfs
echo ::
(
  set -x
  cat >/mnt/etc/mkinitcpio.conf <<EOF
MODULES=(${initcpio_modules[@]})
BINARIES=(${initcpio_binaries[@]})
FILES=(${initcpio_files[@]})
HOOKS=(${initcpio_hooks[@]})
COMPRESSION="$initcpio_compression"
EOF
  arch-chroot /mnt mkinitcpio −−allpresets
)

echo ::
echo :: Install Bootloader
echo ::
(
  set -x

  # Write bootloader images
  dd if=/mnt/boot/idbloader.img of="$emmc_device" seek="$spl_offset" conv=notrunc
  dd if=/mnt/boot/u-boot.itb of="$emmc_device" seek="$tpl_offset" conv=notrunc

  # Write extlinux config file to boot partition
  cat >/mnt/boot/extlinux/extlinux.conf <<EOF
LABEL Arch Linux ARM
KERNEL /Image
FDT /dtbs/rockchip/rk3399-pinebook-pro.dtb
APPEND ${linux_cmdline[@]}
EOF
)

echo ::
echo :: Clean Up
echo ::
(
  set -x
  sync
  umount /mnt/boot
  umount /mnt
  cryptsetup --batch-mode close cryptroot
)
