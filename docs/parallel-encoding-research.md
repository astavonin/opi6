# Parallel hardware encoding and decoding on the Linlon V8

One VPU, several simultaneous sessions. This started as a list of open questions modelled on the Rockchip RK3588 pattern, and expected that pattern not to port; the questions have now been **measured on the board** (2026-11-11, vendor image, kernel `6.6.89-cix`). The pattern does port — the expectation was wrong — and the real finding is an asymmetry nobody predicted.

| | Result |
|---|---|
| **Parallel encode** | **Works, and scales well past the four hardware slots.** 18 concurrent 1080p30 H.264 streams sustained at rate; the engine saturates near 537 fps at 1080p |
| **Parallel decode** | **Does not work.** Exactly one decode session can be in flight, and it must be alone on the VPU |
| **Encode alongside decode** | **Breaks the decode.** Starting an encode while a decode streams wedges the decode permanently, in either start order |

**These are compression figures, not camera counts.** Every test fed the encoder from `videotestsrc` and the decoder from a file — no capture of any kind, no ISP node opened. See "What this does not measure" below before sizing a real pipeline.

Reproduce with `scripts/board/vpu-parallel.sh` (runs on the board, not the laptop).

## What was measured

1080p, 300 frames, `videotestsrc pattern=smpte` into `v4l2h264enc output-io-mode=mmap`; decode is the 300-frame 1080p HEVC file at `/opt/video_h265.mp4`.

### Encode scales to 18 streams at 1080p30

Source paced at a real 30 fps, so a session that cannot keep up shows as wall time exceeding the 10.0 s the 300 frames should take.

| Contexts | Wall time per session | Verdict |
|---|---|---|
| 8 | 10.12–10.18 s | at rate |
| 16 | 10.17–10.32 s | at rate |
| 18 | 10.18–10.35 s | **at rate — ~540 fps aggregate, the practical maximum** |
| 20 | 10.52–11.18 s | falling behind |
| 24 | 12.65–14.41 s | throughput-bound |

Run flat out instead of paced, the same engine gives:

| Contexts | Per session | Aggregate |
|---|---|---|
| 1 | 211 fps | 211 fps |
| 2 | ~190 fps | ~385 fps |
| 6 | ~84 fps | ~499 fps |
| 8 | ~65 fps | ~511 fps |
| 12 | ~45 fps | ~528 fps |
| 16 | ~34 fps | ~536 fps |

**The ceiling is pixel throughput, not context count: ~537 fps at 1080p, about 1.11 Gpixel/s.** Divide it by your resolution and frame rate to size a workload.

**The four LSIDs are not a session cap.** Contexts beyond four queue in the scheduler's `pending:` list and are time-sliced; 32 simultaneous contexts all completed. Scheduling is also notably even — at 16 contexts the spread was 33.4 to 35.2 fps.

### It is the hardware engine, not the CPU

Measured as the encoder's *marginal* cost, with the test source's own CPU subtracted:

| | 16 × 1080p30 | Per stream |
|---|---|---|
| `videotestsrc` → `fakesink`, no encode | 2.67 cores | — |
| same plus `v4l2h264enc` | 4.48 cores | **0.11 cores** |
| `openh264enc` software reference, 4 sessions, source subtracted | 1.46 cores | **0.37 cores** |

0.11 cores per stream is buffer handover, `h264parse` and file I/O — not encoding. The software encoder costs 3.4× more per stream, with near-static content that flatters it. Corroborating evidence: the vendor driver logged 139 `MVX session` messages during the run, 17 file descriptors were open on `/dev/video1`, and `amvx_dev0/sched` tracked LSID occupancy and queue depth against session count exactly. `v4l2h264enc` is a thin V4L2 M2M shim over the kernel device with no software fallback.

### Decode

| Case | Outcome |
|---|---|
| 1 decode | passes, ~300 fps |
| 2 decode | **one passes, one stalls** |
| 3 decode | **one passes, two stall** |
| 2 encode + 1 decode | **encodes pass, decode stalls** |
| decode started 1 s first, then 2 encode | **encodes pass, decode still stalls** |
| 2 decode staggered 3 s, and 3 decodes in sequence | all pass, ~300 fps each |

**Caveats on the numbers.** The desktop session was live, so the board was not quiet. `pattern=smpte` is close to static and compresses easily, and no bitrate target was set, so the flat-out figures are upper bounds rather than rates for real camera content — the paced 18-stream result is the more trustworthy one. The driver also rejected the requested frame period, logging `Invalid frame period from client (1/30). Return 60/1`, so the encoder itself never rate-limited anything. Beyond about 24 contexts the test harness becomes its own bottleneck, since each `videotestsrc` synthesises 1080p frames in software.

