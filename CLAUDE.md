# CLAUDE.md

This is the **only** file in this repo written for an LLM. Everything else is for humans.

## Repo rules

- `README.md` and any doc you add is human-facing: short, scannable, tables over prose. Do not pad it, do not add agent instructions to it.
- Agent-facing context belongs here.
- **No secrets in this repo.** WiFi passphrase, account passwords and the SSH private key live outside it. Never commit them, never paste them into a doc.

## The board

`opi6` — Orange Pi 6 Plus, CIX P1 (CD8180, codename Sky1). UEFI/EDK2 in SPI flash, pure ACPI boot, root on NVMe. Reach it with `ssh opi6`; key auth only, `astavonin` has passwordless sudo, `root` by key works.

## Gotchas that have already cost time

- **No NetworkManager.** The Armbian minimal image ships an empty `/etc/NetworkManager/` directory but no binary. Writing `.nmconnection` files silently does nothing. Real stack: `systemd-networkd` + `wpa_supplicant@wlp1s0`. Detect network stacks by **binary**, never by directory.
- **Interface names are predictable, not `wlan0`.** WiFi is `wlp1s0`; Ethernet `enp97s0` and `enp49s0`, consecutive MACs.
- **Power.** 20 V PD, 65 W minimum. A 27 W supply lights the standby LED and nothing else — it never reaches PD negotiation for 20 V.
- **No fan control from the OS.** No ACPI fan object, no PWM chip, no EC, no i2c adapter. The only knob is BIOS → EC Fan Mode, already on Auto.
- **GPU/NPU/VPU have no drivers on `current-arm64`.** ACPI declares `\_SB.VPU0` (4 cores) and `\_SB.NPU0` (3 cores); nothing binds, and `/dev/video*` does not exist. `edge-cix-p1` adds `panthor` for the GPU but its config has `CONFIG_DRM_ACCEL is not set` and no Linlon codec driver — so NPU and hardware encode need the vendor BSP image.
- **`sudo` on the laptop is per-TTY.** Each Bash tool call authenticates separately; run multi-step root work inside a single invocation. `zenity` works as a `SUDO_ASKPASS` helper when there is no TTY.

## Changing the kernel or network config

The board is reachable **only over WiFi**. A failed boot or a broken network config means physical HDMI + keyboard recovery.

- Kernel swaps: use `grub-reboot` for a one-shot boot so failure reverts on the next power cycle, and have HDMI attached.
- Dropping an interface to test: arm a `systemd-run --on-active=<n>` restore first.
- sshd edits: `sshd -t` before restarting, every time.

## Scripts

`scripts/*.sh` run on the **laptop** against a USB-attached SSD, never on the board. They are shellcheck-clean — keep them that way. `make-headless.sh` writes into a mounted rootfs with no chroot, because there is no `qemu-user-static` for arm64 on the laptop.
