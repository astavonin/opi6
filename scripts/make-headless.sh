#!/usr/bin/env bash
# Make a freshly flashed Orange Pi 6 Plus rootfs come up headless: joins WiFi,
# runs sshd, accepts a known key, answers to a known hostname.
#
# Pure file injection -- no arm64 chroot is available on an x86 laptop without
# qemu-user-static, so nothing in the image is executed here.
#
#   sudo ./make-headless.sh --device /dev/sda \
#        --wifi Linksys17587_5GHz --wifi Linksys17587 --hostname opi6
#
# A bare --wifi NAME pulls the passphrase from this laptop's saved
# NetworkManager profile; use --wifi 'NAME=passphrase' to supply it directly.

set -euo pipefail

readonly PROG=${0##*/}

die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '    WARNING: %s\n' "$*" >&2; }

usage() {
	cat <<-EOF
		Usage: sudo $PROG --device /dev/sdX [options]

		  --device DEV        Disk holding the flashed rootfs (e.g. /dev/sda)
		  --wifi SPEC         SSID, or SSID=passphrase. Repeatable; first = highest
		                      priority. A bare SSID is looked up in this host's
		                      NetworkManager profiles.
		  --hostname NAME     Hostname to set (default: opi6)
		  --pubkey FILE       SSH public key to authorise
		                      (default: ~/.ssh/id_ed25519_opi6.pub of the sudo user)
		  --create-user NAME  Create this account (sudo-capable) if the image has
		                      no regular user. Repeatable.
		  --password SPEC     USER=passphrase. Repeatable. Any account created or
		                      reset without one gets a random passphrase, printed
		                      at the end.
		  --user NAME         Account to authorise. Repeatable.
		                      (default: root plus every UID >= 1000 in the image)
		  --country CC        Regulatory domain, e.g. KG. Required for 5 GHz:
		                      under the default regdomain 00 most 5 GHz channels
		                      are no-initiate and will never associate.
		  --wifi-driver NAME  Warn unless this kernel module is in the image
		                      (e.g. rtw89 for the RTL8852BE module)
		  --wifi-firmware P   Warn unless /lib/firmware/P exists in the image
		  --keep-host-keys    Do not clear the image's baked-in SSH host keys
		  --keep-passwords    Do not touch any existing password hash
	EOF
}

dev=
hostname=opi6
pubkey=
keep_host_keys=0
keep_passwords=0
country=
wifi_driver=
wifi_firmware=
declare -a wifi_specs=() users=() new_users=() password_specs=()

while (($#)); do
	case $1 in
	--device)
		dev=${2:?}
		shift 2
		;;
	--wifi)
		wifi_specs+=("${2:?}")
		shift 2
		;;
	--hostname)
		hostname=${2:?}
		shift 2
		;;
	--pubkey)
		pubkey=${2:?}
		shift 2
		;;
	--user)
		users+=("${2:?}")
		shift 2
		;;
	--create-user)
		new_users+=("${2:?}")
		shift 2
		;;
	--password)
		password_specs+=("${2:?}")
		shift 2
		;;
	--country)
		country=${2:?}
		shift 2
		;;
	--wifi-driver)
		wifi_driver=${2:?}
		shift 2
		;;
	--wifi-firmware)
		wifi_firmware=${2:?}
		shift 2
		;;
	--keep-passwords)
		keep_passwords=1
		shift
		;;
	--keep-host-keys)
		keep_host_keys=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown argument: $1" ;;
	esac
done

[[ -n $dev ]] || {
	usage >&2
	exit 2
}
((EUID == 0)) || die "must run as root (use sudo)"
[[ -b $dev ]] || die "$dev is not a block device"

if [[ -z $pubkey ]]; then
	invoking_home=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)
	pubkey=$invoking_home/.ssh/id_ed25519_opi6.pub
fi
[[ -r $pubkey ]] || die "cannot read public key: $pubkey"
pubkey_data=$(<"$pubkey")

