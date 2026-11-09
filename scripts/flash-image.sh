#!/usr/bin/env bash
# Flash an Orange Pi 6 Plus OS image onto a USB-attached SSD and grow the
# rootfs to fill the disk.
#
# The board's UEFI lives in SPI flash and boots NVMe first, so the image's own
# GPT is usable as-is -- unlike Rockchip boards, nothing has to be written to
# fixed sector offsets.
#
#   sudo ./flash-image.sh --device /dev/sda --image ~/Downloads/Orangepi6plus_*.img.xz

set -euo pipefail

readonly PROG=${0##*/}

die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }

usage() {
	cat <<-EOF
		Usage: sudo $PROG --device /dev/sdX --image <file> [--yes]

		  --device DEV   Whole-disk device to ERASE (e.g. /dev/sda)
		  --image FILE   OS image: .img, .img.xz, .img.gz, .img.zst or .img.bz2
		  --yes          Skip the interactive confirmation
	EOF
}

dev=
img=
assume_yes=0

while (($#)); do
	case $1 in
	--device)
		dev=${2:?--device needs a value}
		shift 2
		;;
	--image)
		img=${2:?--image needs a value}
		shift 2
		;;
	--yes)
		assume_yes=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown argument: $1" ;;
	esac
done

[[ -n $dev && -n $img ]] || {
	usage >&2
	exit 2
}
((EUID == 0)) || die "must run as root (use sudo)"
[[ -b $dev ]] || die "$dev is not a block device"
[[ -f $img ]] || die "$img is not a readable file"

# Refuse anything that is not a whole disk; writing an image to a partition
# would destroy the table we then try to read back.
[[ $(lsblk -dno TYPE "$dev") == disk ]] || die "$dev is not a whole disk"

# Hard interlock against the laptop's own system disk.
root_src=$(findmnt -no SOURCE / || true)
root_disk=$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1 || true)
if [[ -n $root_disk && /dev/$root_disk == "$dev" ]]; then
	die "$dev holds the running root filesystem"
fi

if lsblk -nro MOUNTPOINT "$dev" | grep -q '[^[:space:]]'; then
	lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT "$dev" >&2
	die "$dev has mounted filesystems -- unmount them first"
fi

case $img in
*.img) decompress=(cat --) ;;
*.xz) decompress=(xz -dc --) ;;
*.gz) decompress=(gzip -dc --) ;;
*.zst) decompress=(zstd -dc --) ;;
*.bz2) decompress=(bzip2 -dc --) ;;
*) die "unrecognised image extension: $img" ;;
esac
command -v "${decompress[0]}" >/dev/null || die "${decompress[0]} is not installed"

info "Target device"
lsblk -o NAME,SIZE,TYPE,TRAN,MODEL,SERIAL,FSTYPE,LABEL "$dev"
printf '\nImage: %s (%s)\n' "$img" "$(du -h "$img" | cut -f1)"

if ((!assume_yes)); then
	printf '\nALL DATA ON %s WILL BE DESTROYED.\nType the device name to confirm: ' "$dev"
	read -r reply
	[[ $reply == "$dev" ]] || die "confirmation did not match -- nothing written"
fi

info "Clearing existing signatures"
wipefs -a "$dev"

info "Writing image (this takes a while over USB)"
"${decompress[@]}" "$img" | dd of="$dev" bs=4M conv=fsync iflag=fullblock status=progress
sync
udevadm settle
partprobe "$dev" || true
udevadm settle

# The image's GPT was built for a small card, so its backup header sits in the
# middle of a 1TB disk. Relocating it is a precondition for growing the last
# partition and keeps UEFI from seeing a corrupt table.
info "Relocating GPT backup header to end of disk"
sgdisk -e "$dev"
partprobe "$dev" || true
udevadm settle

info "Partitions after flash"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL "$dev"

# The rootfs is the largest ext4 partition; vendor images pair it with a small
# ESP or boot partition.
root_name=$(lsblk -bnro NAME,FSTYPE,SIZE,TYPE "$dev" |
	awk '$4=="part" && $2=="ext4" {print $3, $1}' | sort -rn | head -1 | awk '{print $2}')
[[ -n $root_name ]] || die "no ext4 partition found -- is this an Orange Pi OS image?"

root_part=/dev/$root_name
part_num=$(<"/sys/class/block/$root_name/partition")
part_uuid_before=$(blkid -s PARTUUID -o value "$root_part")

info "Growing $root_part (partition $part_num) to fill the disk"
parted -s "$dev" resizepart "$part_num" 100%
partprobe "$dev" || true
udevadm settle

set +e
e2fsck -fy "$root_part"
fsck_rc=$?
set -e
((fsck_rc <= 2)) || die "e2fsck failed on $root_part (rc=$fsck_rc)"

resize2fs "$root_part"

# fstab in the image references the rootfs by UUID or PARTUUID; a changed
# PARTUUID here would leave the board unable to find its root.
part_uuid_after=$(blkid -s PARTUUID -o value "$root_part")
[[ $part_uuid_before == "$part_uuid_after" ]] ||
	die "PARTUUID changed ($part_uuid_before -> $part_uuid_after) -- fstab will not match"

sync
info "Done"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL "$dev"
printf '\nRootfs: %s  PARTUUID=%s\nNext:   sudo ./make-headless.sh --device %s ...\n' \
	"$root_part" "$part_uuid_after" "$dev"
