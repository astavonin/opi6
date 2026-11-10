# CLAUDE.md

This is the **only** file in this repo written for an LLM. Everything else is for humans.

## Repo rules

- `README.md` and any doc you add is human-facing: short, scannable, tables over prose. Do not pad it, do not add agent instructions to it.
- Agent-facing context belongs here.
- **No secrets in this repo.** WiFi passphrase, account passwords and the SSH private key live outside it. Never commit them, never paste them into a doc.

## The board

`opi6` — Orange Pi 6 Plus, CIX P1 (CD8180, codename Sky1). UEFI/EDK2 in SPI flash, pure ACPI boot, root on NVMe. Reach it with `ssh opi6`; key auth only, `astavonin` has passwordless sudo, `root` by key works.

**Running now: the Orange Pi vendor image — Ubuntu 24.04 Noble, kernel `6.6.89-cix`, NetworkManager.** It replaced an Armbian install in Nov 2026. Check before trusting any older note: `uname -r` and `. /etc/os-release`.

## Gotchas that have already cost time

- **Detect a network stack by its binary, never by a directory.** The Armbian image shipped an empty `/etc/NetworkManager/` with no binary, so `.nmconnection` files written there did nothing at all. The vendor image genuinely runs NetworkManager (`nmcli` present, service active, `systemd-networkd` inactive) — so the same directory check is right by accident now and wrong again after the next reflash. Test `-x /usr/sbin/NetworkManager`.
- **Interface names are predictable, not `wlan0`.** WiFi is `wlp1s0`; Ethernet `enp97s0` and `enp49s0`, consecutive MACs.
- **Power.** 20 V PD, 65 W minimum. A 27 W supply lights the standby LED and nothing else — it never reaches PD negotiation for 20 V.
- **No fan control from the OS.** No ACPI fan object, no PWM chip, no EC, no i2c adapter. The only knob is BIOS → EC Fan Mode, already on Auto.
- **GPU, NPU and VPU work on the vendor image, and only there.** `mali_kbase` loaded, `/dev/aipu`, `/dev/video0-9`. Mainline and Armbian have none of it: `current-arm64` binds nothing, and `edge-cix-p1` adds `panthor` for the GPU but sets `CONFIG_DRM_ACCEL is not set` and ships no Linlon codec driver.
- **MIPI capture is unreliable and the cause is unknown.** 3 of 10 runs in a measured pass, against 10 of 10 on a USB camera. Retry rather than concluding a pipeline is broken from one run. `colorimetry=bt709` is mandatory — the driver rejects GStreamer's `bt601` guess.
- **The vendor v4l2 layer crashes the board.** Two pipelines on one node, looping `systemctl restart isp-daemon`, and `v4l2-ctl --all` against an ISP node have each required a power cycle. One pipeline at a time, check reachability between runs.
- **`sudo` on the laptop is per-TTY.** Each Bash tool call authenticates separately; run multi-step root work inside a single invocation. `zenity` works as a `SUDO_ASKPASS` helper when there is no TTY.

## Changing the kernel or network config

The board is reachable **only over WiFi**. A failed boot or a broken network config means physical HDMI + keyboard recovery.

- Kernel swaps: use `grub-reboot` for a one-shot boot so failure reverts on the next power cycle, and have HDMI attached.
- Dropping an interface to test: arm a `systemd-run --on-active=<n>` restore first.
- sshd edits: `sshd -t` before restarting, every time.

## Scripts

`scripts/*.sh` run on the **laptop** against a USB-attached SSD, never on the board. They are shellcheck-clean — keep them that way. `make-headless.sh` writes into a mounted rootfs with no chroot, because there is no `qemu-user-static` for arm64 on the laptop.
