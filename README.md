# opi6 — Orange Pi 6 Plus

Headless ARM64 dev box for video streaming and GPU/NPU experiments. CIX P1 SoC, MIPI-CSI camera, 1 TB NVMe.

## Reach it

```
ssh opi6         # 192.168.10.130, DHCP reservation on the WiFi MAC
ssh opi6-mdns    # opi6.local, fallback
```

Key: `~/.ssh/id_ed25519_opi6`. Password login is **off** — that key is the only remote way in. Lose it and you need HDMI + keyboard. `astavonin` has passwordless sudo.

## Hardware

| | |
|---|---|
| SoC | CIX P1 / CD8180 (codename Sky1) |
| CPU | 4× A720 @ 2.6 GHz + 4× A720 @ 2.4 GHz + 4× A520 @ 1.8 GHz |
| GPU | Immortalis-G720 MC10 (10 cores) |
| NPU | Zhouyi V3 — 3 cores × 4 TECs, 30 TOPS |
| VPU | Linlon V8 (`amvx`) — separate encode and decode engines. Encode `/dev/video1`, decode `/dev/video0`; four hardware session slots |
| Camera | 13 MP MIPI-CSI via Orange Pi CAM adapter (module sold for OPi 5/RK3588; works here) |
| Disk | Samsung 980 1 TB NVMe |
| WiFi | RTL8852BE → `wlp1s0` |
| Ethernet | 2× → `enp97s0`, `enp49s0` |
| Power | USB-C PD **20 V, 65 W min, 100 W recommended** |

Draw: 13.7 W idle · 26.7 W load · 41.4 W peak — published figures for the Orange Pi 6 (same SoC), not measured on this board. A Raspberry Pi 5 supply will not start it.

## OS

Orange Pi vendor image 1.0.2 (Ubuntu 24.04 Noble), kernel **6.6.89-cix**, root on NVMe. Network is **NetworkManager** (`nmcli`); `systemd-networkd` is inactive.

The vendor BSP is the only stack that drives the MIPI camera, NPU and VPU. Armbian and mainline have no ISP, no Zhouyi and no Linlon codec driver — GPU only, and even that needs device-tree boot.

It replaced an Armbian install, which used `systemd-networkd` + `wpa_supplicant` and had none of the accelerators. Check `uname -r` before trusting any note that predates the swap.

## Verified working

| | |
|---|---|
| GPU | Vulkan 1.3.296 `Mali-G720-Immortalis`, OpenGL ES, 5 render nodes |
| NPU | `zhouyi-v3`, KMD v5.11.0, `/dev/aipu` opens, `libnoe` + Python bindings |
| Camera capture | `/dev/video9` only — NM12, 1920×1080 / 1280×720 / 640×480 @ 30 fps |
| Raw capture to disk | 720p, exact byte count |
| HW encode (synthetic) | H.264 + H.265 at 1080p from `videotestsrc` |
| HW encode (MIPI camera) | 720p **and** 1080p, H.264 and H.265 — but it panics the kernel, see below |
| HW encode (USB camera) | 720p and 1080p, H.264 and H.265 — reliable |
| File → HW encode | H.265, verified with `ffprobe` |
| Parallel HW encode | **18 × 1080p30 sustained** on one engine, ~0.11 CPU cores per stream. Ceiling is ~537 fps at 1080p |
| Zero-copy encode input | `output-io-mode=dmabuf-import` from a USB camera |

### MIPI capture panics the kernel

It does not merely fail unreliably. Measured 2026-11-10: **4 of 10** MIPI capture runs reset the board, against **10 of 10** clean USB runs — six resets in one session. An earlier sitting recorded 3 of 10 succeeding, the rest hanging or resetting.

The panic is identical across five traced occurrences:

```
Unable to handle kernel paging request, ESR = 0x96000004   (level 0 translation fault)
pc : mutex_lock_interruptible+0x10/0x6c
lr : __video_do_ioctl+0xe0/0x3c8
Comm: v4l2src0:src          armcb_isp_v4l2(O) loaded, kernel tainted O
```

Call path is `mutex_lock_interruptible` ← `video_usercopy` ← `video_ioctl2` ← `v4l2_ioctl` ← `__arm64_sys_ioctl`, and the faulting thread is GStreamer's own capture thread. **The mutex pointer holds garbage** — in one panic `0x494e495f43455355`, which is the ASCII `USEC_INI` little-endian; another held an unrelated value, so the contents vary between runs. The last driver lines before every fault are `armcb_g_param` entering, then `armcb_v4l2_g_selection` logging `target = 257, type = 1`.