## What this does not measure: the input side

The encoder was fed synthesised frames from RAM. Nothing here touched a camera, an ISP node, or any capture path, which was deliberate — the ISP is where this board's kernel panic lives. So **18 streams is what the engine can compress, not how many cameras the board can run.** Getting frames in is the separate and much harder problem:

| Source | State on this board |
|---|---|
| MIPI | Panics the kernel in the vendor ISP driver. Capped at 1080p, and `isp_app -s 0` serves a single sensor; `-m 2` is said to enable both CSI ports but is untested |
| USB / UVC | Reliable where MIPI is not — 10 of 10 runs — but bandwidth-bound, and none was attached for these tests |
| Network in, then re-encode | Blocked by the decode serialisation above |

The shape that actually exploits 18-way encode is **one source fanned out to many encoders** — a `tee` into several `v4l2h264enc` at different resolutions and bitrates. That is an ABR ladder, or simultaneous record-and-stream, and it needs no additional capture bandwidth and no decode. Eighteen independent cameras is not on the table, and these numbers should not be read as saying it is.

### Zero-copy input works, but only off the ISP path

The long-standing note that `output-io-mode=dmabuf` "hangs every time" is **specific to the MIPI/ISP source**, not a property of the encoder. Fed from a USB camera, the encoder imports dmabuf fine.

The knob matters, and the wrong one fails silently:

| `output-io-mode` | What the allocator actually did |
|---|---|
| `dmabuf` (enum 4) | **silently fell back to mmap** on every pool — the pipeline completes and proves nothing |
| `dmabuf-import` (enum 5) | genuinely imported: `v4l2h264enc0:pool0:sink -> dmabuf`, pipeline clean |

Verify with `GST_DEBUG=v4l2allocator:5` and read the `allocated N <mode> buffers` lines. A dmabuf pipeline that merely exits 0 is not evidence; GStreamer downgrades without warning.

The 0.11 cores per stream measured above was an `mmap` path, so it already includes one copy per frame. The dmabuf-import path should come in under that; it has not been measured at scale.

### What a USB camera can and cannot feed

Tested with a Logitech C920 on this board. It is a **USB 2.0 device**, so it negotiates 480 Mbps whichever port it is plugged into — moving it to one of the board's 10 Gbps ports changes nothing.

| Path | Verdict |
|---|---|
| YUYV 640×480@30 straight into the encoder | Works, no conversion at all — the encode node accepts `YUYV` and `UYVY` on its OUTPUT queue |
| YUYV at 720p or 1080p | No 30 fps interval offered; USB 2.0 bandwidth is the limit |
| MJPEG 1080p30 | The only 1080p30 option, and it needs JPEG decode first — the broken side. Software `jpegdec` works and costs CPU |
| Camera's native H.264 (`uvch264src`) | Already encoded; nothing for the VPU to do |
| One camera → `tee` → 4 encoders | Works. Four identical outputs from a single 1080p30 MJPEG capture |

That last row is the shape worth building on: one capture fanned out to many encoders needs no extra capture bandwidth and never touches the decoder.

## The decode failure, precisely

The second decode context does not fail loudly. It negotiates caps, reaches streaming, emits two `Redistribute latency...` lines and then stops producing buffers. `dmesg` records nothing. The scheduler at `amvx_dev0/sched` shows the session holding a perfectly normal LSID with `Client session`, `Dev session` and `MVX session` pointers, and an empty `pending:` queue — the driver believes all is well.

Two details that matter for anyone testing this:

- **It is permanent, not starvation.** In the encode-plus-decode case the encoders finished at 1.6 s and the decode still had eighteen idle seconds of the engine to itself. It never recovered.
- **Order does not help.** Giving the decode a 1 s head start before the encoders start makes no difference, so this is not a race during session setup — a decode in mid-stream is killed by a session opening next to it.

The node is not left poisoned: decodes run back-to-back without trouble, and two decodes staggered far enough apart to not overlap both pass. One at a time, strictly serialised, is the usable pattern.

**Do not use `gst-launch -e` on a stalled decode.** `-e` forces EOS on interrupt, and a wedged decoder never delivers it, so SIGINT turns one hang into two. Plain SIGINT tears it down cleanly in about a second.

## The hardware, as the driver reports it

