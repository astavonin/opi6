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
| VPU | Linlon V8 (`amvx`) — separate encode and decode engines |
| Camera | 13 MP MIPI-CSI via Orange Pi CAM adapter (module sold for OPi 5/RK3588; works here) |
| Disk | Samsung 980 1 TB NVMe |
| WiFi | RTL8852BE → `wlp1s0` |
| Ethernet | 2× → `enp97s0`, `enp49s0` |
| Power | USB-C PD **20 V, 65 W min, 100 W recommended** |

Draw: 13.7 W idle · 26.7 W load · 41.4 W peak. A Raspberry Pi 5 supply will not start it.

## OS

Orange Pi vendor image 1.0.2 (Ubuntu 24.04 Noble), kernel **6.6.89-cix**, root on NVMe.

The vendor BSP is the only stack that drives the MIPI camera, NPU and VPU. Armbian and mainline have no ISP, no Zhouyi and no Linlon codec driver — GPU only, and even that needs device-tree boot.

## Verified working

| | |
|---|---|
| GPU | Vulkan 1.3.296 `Mali-G720-Immortalis`, OpenGL ES, 5 render nodes |
| NPU | `zhouyi-v3`, KMD v5.11.0, `/dev/aipu` opens, `libnoe` + Python bindings |
| Camera capture | `/dev/video9` only — NM12, 1920×1080 / 1280×720 / 640×480 @ 30 fps |
| Raw capture to disk | 720p, exact byte count |
| HW encode (synthetic) | H.264 + H.265 at 1080p from `videotestsrc` |
| HW encode (MIPI camera) | 720p **and** 1080p, H.264 and H.265 — ~60 % of runs, see below |
| HW encode (USB camera) | 720p and 1080p, H.264 and H.265 — reliable |
| File → HW encode | H.265, verified with `ffprobe` |

### MIPI captures race a 5-second window

`isp-daemon` runs `isp_app -s 0`, but **`-s` is not a valid flag** (usage: `-h -g -f -d -p`). With no valid instruction `isp_app` runs a default cycle — configure camera, `FAKE SLEEP: sleepTimeUs = 5000000`, `camera 0 stopped`, exit — and `Restart=always` loops it forever.

The camera is therefore up ~5 s, down ~1–2 s, continuously. A ~3.8 s capture succeeds only if it starts early enough in a window; otherwise the camera is torn down mid-stream and GStreamer waits for buffers that never arrive (~43 s timeout). That is the ~60 % success rate.

**Bypass: retry.** Each attempt is ~60 %; two gets you to ~84 %.

Do **not** loop `systemctl restart isp-daemon` — that rebooted the board twice.

For anything that must not fail, use the **USB camera** — `uvcvideo` never touches the ISP and was 100 % reliable.

Full architecture comparison against a Raspberry Pi 5, and the alternatives we ruled out: [docs/isp-vs-rpi5.md](docs/isp-vs-rpi5.md).

#### The sensor is not the cause

`journalctl -u isp-daemon` shows `Probe failure` lines, but they are the ISP walking its candidate list and probing the empty second CSI slot (`sensorId = 2`). The line that matters comes after:

```
Hw_Env_Sensor_Probe(581): Probe Success, sensorId = 0, chipId = 0xd8
```

`isp_app` contains `ov13850`, `ov13855` and `ov13858`. Our module (sold for OPi 5 / RK3588) is recognised. Swapping it for an OV13855 would not address the daemon-staleness fault.

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
| MIPI encode, ~40 % of runs | hangs when `isp_app` is stale. Not resolution- or codec-specific. Retry once |
| `output-io-mode=dmabuf` on the encoder | hangs every time here, despite appearing in the vendor's own documented pipeline |
| `/dev/video7`, `/dev/video8` | no frames — **expected**: `isp-daemon` runs `isp_app -s 0` (single sensor). Use `-m 2` for both CSI ports |
| **ffmpeg** camera capture | `Not a video capture device` — its v4l2 demuxer cannot open multiplanar nodes |
| `videoparse` on camera buffers | SIGSEGV (treats non-contiguous NM12 planes as packed) |
| Default colorimetry | driver rejects `bt601`; must force `bt709` |
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

Guards now in place on the board: `orangepi-resize-filesystem` masked, `errors=remount-ro`, `fsck.repair=yes`, root in `fstab` with `passno=1`, persistent journal.

## Scripts

Run on a laptop, against the SSD in a USB enclosure — not on the board. `--help` on each.

- `scripts/flash-image.sh` — wipe disk, write image, grow rootfs to fill it.
- `scripts/make-headless.sh` — inject WiFi, SSH key, user and hostname into the flashed rootfs.

## BIOS

F2 or ESC at boot.

- Fan: Cix System Manager → Platform configuration → EC Fan Mode.
- `Restore AC Power Loss` is **Power Off** — a power cut leaves the board down until someone presses the button.
- `GRUB.CFG` on the ESP has commented-out **device-tree** entries; that is the boot mode mainline GPU work needs.