**It happens with `isp-daemon` stopped as well as running**, so it is a driver bug rather than daemon contention — which also refutes the idea that the daemon is the only route to the sensor.

*Unproven reading, recorded as a lead:* `armcb_v4l2_core.c` assigns and clears `vdev->queue` directly around the streaming entry points without serialising against in-flight ioctls, which would let an ioctl dereference `vdev->queue->lock` after the backing `vb2_queue` was freed and its memory reused. The source shows the unserialised assignments and the trace shows a garbage lock pointer; nothing measured connects the two. `armcb_v4l2_g_selection` carries the vendor's own `/* need fix: hard code for NV12M 1080p fmt */` comment.

This supersedes the earlier `FAKE SLEEP: sleepTimeUs = 5000000` lead, which was never reproducible.

`/sys/fs/pstore/` stays empty after every panic even though `ramoops` is registered, so these traces survive only because journald was given a persistent store (see Guards). Under the vendor default all of it is lost on reset.

`isp-daemon` runs `isp_app -s 0`. **`-s` is undocumented but valid** — the binary's getopt string is `hgtf:m:s:dp:nc`, `-s` takes an argument, and the daemon logs `Set singleCamIdx 0`. Five of its ten options are missing from `-h`.

**Bypass: retry**, and expect a poor hit rate.

Do **not** loop `systemctl restart isp-daemon` — that rebooted the board twice.

For anything that must not fail, use the **USB camera** — `uvcvideo` never touches the ISP and was 100 % reliable.

Full architecture comparison against a Raspberry Pi 5, and the alternatives we ruled out: [docs/isp-vs-rpi5.md](docs/isp-vs-rpi5.md).

How many streams the VPU encodes at once, why decode serialises, and the measurements behind both: [docs/parallel-encoding-research.md](docs/parallel-encoding-research.md).

#### The sensor is not the cause

`journalctl -u isp-daemon` shows `Probe failure` lines, but they are the ISP walking its candidate list and probing the empty second CSI slot (`sensorId = 2`). The line that matters comes after:

```
Hw_Env_Sensor_Probe(581): Probe Success, sensorId = 0, chipId = 0xd8
```

`isp_app` contains `ov13850`, `ov13855` and `ov13858`. Our module (sold for OPi 5 / RK3588) is recognised. Swapping it for an OV13855 would change nothing — zero sensor model names appear anywhere in the 584 KB GPL driver tree, so sensor handling is entirely inside the closed binary either way.

### The pipeline that works

`colorimetry=bt709` is mandatory. GStreamer defaults to guessing `bt601`, which the driver rejects outright.

MIPI camera — 720p and 1080p both work:

```
gst-launch-1.0 -e v4l2src device=/dev/video9 num-buffers=60 \
  ! video/x-raw,format=NV12,width=1920,height=1080,framerate=30/1 \
  ! videoconvert \
  ! video/x-raw,colorimetry=bt709 \
  ! v4l2h265enc ! h265parse ! matroskamux ! filesink location=out.mkv
```

USB camera — works at 1080p too, and avoids the ISP entirely:

```
gst-launch-1.0 -e v4l2src device=/dev/video3 num-buffers=60 \
  ! image/jpeg,width=1920,height=1080,framerate=30/1 \
  ! jpegdec ! videoconvert \
  ! video/x-raw,format=NV12,colorimetry=bt709 \
  ! v4l2h264enc ! h264parse ! matroskamux ! filesink location=out.mkv
```

## What does not work

| Thing | Symptom |
|---|---|
| MIPI encode, most runs | **panics the kernel** in `armcb_isp_v4l2` — 4/10 runs reset the board, 10/10 clean on USB. Not resolution- or codec-specific |
| `output-io-mode=dmabuf` **from MIPI** | hangs every time. Not an encoder limit — fed from a USB camera the encoder imports dmabuf fine, with `output-io-mode=dmabuf-import` |
| `/dev/video7`, `/dev/video8` | no frames — **expected**: `isp-daemon` runs `isp_app -s 0` (single sensor). `-m 2` is said to enable both CSI ports; **untested here**, and `-m` is one of the five options `-h` does not document |
| **ffmpeg** camera capture | `Not a video capture device` — its v4l2 demuxer cannot open multiplanar nodes |
| `videoparse` on camera buffers | SIGSEGV (treats non-contiguous NM12 planes as packed) |
| Default colorimetry | driver rejects `bt601`; must force `bt709` |
| Concurrent HW decode | only one decode session at a time, and an encode starting beside it wedges the decode permanently. Encode has no such limit |
| `output-io-mode=dmabuf` (enum 4) | silently falls back to mmap instead of erroring, so a dmabuf pipeline can "pass" while proving nothing. Use `dmabuf-import` (enum 5) |
| Fan control from Linux | no ACPI fan object, no PWM, no EC. BIOS is on Auto Mode, idles ~40 % |