| | Value | Where |
|---|---|---|
| Encode node | `/dev/video1` — raw in; H.264, HEVC, VP8, VP9, JPEG, MJPEG out | `v4l2-ctl --list-formats-out` / `--list-formats` |
| Decode node | `/dev/video0` — compressed in, raw out; adds AV1, MPEG-2, MPEG-4, H.263, none of which encode | same |
| Hardware sessions | `hw_ncores = 4`, alongside `lsid0_regs` … `lsid3_regs`. Four slots, but **not a session cap** — extra contexts queue in `sched`'s `pending:` list | `/sys/module/amvx/parameters`, `/sys/kernel/debug/amvx_dev0` |
| Scheduler | `amvx_dev0/sched` — `Core LSID`, `Job queue`, and per-LSID session pointers | debugfs |
| Instrumentation | `amvx/log/group/` — `perf`, `session`, `dev`, `firmware_interface` — drained to `dmesg`, `ram0` or `ram1` | debugfs |
| Contention tunables | `wait_scheduler_timeout=1000`, `session_watchdog_timeout=100`, `wait_pending_timeout=3000`, `busctrl_split=2` | module params |
| Buffer budget | `cma=640M`, and not the limiter — 16 concurrent 1080p encodes moved `CmaFree` by under 3 MB | `/proc/cmdline`, `/proc/meminfo` |
| Kernel threads | two `kworker/R-mvx_s`, `SCHED_OTHER`, no RT priority | `ps -eLo pid,tid,cls,rtprio,comm` |
| GStreamer device property | `device` is **read-only** on `v4l2h264enc`, `v4l2h265enc` and `v4l2h265dec`; the defaults already point at the right nodes | `gst-inspect-1.0` |

`amvx_if0/session` is a directory, and it stays empty — the live-session evidence is in `sched`, not there.

## The RK3588 pattern ports; its mechanism does not

RK3588 runs up to twenty-one concurrent encode sessions on one core, multiplexed below userspace. That is exactly what this board does: 18 sessions sustained at 1080p30, 32 contexts opened without complaint, and scheduling even enough that sixteen sessions spread only 33.4 to 35.2 fps. **The concurrency model carries over whole** — the original expectation in this document, that it would not, was wrong. What differs is every mechanism underneath it, and in one place the Linlon arrangement is the simpler of the two.

| | RK3588 | Orange Pi 6 Plus | Ports? |
|---|---|---|---|
| Many sessions on one engine | up to 21 | 18 sustained at 1080p30, 32 contexts opened | **yes** |
| Who multiplexes | the kernel's `mpp_service`, dispatching queued jobs from `queue_work` kthreads | the driver's own scheduler at `amvx_dev0/sched`, below the V4L2 M2M job queue | **yes, in shape** |
| Fairness across sessions | even | even | **yes** |
| Userspace API | Rockchip MPP — `mpp_create()` + `mpp_init(MPP_CTX_ENC)` per session | **no library at all**: `open("/dev/video1")` once per stream | no — and simpler |
| A "session" is | an MPP context, one per stream | an open M2M file descriptor with its own queues, holding one of four LSIDs or queued in `pending:` behind them | no |
| Zero-copy input | import the capture buffer's dmabuf fd as `MPP_BUFFER_TYPE_DRM` | `output-io-mode=dmabuf-import`, verified working from a USB camera; the MIPI/ISP source is what hangs | **yes, off the ISP path** |
| Concurrent decode | independent per-context | **one at a time, and only with nothing else on the engine** | no |
| The priority-inversion fix | promote the dedicated feeder kthreads | no dedicated kthread exists to promote | no |
| Driver provenance | mainline | out-of-tree vendor BSP; no source in `/usr/src`, no kernel headers installed | no |

**There is no multiplexing layer to port, because there is nothing to write.** On RK3588 concurrency is a userspace concern: you link MPP and create a context per stream. Here the kernel does it — open the encode node once per stream and the driver assigns slots and queues the overflow. A single process can hold at least eight concurrent file descriptors on `/dev/video1`, so one-process-many-streams and many-processes work the same way.

The layers available above that, by how much control they give:

| Layer | Use it for |
|---|---|
| GStreamer `v4l2h264enc` / `v4l2h265enc` | One element per stream, `tee` to fan out. This is what the measurements above used |
| FFmpeg `h264_v4l2m2m` / `hevc_v4l2m2m` | The same from ffmpeg. These are encoders, not an hwaccel — `ffmpeg -hwaccels` does not list them |
| Raw V4L2 M2M plus `/usr/share/cix/include/mvx-v4l2-controls.h` | MPP-equivalent depth: `V4L2_CID_MVE_*` for GOP type, tiles, temporal MVP and bandwidth limit, plus the private `VIDIOC_S_MVX_QP_EPR` ioctl |
| `/usr/share/cix/bin/mvx_encoder`, `mvx_decoder` | Arm's reference applications, shipped in `cix-vpu-test`. Canonical ioctl-level usage; defaults to `--dev /dev/video1` |