# Resolve each WiFi spec to an SSID/passphrase pair up front, so a missing
# passphrase fails before the rootfs is touched.
declare -a ssids=() psks=()
for spec in "${wifi_specs[@]}"; do
	if [[ $spec == *=* ]]; then
		ssids+=("${spec%%=*}")
		psks+=("${spec#*=}")
	else
		psk=$(nmcli -s -g 802-11-wireless-security.psk connection show "$spec" 2>/dev/null || true)
		[[ -n $psk ]] || die "no saved passphrase for '$spec' on this host -- pass --wifi '$spec=<passphrase>'"
		ssids+=("$spec")
		psks+=("$psk")
	fi
done
((${#ssids[@]})) || warn "no --wifi given; the board will have no network unless it is wired"

root_name=$(lsblk -bnro NAME,FSTYPE,SIZE,TYPE "$dev" |
	awk '$4=="part" && $2=="ext4" {print $3, $1}' | sort -rn | head -1 | awk '{print $2}')
[[ -n $root_name ]] || die "no ext4 partition on $dev -- flash the image first"
root_part=/dev/$root_name

mnt=$(mktemp -d /tmp/opi6-root.XXXXXX)
cleanup() {
	# Flush before the enclosure is unplugged; a dirty USB-attached ext4 is the
	# classic cause of a board that never boots after prep.
	sync
	mountpoint -q "$mnt" && umount "$mnt"
	rmdir "$mnt" 2>/dev/null || true
}
trap cleanup EXIT

mount "$root_part" "$mnt"
[[ -f $mnt/etc/os-release ]] || die "$root_part does not look like a Linux rootfs"

info "Target rootfs"
note "device:  $root_part"
note "os:      $(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' "$mnt/etc/os-release")"
note "kernel:  $(find "$mnt/boot" -maxdepth 1 -name 'vmlinu*' -printf '%f\n' 2>/dev/null | head -1 || echo unknown)"

# ---------------------------------------------------------------- WiFi

info "WiFi"
if ((${#ssids[@]} == 0)); then
	note "skipped"
elif [[ -x $mnt/usr/sbin/NetworkManager ]]; then
	conn_dir=$mnt/etc/NetworkManager/system-connections
	mkdir -p "$conn_dir"
	for i in "${!ssids[@]}"; do
		ssid=${ssids[i]}
		# No interface-name: the board's wifi device may be wlan0 or a
		# predictable name like wlP1p1s0, and the profile must match either.
		prio=$((100 - i))
		file=$conn_dir/$ssid.nmconnection
		cat >"$file" <<-EOF
			[connection]
			id=$ssid
			uuid=$(cat /proc/sys/kernel/random/uuid)
			type=wifi
			autoconnect=true
			autoconnect-priority=$prio

			[wifi]
			mode=infrastructure
			ssid=$ssid

			[wifi-security]
			key-mgmt=wpa-psk
			psk=${psks[i]}

			[ipv4]
			method=auto

			[ipv6]
			method=auto
			addr-gen-mode=default
		EOF
		# NetworkManager silently ignores profiles that are group/world readable.
		chown 0:0 "$file"
		chmod 600 "$file"
		note "NetworkManager profile: $ssid (priority $prio)"
	done
elif [[ -x $mnt/usr/sbin/netplan || -x $mnt/usr/lib/systemd/system-generators/netplan ]]; then
	mkdir -p "$mnt/etc/netplan"
	file=$mnt/etc/netplan/90-headless-wifi.yaml
	{
		printf 'network:\n  version: 2\n  renderer: networkd\n  wifis:\n    wifi0:\n'
		printf '      match:\n        name: "wl*"\n'
		printf '      dhcp4: true\n      dhcp6: true\n      optional: true\n'
		[[ -n $country ]] && printf '      regulatory-domain: "%s"\n' "$country"
		printf '      access-points:\n'
		for i in "${!ssids[@]}"; do
			printf '        "%s":\n          password: "%s"\n' "${ssids[i]}" "${psks[i]}"
		done
	} >"$file"
	chown 0:0 "$file"
	chmod 600 "$file"
	note "netplan: $(basename "$file") (${#ssids[@]} network(s))"
elif [[ -x $mnt/usr/sbin/wpa_supplicant ]]; then
	mkdir -p "$mnt/etc/wpa_supplicant"
	conf=$mnt/etc/wpa_supplicant/wpa_supplicant-headless.conf
	{
		printf 'ctrl_interface=/run/wpa_supplicant\nupdate_config=1\n'
		# Without a country the card stays on regdomain 00, where most 5 GHz
		# channels are no-initiate: the AP is visible but never associable.
		[[ -n $country ]] && printf 'country=%s\n' "$country"
		printf '\n'
		for i in "${!ssids[@]}"; do
			printf 'network={\n\tssid="%s"\n\tpsk="%s"\n\tpriority=%d\n}\n\n' \
				"${ssids[i]}" "${psks[i]}" $((100 - i))
		done
	} >"$conf"
	chown 0:0 "$conf"
	chmod 600 "$conf"

	# The interface name is not knowable offline (wlan0 vs wlp1s0), so bind the
	# config to whatever the wireless device turns out to be called, at boot.
	mkdir -p "$mnt/usr/local/sbin"
	cat >"$mnt/usr/local/sbin/headless-wifi-bind" <<'SHIM'
#!/bin/sh
set -e
for w in /sys/class/net/*/wireless; do
	[ -e "$w" ] || continue
	iface=$(basename "$(dirname "$w")")
	install -m 600 /etc/wpa_supplicant/wpa_supplicant-headless.conf \
		"/etc/wpa_supplicant/wpa_supplicant-$iface.conf"
	systemctl enable --now "wpa_supplicant@$iface.service"
	exit 0
done
exit 0
SHIM
	chmod 755 "$mnt/usr/local/sbin/headless-wifi-bind"

	mkdir -p "$mnt/etc/systemd/system/multi-user.target.wants"
	cat >"$mnt/etc/systemd/system/headless-wifi.service" <<'UNIT'
[Unit]
Description=Bind headless WiFi config to the detected wireless interface
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/headless-wifi-bind

[Install]
WantedBy=multi-user.target
UNIT
	ln -sf /etc/systemd/system/headless-wifi.service \
		"$mnt/etc/systemd/system/multi-user.target.wants/headless-wifi.service"

	mkdir -p "$mnt/etc/systemd/network"
	cat >"$mnt/etc/systemd/network/25-headless-wifi.network" <<'NET'
[Match]
Name=wl*

[Network]
DHCP=yes

[DHCPv4]
# Higher metric than ethernet so a wired link wins when both are up.
RouteMetric=600
NET
	note "wpa_supplicant + networkd (interface resolved at boot)"
else
	warn "no recognised network stack in the image -- WiFi not configured"
fi

# cloud-init, when present, can reconfigure the network on first boot and undo
# the above; seed it with the same credentials rather than fighting it.
if [[ -d $mnt/etc/cloud ]] && ((${#ssids[@]})); then
	seed=$mnt/var/lib/cloud/seed/nocloud
	mkdir -p "$seed"
	printf 'instance-id: %s\nlocal-hostname: %s\n' "$hostname-001" "$hostname" >"$seed/meta-data"
	{
		printf 'version: 2\nwifis:\n  wifi0:\n    match:\n      name: "wl*"\n'
		printf '    dhcp4: true\n    optional: true\n    access-points:\n'
		for i in "${!ssids[@]}"; do
			printf '      "%s":\n        password: "%s"\n' "${ssids[i]}" "${psks[i]}"
		done
	} >"$seed/network-config"
	{
		printf '#cloud-config\nhostname: %s\nssh_pwauth: true\nssh_authorized_keys:\n  - %s\n' \
			"$hostname" "$pubkey_data"
	} >"$seed/user-data"
	chmod 600 "$seed/network-config" "$seed/user-data"
	note "cloud-init nocloud seed written"
fi

# ---------------------------------------------------------------- WiFi driver

info "WiFi driver and firmware"
kver=$(find "$mnt/lib/modules" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -1)
note "kernel modules: ${kver:-none found}"
if [[ -n $wifi_driver ]]; then
	if [[ -n $kver ]] && [[ -n $(find "$mnt/lib/modules/$kver" -name "${wifi_driver}*.ko*" -print -quit) ]]; then
		note "module $wifi_driver: present"
	else
		warn "module $wifi_driver NOT in the image -- WiFi will not come up"
	fi
fi
if [[ -n $wifi_firmware ]]; then
	if [[ -e $mnt/lib/firmware/$wifi_firmware ]]; then
		note "firmware $wifi_firmware: present"
	else
		warn "firmware /lib/firmware/$wifi_firmware MISSING -- WiFi will not come up"
	fi
fi

# ---------------------------------------------------------------- accounts

info "Accounts"

declare -A resolved_pw=()
for spec in "${password_specs[@]}"; do
	[[ $spec == *=* ]] || die "--password needs USER=passphrase, got: $spec"
	resolved_pw[${spec%%=*}]=${spec#*=}
done
declare -a generated=()

# No pipeline that exits early: SIGPIPE under `set -o pipefail` would abort.
random_pw() { openssl rand -base64 36 | tr -d '/+=\n' | cut -c1-24; }

set_password() {
	local u=$1 pw=$2 hash today
	hash=$(openssl passwd -6 "$pw")
	today=$(($(date +%s) / 86400))
	awk -F: -v OFS=: -v u="$u" -v h="$hash" -v t="$today" \
		'$1==u { $2=h; $3=t } 1' "$mnt/etc/shadow" >"$mnt/etc/shadow.new"
	chown --reference="$mnt/etc/shadow" "$mnt/etc/shadow.new"
	chmod --reference="$mnt/etc/shadow" "$mnt/etc/shadow.new"
	mv "$mnt/etc/shadow.new" "$mnt/etc/shadow"
}

add_to_group() {
	local g=$1 u=$2
	grep -qE "^${g}:" "$mnt/etc/group" || return 0
	awk -F: -v OFS=: -v g="$g" -v u="$u" \
		'$1==g { n=$4; if (n=="") n=u; else if (n !~ "(^|,)" u "($|,)") n=n "," u; $4=n } 1' \
		"$mnt/etc/group" >"$mnt/etc/group.new"
	chown --reference="$mnt/etc/group" "$mnt/etc/group.new"
	chmod --reference="$mnt/etc/group" "$mnt/etc/group.new"
	mv "$mnt/etc/group.new" "$mnt/etc/group"
}

create_user() {
	local u=$1 pw=$2 uid gid hash today g
	if grep -qE "^${u}:" "$mnt/etc/passwd"; then
		note "$u already exists -- not recreating"
		return 0
	fi
	uid=1000
	while awk -F: -v i="$uid" '$3==i {f=1} END{exit !f}' "$mnt/etc/passwd"; do uid=$((uid + 1)); done
	gid=$uid
	while awk -F: -v i="$gid" '$3==i {f=1} END{exit !f}' "$mnt/etc/group"; do gid=$((gid + 1)); done

	printf '%s:x:%d:%d:,,,:/home/%s:/bin/bash\n' "$u" "$uid" "$gid" "$u" >>"$mnt/etc/passwd"
	printf '%s:x:%d:\n' "$u" "$gid" >>"$mnt/etc/group"
	hash=$(openssl passwd -6 "$pw")
	today=$(($(date +%s) / 86400))
	printf '%s:%s:%d:0:99999:7:::\n' "$u" "$hash" "$today" >>"$mnt/etc/shadow"
	[[ -f $mnt/etc/gshadow ]] && printf '%s:!::\n' "$u" >>"$mnt/etc/gshadow"

	mkdir -p "$mnt/home/$u"
	[[ -d $mnt/etc/skel ]] && cp -aT "$mnt/etc/skel" "$mnt/home/$u"
	chown -R "$uid:$gid" "$mnt/home/$u"
	chmod 750 "$mnt/home/$u"

	for g in sudo adm dialout cdrom floppy audio dip video plugdev games users netdev render input ssh; do
		add_to_group "$g" "$u"
	done
	# Without a %sudo rule in sudoers, group membership alone grants nothing.
	if ! grep -qE '^[[:space:]]*%sudo' "$mnt/etc/sudoers" 2>/dev/null; then
		mkdir -p "$mnt/etc/sudoers.d"
		printf '%s ALL=(ALL:ALL) ALL\n' "$u" >"$mnt/etc/sudoers.d/90-$u"
		chmod 440 "$mnt/etc/sudoers.d/90-$u"
		note "granted sudo via /etc/sudoers.d/90-$u"
	fi
	note "created $u (uid $uid, gid $gid)"
}

for u in "${new_users[@]}"; do
	pw=${resolved_pw[$u]:-}
	if [[ -z $pw ]]; then
		pw=$(random_pw)
		generated+=("$u:$pw")
	fi
	create_user "$u" "$pw"
done

# Armbian ships root with a published default passphrase. Password auth stays
# enabled below as a recovery path, so that default must not reach the LAN.
if ((!keep_passwords)) && grep -qE '^root:' "$mnt/etc/shadow"; then
	pw=${resolved_pw[root]:-}
	if [[ -z $pw ]]; then
		pw=$(random_pw)
		generated+=("root:$pw")
	fi
	set_password root "$pw"
	note "root password reset"
fi

# ---------------------------------------------------------------- SSH keys

info "SSH authorised keys"
if ((${#users[@]} == 0)); then
	mapfile -t users < <(awk -F: '$3==0 || ($3>=1000 && $3<65534) {print $1}' "$mnt/etc/passwd")
fi

for u in "${users[@]}"; do
	entry=$(grep -E "^${u}:" "$mnt/etc/passwd" || true)
	[[ -n $entry ]] || {
		warn "no such user in image: $u"
		continue
	}
	uid=$(cut -d: -f3 <<<"$entry")
	gid=$(cut -d: -f4 <<<"$entry")
	home=$(cut -d: -f6 <<<"$entry")
	ssh_dir=$mnt$home/.ssh
	mkdir -p "$ssh_dir"
	touch "$ssh_dir/authorized_keys"
	grep -qxF "$pubkey_data" "$ssh_dir/authorized_keys" ||
		printf '%s\n' "$pubkey_data" >>"$ssh_dir/authorized_keys"
	chown -R "$uid:$gid" "$mnt$home/.ssh"
	chmod 700 "$ssh_dir"
	chmod 600 "$ssh_dir/authorized_keys"
	note "$u ($home)"
done

# ---------------------------------------------------------------- sshd

info "sshd"
[[ -x $mnt/usr/sbin/sshd ]] || warn "no sshd in the image -- SSH will not work until it is installed"

enabled=0
for unit in ssh.service sshd.service; do
	for d in lib/systemd/system usr/lib/systemd/system etc/systemd/system; do
		if [[ -f $mnt/$d/$unit ]]; then
			mkdir -p "$mnt/etc/systemd/system/multi-user.target.wants"
			ln -sf "/$d/$unit" "$mnt/etc/systemd/system/multi-user.target.wants/$unit"
			note "enabled $unit"
			enabled=1
			break 2
		fi
	done
done
((enabled)) || warn "no ssh unit found -- cannot pre-enable the service"

drop_in=$mnt/etc/ssh/sshd_config.d
if [[ -d $drop_in ]]; then
	# Password auth stays on deliberately: with no monitor attached, a key that
	# turns out not to work would otherwise mean an unreachable board.
	cat >"$drop_in/10-headless.conf" <<-'EOF'
		PubkeyAuthentication yes
		PasswordAuthentication yes
	EOF
	chmod 644 "$drop_in/10-headless.conf"
	note "drop-in 10-headless.conf (password auth left ON as a lockout escape hatch)"
else
	warn "no sshd_config.d -- check sshd_config by hand for PubkeyAuthentication"
fi

if ((!keep_host_keys)) && compgen -G "$mnt/etc/ssh/ssh_host_*" >/dev/null; then
	# Baked-in host keys are shared by every board flashed from this image.
	# Only safe to clear if something regenerates them at boot.
	regen=0
	for u in ssh-keygen.service sshd-keygen.service regenerate_ssh_host_keys.service armbian-firstrun.service; do
		for d in lib/systemd/system usr/lib/systemd/system etc/systemd/system; do
			[[ -f $mnt/$d/$u ]] && {
				regen=1
				break 2
			}
		done
	done
	if ((regen)); then
		rm -f "$mnt"/etc/ssh/ssh_host_*
		note "cleared baked-in host keys (image regenerates them on first boot)"
	else
		warn "image has baked-in host keys but no regeneration unit -- keeping them"
	fi
fi

# ---------------------------------------------------------------- first-boot blockers

info "First-boot blockers"

# Armbian-derived images run an interactive wizard on first login while this
# file exists, which blocks a headless SSH session.
if [[ -f $mnt/root/.not_logged_in_yet ]]; then
	rm -f "$mnt/root/.not_logged_in_yet"
	note "removed /root/.not_logged_in_yet (skips interactive first-run wizard)"
fi

# A last-change field of 0 in shadow forces a password change at login, which
# an SSH key cannot satisfy.
if [[ -f $mnt/etc/shadow ]] && awk -F: '$3=="0"' "$mnt/etc/shadow" | grep -q .; then
	forced=$(awk -F: '$3=="0" {printf "%s ", $1}' "$mnt/etc/shadow")
	today=$(($(date +%s) / 86400))
	awk -F: -v OFS=: -v t="$today" '$3=="0" {$3=t} 1' "$mnt/etc/shadow" >"$mnt/etc/shadow.new"
	chown --reference="$mnt/etc/shadow" "$mnt/etc/shadow.new"
	chmod --reference="$mnt/etc/shadow" "$mnt/etc/shadow.new"
	mv "$mnt/etc/shadow.new" "$mnt/etc/shadow"
	note "cleared forced password change for: $forced"
else
	note "no forced password changes"
fi

# ---------------------------------------------------------------- identity

info "Hostname"
printf '%s\n' "$hostname" >"$mnt/etc/hostname"
if [[ -f $mnt/etc/hosts ]]; then
	if grep -qE '^127\.0\.1\.1' "$mnt/etc/hosts"; then
		sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$hostname/" "$mnt/etc/hosts"
	else
		printf '127.0.1.1\t%s\n' "$hostname" >>"$mnt/etc/hosts"
	fi
fi
note "$hostname"

if [[ -x $mnt/usr/sbin/avahi-daemon ]]; then
	note "avahi present -- $hostname.local should resolve once it is up"
else
	warn "no avahi-daemon in the image -- find the board by IP (check the router's DHCP leases)"
fi

if ((${#generated[@]})); then
	info "Generated passphrases -- record these now, they are stored nowhere else"
	for entry in "${generated[@]}"; do
		printf '    %-14s %s\n' "${entry%%:*}" "${entry#*:}"
	done
fi

info "Done -- safe to unmount and move the SSD to the board"
