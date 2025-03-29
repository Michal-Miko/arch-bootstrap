#!/bin/bash
# WARNING: this script will destroy data on the selected drive

set -uo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

# Collect configuration input from the user
read -rp "Hostname: " hostname
read -rp "Username: " username
read -srp "Password: " password
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

# Partitions
parted --script "${drive}" -- mklabel gpt \
  mkpart primary ESP fat32 1MiB 1024MiB \
  set 1 esp on \
  mkpart primary linux-swap 1024MiB "${swap_end}MiB" \
  mkpart primary ext4 "${swap_end}MiB" 100% \
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