There is **no VA-API** on this image (no driver, no `vainfo`), no OpenMAX and no `gst-omx`. V4L2 is the interface, not one option among several.

Rate control does not need the ioctl path. The driver advertises `video_bitrate`, `video_peak_bitrate`, `video_bitrate_mode`, `video_gop_size`, per-frame-type QP, intra-refresh and `force_key_frame`, and GStreamer reaches them through `extra-controls`:

```
v4l2h264enc extra-controls="controls,video_bitrate=4000000,video_gop_size=60"
```

Verify it takes effect before relying on it. The driver advertises a 500 kbps CBR default, yet the runs above emitted roughly 19 Mbps, so something in the GStreamer path is not applying rate control — the same class of problem as the frame-period override.

**The one idea that genuinely does not port is the fix, not the pattern.** The measured limiter on RK3588 was not encoder throughput but a priority inversion: the frame path ran `SCHED_FIFO` in userspace while the kernel threads *feeding* the encoder ran `SCHED_OTHER`, so real-time producers starved the threads they waited on and a queued job sat for 7–25 ms. Promoting those kernel threads above the real-time consumers fixed it for about 2% of a core. Here there is nothing to promote: the only `mvx` threads are two `kworker/R-mvx_s`, and the `R-` prefix makes them **rescuer** threads of a reclaim workqueue, idle unless the worker pool starves. The work runs on the shared kworker pool. If dispatch latency ever becomes the limiter, the lever is the driver's own scheduler and its timeouts, not thread priority.

## What is still open

| # | Question | Why it matters | How to settle it |
|---|---|---|---|
| 1 | Is the decode serialisation a driver bug or a firmware constraint? | Decides whether it is worth reporting upstream or designing around permanently | Compare against a second decode codec (VP9, AV1) and watch `log/group/session` with session logging raised |
| 2 | Does encode hold up on real camera input rather than `videotestsrc`? | `smpte` is near-static; real content is the actual workload | Repeat the 4-encode case against a USB camera, which captures 10 of 10 where MIPI panics |
| 3 | Does encode throughput hold on a quiet system, over repeated passes, with a real bitrate target? | Current figures are single runs with a live desktop and no rate control | Stop GNOME, pin the governor to `performance`, set a bitrate, repeat each case five times |
| 4 | What is the per-frame latency distribution, not just throughput? | A real-time pipeline cares about the tail, and time-slicing 18 contexts over four slots must cost queueing delay somewhere. `MVX dev: Waiting scheduler idle timeout.` appeared once under load | `log/group/perf` at 1, 4 and 18 sessions |
| 5 | Does the NPU interact with this? | A third-party report has NPU plus VPU triggering decode errors, and decode is already the fragile side | Run an `/dev/aipu` workload alongside the 4-encode case |

## What this means for a video node

**Multi-stream encode is real on this board, and generous.** Eighteen 1080p30 streams sustain at rate on one engine for about 0.11 CPU cores each, which leaves eleven of twelve cores free for everything else — with a 10-core GPU and a 30 TOPS NPU beside it on 20 V PD.

**The constraint has moved to the input side.** Encode is no longer the scarce resource; capture is. One reliable source fanned out to many encoders is well within budget, and that covers transcoding ladders and record-while-streaming. Many independent cameras is a capture problem this test says nothing about, and the ISP path it would depend on is the one that panics.

**Anything involving concurrent decode is not.** Replay-while-recording — the use case the separate encode and decode engines seemed to make obvious — is measurably broken: the decode dies the moment an encode joins it. Transcoding, multi-stream playback, and decode-plus-inference all inherit that limit. Until question 1 above is answered, treat decode as a strictly serialised, exclusive resource.

## Operational notes

- The board survived every run here, including the wedged ones, and never needed a power cycle. Every recorded hard hang on this board is on the ISP path, and this test opens no ISP node.
- Tear down with SIGINT. `kill -9` on a GStreamer pipeline leaves the device unusable until `isp-daemon` restarts or the board reboots.
- `kernel.panic` is `0` by default, so a panic hangs instead of rebooting. Setting `kernel.panic=10` at runtime is free and reversible, and is worth doing before any unattended run; the SBSA watchdog at `/dev/watchdog0` exists but nothing arms it.
