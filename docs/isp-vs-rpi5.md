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
| **The daemon cannot be removed** | with `isp-daemon` stopped: 0 OK / 3 FAIL, 33 s hangs |
| **The daemon cannot own the stream either** | `isp_app -f` with `start` keeps the camera up, but then GStreamer gets EBUSY in 220 ms: 1 OK / 5 FAIL |
| **Only one camera is active** | the unit runs `isp_app -s 0`; `/dev/video7`, `/dev/video8` deliver no frames |
| **Capture usually fails** | 3 of 10 MIPI runs succeeded in a measured pass, against 10 of 10 on USB on the same board. Failures hang rather than error, and one run rebooted the board. The mechanism is not established |
| **Half the daemon's interface is undocumented** | `isp_app -h` lists five options; the binary's getopt string is `hgtf:m:s:dp:nc` — ten. The `-s` the unit passes is valid and functional (`Set singleCamIdx 0`), just absent from the help |
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

The media graph then closes the door. The board boots **ACPI, not device tree** (`acpi=force`, no `/proc/device-tree`, DSDT signed `CIXTEK SKY1EDK2`) — so the DTB sitting on the ESP describes a file, not this machine. The evidence that matters is on the running system and in the driver source:

| Needed to attach a mainline sensor | Reality |
|---|---|
| A real sensor `compatible` | ❌ the driver's `of_match_table` holds one generic entry, `{ .compatible = "image,sensor0" }`. Live binding is by ACPI HID (`armcb,isp` ← `CIXH3021:00`). Mainline binds on `sony,imx477` |
| A media graph to attach to | ❌ **`media_create_pad_link` appears zero times** in the whole GPL driver, against eight other media calls |
| …and on the board | ❌ all three ISP media devices: **13 entities, every one `(0 pad, 0 link)`**. Pi 5 with the same tool: **44 entities, 44 links, none unlinked** |
| Sensor subdev with real ops | ❌ all three `v4l2_subdev_ops` fill only `.core`; the sensor ioctl handles one command and returns `-ENOIOCTLCMD` for everything else |
| Standalone CSI capture, no ISP | ❌ not implemented |

Sensor identity never comes from firmware at all. It crosses from userspace as a `char sName[32]` the driver merely logs, with register writes passed through as opaque bytes to `i2c_master_send` under the driver's own comment `/// already sort in userspace`. **Zero sensor model names appear in the 584 KB GPL tree**; the three (`ov13850/55/58`) live in the closed binary.

The irony: `ov13858.c` **is** in mainline and sits unused, and this kernel also ships unused `imx219`, `imx412`, `ov5640` and `ov5645` drivers. The sensor drivers exist. Nothing can reach them.

So a bypass is not configuration, it is kernel work: write the endpoint graph, enable the CSI receivers, add a standalone capture path, then run a software ISP with no tuning data and poor image quality for the trouble.

**The OV13850 we have is already one of the three supported parts and probes successfully** (`Probe Success, chipId = 0xd8`). Swapping sensors changes nothing.

## Practical guidance

- **If it must not fail, use a USB camera.** It bypasses the entire vendor ISP.
- **On MIPI, retry.** A measured pass got 3 of 10; budget for repeats rather than a fixed rate.
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