### Crashes

The vendor v4l2 layer is fragile **by design, not because of our setup**. Someone running the officially-supported OV13855 on this board reports the same: *"Once you issue a wrong command, the kernel may crash"*, *"MIPI Cameras are capped at 1920x1080"*, *"Using NPU and VPU (H265) triggers some decoding errors"*, and MIPI capture crashing the ISP after 15 min of sustained load ([avafinger/orangepi-6-plus-experiments](https://github.com/avafinger/orangepi-6-plus-experiments)).

These took the board down hard, needing a power cycle:

- `systemctl restart isp-daemon` repeatedly in a loop
- two pipelines holding `/dev/video9` at once
- `v4l2-ctl --all` against ISP nodes (reported by others; not retried here)

SSH also dropped mid-test several times without the board going down — check reachability before assuming a crash.

Test one pipeline at a time and check the board is still reachable between runs. `kill -9` on a GStreamer pipeline leaves the device in a state where even known-good pipelines fail until `isp-daemon` is restarted or the board reboots.

A hard crash once left the filesystem overrunning its partition, which caused an unbootable loop — see Recovery.

## Recovery

If it boot-loops (EDK2 → GRUB → reset), pull the SSD and check the partition contains the filesystem:

```
sudo parted -s /dev/sdX unit s print        # partition size
sudo dumpe2fs -h /dev/sdX2 | grep 'Block count'   # × 8 = sectors
sudo parted -s -a none /dev/sdX resizepart 2 100%
sudo e2fsck -fy /dev/sdX2
```

### Guards

`scripts/make-headless.sh` applies all of these at flash time, so a reflash does not quietly lose them:

| Guard | Without it |
|---|---|
| vendor resize service masked | it re-creates the root partition **smaller than the filesystem** — the unbootable loop above |
| `errors=remount-ro` on the rootfs | ext4 default is `Continue`: it runs on through corruption instead of failing safe |
| root in `fstab` with `passno=1` | no boot-time fsck runs at all — the vendor fstab has no root line |
| `fsck.repair=yes` on the kernel line | a dirty filesystem drops to an emergency shell, which on a headless board is a dead box |
| RAM-log disabled, persistent journal | crash logs are lost, which is exactly when you need them (see below) |

### Logs survive a crash

The vendor image mounts `/var/log` as a **50 MB tmpfs** (`orangepi-ramlog`) and rsyncs it to `/var/log.hdd` only from the service's `ExecStop` — no timer, no periodic flush. A clean shutdown keeps the logs; a hard hang loses everything since the last sync, which is precisely the case you need them for.

Setting `Storage=persistent` alone does nothing here: it points journald at a RAM filesystem recreated every boot. Worse, a `SystemMaxUse` larger than the tmpfs tells journald it has headroom it does not, and fills `/var/log`.

`orangepi-ramlog` is now disabled and masked, so `/var/log` is the NVMe. Verified by planting a marker, rebooting, and reading it back — `journalctl --list-boots` now shows boot `-1`.

`scripts/make-headless.sh` does this at flash time; `--keep-ramlog` opts out, which is only right when the target is an SD card.

## Scripts

Run on a laptop, against the SSD in a USB enclosure — not on the board. `--help` on each.

- `scripts/flash-image.sh` — wipe disk, write image, relocate the GPT backup header, grow the rootfs to fill it.
- `scripts/make-headless.sh` — everything needed for the board to come up headless and stay recoverable: WiFi, SSH key, user, hostname, and the five Guards above. Detects the image's network stack by **binary**, so it works on both the vendor image (NetworkManager) and Armbian (networkd + wpa_supplicant).

## BIOS

F2 or ESC at boot.

- Fan: Cix System Manager → Platform configuration → EC Fan Mode.
- `Restore AC Power Loss` is **Power Off** — a power cut leaves the board down until someone presses the button.
- `GRUB.CFG` on the ESP has commented-out **device-tree** entries; that is the boot mode mainline GPU work needs.
