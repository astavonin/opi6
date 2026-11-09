# Camera stack: Orange Pi 6 Plus vs Raspberry Pi 5

Why MIPI capture is unreliable on the opi6 and rock solid on the rpi5. The difference is architectural, not a question of polish.

## The two designs

| | Raspberry Pi 5 | Orange Pi 6 Plus |
|---|---|---|
| Sensor driver | **in-tree kernel**: `imx477`, `imx708`, `dw9807_vcm` | none — sensor support is inside a proprietary blob |
| CSI front-end | `rp1_cfe` (mainline) | `armcb_isp_v4l2.ko` (out-of-tree) |
| ISP back-end | `pisp_be` (mainline) | proprietary, same module |
| 3A (exposure, white balance, focus) | **libcamera IPA — a library inside your process** | **`isp_app` — a system daemon that owns the hardware** |
| Owns `/dev/video*` | nothing | `isp_app`, permanently |
| Upstream status | mainline | out-of-tree; CIX is upstreaming only pinctrl/mailbox/PCIe |

On the Pi, your process opens the device and configures it through libcamera. Nothing else holds it, so nothing can take it away mid-capture.

On the opi6, a vendor daemon must be running for the ISP to work at all, and that daemon holds the capture node. Every capture is a negotiation with another process over the same hardware.

## What that costs us

| Issue | Evidence |
|---|---|
| **~40 % of MIPI captures fail** | `isp_app` runs the camera ~5 s then exits (`FAKE SLEEP: sleepTimeUs = 5000000` → `camera 0 stopped`); `Restart=always` loops it. A ~3.8 s capture only succeeds if it fits inside a window |
| **The daemon cannot be removed** | with `isp-daemon` stopped: 0 OK / 3 FAIL, 33 s hangs |
| **The daemon cannot own the stream either** | `isp_app -f` with `start` keeps the camera up, but then GStreamer gets EBUSY in 220 ms: 1 OK / 5 FAIL |
| **Only one camera is active** | the unit runs `isp_app -s 0`; `/dev/video7`, `/dev/video8` deliver no frames |
| **`-s` is not even a valid flag** | `isp_app` usage lists only `-h -g -f -d -p`. The service passes an option the binary does not accept, which is why it falls into the 5 s demo cycle |
| **Non-standard colorimetry** | driver reports `2:4:16:1` (BT601 matrix+transfer, BT709 primaries) — matches no GStreamer preset. `colorimetry=bt709` must be forced or negotiation fails |
| **Multiplanar-only capture** | format is `NM12`, Video Capture **Multiplanar**. `ffmpeg` cannot open it at all; `videoparse` SIGSEGVs on the non-contiguous planes |
| **Misuse crashes the board** | repeated ISP restarts, two pipelines on one node, and `v4l2-ctl --all` have each required a power cycle |

None of these exist on the rpi5, because none of the preconditions do.

## Alternatives, and why they fail

| Option | Result |
|---|---|
| Run without the daemon | **fails** — ISP never gets configured, 0/3 |
| `isp_app -f` + `start` (daemon streams) | **fails** — daemon owns the node, EBUSY, 1/6 |
| `isp_app -f` with `set:` only, no `start` | **untested** — the attempt crashed the board. The most promising remaining idea |
| libcamera | no CIX pipeline handler exists; the ISP driver is not upstream |
| **USB camera** | **works** — `uvcvideo`, single-planar, never touches the ISP. 100 % reliable at 720p and 1080p, both codecs |

## Can we just use Raspberry Pi cameras?

No — and only partly for the obvious reason.

`isp_app` knows exactly three sensors: **ov13850, ov13855, ov13858**. Pi cameras are **imx708** (Module 3) and **imx477** (HQ). No overlap, and the sensor tables are compiled into the closed binary, so the list cannot be extended. An IMX sensor on the CSI port would not be a flaky camera — it would be no camera.

The real question is whether we could bypass `isp_app` entirely: bind a mainline sensor driver, take raw Bayer off the CSI receiver, do the ISP work in software. The open kernel driver looks encouraging at first — `armcb_sensor.c` uses the standard `v4l2_async_nf` and `fwnode` binding that mainline sensor drivers rely on.

The device tree then closes the door:

| Needed to attach a mainline sensor | Reality |
|---|---|
| Driver speaks async/fwnode | ✅ it does |
| A real sensor `compatible` | ❌ `compatible = "image,sensor0"` — a generic placeholder. Mainline binds on `sony,imx477` |
| CSI receiver enabled | ❌ `csi@14280000` and siblings are `status = "disabled"` |
| `ports` / `endpoints` media graph | ❌ absent — nothing describes sensor↔receiver links |
| Standalone CSI capture, no ISP | ❌ not implemented by the driver |

Sensor identity never comes from the device tree at all; `isp_app` injects it at runtime through the private `ARMCB_VIDIOC_APPLY_CMD` ioctl. Our sensor sits at I²C `0x34`; Pi sensors sit at `0x1a`.

So a bypass is not configuration, it is kernel work: write the endpoint graph, enable the CSI receivers, add a standalone capture path, then run a software ISP with no tuning data and poor image quality for the trouble.

**The OV13850 we have is already one of the three supported parts and probes successfully** (`Probe Success, chipId = 0xd8`). Swapping sensors changes nothing.

## Practical guidance

- **If it must not fail, use a USB camera.** It bypasses the entire vendor ISP.
- **On MIPI, retry.** Each attempt is ~60 %; two attempts gets you to ~84 %.
- Do not loop `systemctl restart isp-daemon` — that rebooted the board twice.

## What is open and what is not

CIX released the kernel half and kept the brains:

| Open (GPL) | Closed |
|---|---|
| `armcb_isp_v4l2` kernel driver | `cix-isp-umd` → **`isp_app`** |
| ISP hardware register map (`armcb_isp_hw_reg.h`) | 3A: exposure, white balance, focus |
| V4L2 plumbing, videobuf2 | per-sensor register tables and tuning |

Source: [`orangepi-xunlong/component_cix-current`](https://github.com/orangepi-xunlong/component_cix-current) — `cix_opensource/isp/` versus `cix_proprietary/`.

The register map being public is unusual and means a libcamera pipeline handler is not blocked on reverse-engineering the silicon. But 3A plus sensor tuning is the expensive part, and it is precisely what vendors keep. No such handler exists: libcamera ships handlers for Raspberry Pi, Rockchip and C3, and is adding Arm's Mali-C55, but nothing for CIX or `armcb`.

## Why it will not improve soon

CIX is upstreaming basic SoC support only — pinctrl, mailbox, PCIe. The ISP driver stays out-of-tree, the 3A algorithms stay in a closed daemon, and no libcamera pipeline handler exists.

The Pi's camera stack works because every layer is mainline and the 3A library loads into your own process. If a usable open stack arrives here, it will most likely come from [Sky1-Linux](https://github.com/Sky1-Linux), who already carry the VPU and NPU drivers in-tree — not from anything we can do on this board.
