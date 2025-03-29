#!/bin/bash
# WARNING: this script will destroy data on the selected drive

set -uo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

mount -o remount,size=4G /run/archiso/cowspace
pacman -Syy base-devel rustup git fzf --noconfirm

git clone -b initial_version https://github.com/michal-miko/arch-bootstrap.git /tmp/arch-bootstrap
git clone https://aur.archlinux.org/paru.git /tmp/paru
cp /tmp/arch-bootstrap/pkg/mm-arch/pacman.conf /etc/pacman.conf

# Define a local repository for paru and the local meta packages
cat <<EOF >> /etc/pacman.conf
[tmplocal]
SigLevel = Optional TrustAll
Server = file:///tmp/local-repo
EOF
mkdir -p /tmp/local-repo
repo-add /tmp/local-repo/tmplocal.db.tar.gz

# Collect configuration input from the user
read -rp "Hostname: " hostname
read -rp "Username: " username
read -srp "Password: " password
packages="mm-arch-base mm-arch-k8s mm-arch-kde"
chosen_meta_pkg=$(printf "%s\n" $packages | fzf --height 10 --prompt "Chose the base package: ")
swap_size=8192
swap_end=$((1024 + swap_size))

# Select the installation drive with fzf
lsblk
drive_list=$(lsblk -dlnpx size -o name,size | grep -vE "boot|rpmb|loop")
drive=$(echo "${drive_list[@]}" | fzf --height 10 --prompt "Drive: " --layout reverse | awk '{print $1}')

if [[ -z "$drive" ]]; then
  echo "No drive selected. Exiting..."
  exit 1
fi

echo "Selected drive: $drive"

exec 1> >(tee -a stdout.log)
exec 2> >(tee -a stderr.log)

timedatectl set-ntp true

# Add a build user
useradd -Um build

# Prepare the meta packages
cd /tmp/arch-bootstrap/pkg/mm-arch
chown -R build:build .
su build -c "makepkg -s"
chown root:root ./*.pkg.tar.zst
mv ./*.pkg.tar.zst /tmp/local-repo

# Perepare the paru packages
cd /tmp/paru
chown -R build:build .
su build -c "rustup default stable"
su build -c "makepkg -s"
chown root:root ./*.pkg.tar.zst
mv ./*.pkg.tar.zst /tmp/local-repo

# Update the local repository
repo-add /tmp/local-repo/tmplocal.db.tar.gz /tmp/local-repo/*.pkg.tar.zst

# Partitions
parted --script "${drive}" -- mklabel gpt \
  mkpart ESP fat32 1MiB 1024MiB \
  set 1 esp on \
  mkpart swap linux-swap 1024MiB "${swap_end}MiB" \
  mkpart root ext4 "${swap_end}MiB" 100% \
  print

boot_part="$(ls "${drive}"* | grep -E "^${drive}p?1$")"
swap_part="$(ls "${drive}"* | grep -E "^${drive}p?2$")"
root_part="$(ls "${drive}"* | grep -E "^${drive}p?3$")"

wipefs "${boot_part}"
wipefs "${swap_part}"
wipefs "${root_part}"

mkfs.fat -F32 "${boot_part}"
mkswap "${swap_part}"
mkfs.ext4 "${root_part}"

# Mounts
mount "${root_part}" /mnt
mount --mkdir "${boot_part}" /mnt/boot
swapon "${swap_part}"

# Install the chosen meta-package and paru
pacman -Sy
pacstrap /mnt "${chosen_meta_pkg}" paru

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Configure the system
arch-chroot /mnt ln -sf /usr/share/zoneinfo/Europe/Warsaw /etc/localtime
arch-chroot /mnt hwclock --systohc
arch-chroot /mnt sed -i 's/#\(en_US\.UTF-8\)/\1/' /etc/locale.gen
arch-chroot /mnt locale-gen
arch-chroot /mnt echo "LANG=en_US.UTF-8" > /etc/locale.conf
arch-chroot /mnt echo "KEYMAP=pl" > /etc/vconsole.conf
arch-chroot /mnt echo "${hostname}" > /mnt/etc/hostname
arch-chroot /mnt useradd -mU -s /usr/bin/fish -G wheel "${username}"
arch-chroot /mnt chsh -s /usr/bin/fish
echo "${username}:${password}" | chpasswd --root /mnt
echo "root:${password}" | chpasswd --root /mnt

# Configure the bootloader
arch-chroot /mnt bootctl install
cat <<EOF > /mnt/boot/loader/loader.conf
default arch
timeout 3
EOF

cat <<EOF > /mnt/boot/loader/entries/arch.conf
title Arch Linux
linux /vmlinuz-linux
initrd /initramfs-linux.img
options root=PARTUUID=$(blkid -s PARTUUID -o value "${root_part}") rw
EOF

cat <<EOF > /mnt/boot/loader/entries/arch-fallback.conf
title Arch Linux Fallback
linux /vmlinuz-linux
initrd /initramfs-linux.img
options root=PARTUUID=$(blkid -s PARTUUID -o value "${root_part}") rw
EOF

# Enable services
mkdir -pm /mnt/etc/systemd/system/multi-user.target.wants
arch-chroot /mnt ln -sf /usr/lib/systemd/system/systemd-networkd.service /etc/systemd/system/multi-user.target.wants/systemd-networkd.service
arch-chroot /mnt ln -sf /usr/lib/systemd/system/systemd-resolved.service /etc/systemd/system/multi-user.target.wants/systemd-resolved.service
arch-chroot /mnt ln -sf /usr/lib/systemd/system/sshd.service /etc/systemd/system/multi-user.target.wants/sshd.service

# Set the default rust toolchain
arch-chroot /mnt rustup default stable
