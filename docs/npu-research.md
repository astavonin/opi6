# NPU

Zhouyi V3, 1 cluster × 3 cores × 4 TECs, `/dev/aipu` behind an IOMMU. Measured 2026-11-24 on kernel `6.6.89-cix`.

Two stacks reach it, and they need different kernel drivers:

| Stack | Runs | Needs |
|---|---|---|
| **Vendor NOE** — `libnoe` + `.cix` graphs from CIX's Compass compiler | vision, audio, anything static-shape | stock KMD 5.11.0 (shipped) |
| **tinygrad `ZHOUYI`** — own kernels straight to `/dev/aipu` | the same, plus **LLMs** | KMD 6.2.0 + WBUF ([details](npu-llm.md)) |

Only one driver can be loaded at a time, and swapping breaks the other stack — the 5.11 UAPI declares `aipu_cap.asid_base[32]` where 6.x declares `[4]`, which changes the `QUERY_CAP` ioctl number, so a `libnoe` built against 5.11 fails its first call.

## Measured here

| What | Result |
|---|---|
| MobileNet v2 (hub `.cix`) via `NOE_Engine` | **1.7–2.7 ms**, ~500/s, five consecutive calls |
| openpilot supercombo, compiled by us | **73 ms** (13.7 Hz); `modeld` wants 20 Hz — see [npu-openpilot.md](npu-openpilot.md) |
| tinygrad elementwise + 8×8 matmul | correct, matmul error 0.0 — **only** on the 6.2.0 driver |
| Driver memory reservation | `rmmod aipu` frees **4.01 GB**; 5.11 carves 4 × 1 GiB ASID windows on a 16 GB board |

## What the hub offers

Precompiled `.cix` from ModelScope (`cix/ai_model_hub_25_Q3`, 26Q1 at `cix/ai_model_hub`) — the GitHub repo has only configs. Third-party latencies on this SoC: YOLOv8-L 44 ms, YOLOX-M 28 ms, **CLIP ViT-B/32 17 ms**, SCRFD+ArcFace 72 ms for 5 faces, SAM 2.1-tiny 1.4 s encode, Depth-Anything-V2 289 ms, Real-ESRGAN 12.6 s. Plus Whisper and Stable Diffusion 1.4.

Run one with `NOE_Engine`; `numpy` is not installed system-wide, so use a venv and point `PYTHONPATH` at `/usr/local/lib/python3.12/dist-packages`:

```python
from NOE_Engine import EngineInfer
m = EngineInfer("mobilenet_v2.cix")
m.forward(np.random.rand(1, 3, 224, 224).astype(np.float32))
```

## Compiling your own

Works, with caveats: [npu-compass-toolchain.md](npu-compass-toolchain.md). Static shapes only — dynamic shapes and a growing KV cache don't compile, which is why LLMs need the other stack.

## Versions and traps

On the image: `cix-npu-driver` 1.0.0+2503 (KMD 5.11.0, source in `/usr/src/aipu-5.11.0`), `cix-noe-umd` 2.0.4, `cix-npu-onnxruntime` 1.1.0. **No CIX or Radxa apt repo is configured**, so `apt` will not update these. Newer packages are public at [radxa-pkg/cix-prebuilt 26Q2-2607](https://github.com/radxa-pkg/cix-prebuilt/releases/tag/26Q2-2607).

- Never upgrade the KMD alone — see the ABI note above. Keep the vendor `.deb` to restore the `NOE_Engine` baseline.
- `onnxruntime_zhouyi` is a **cp311** wheel; the board runs Python 3.12, so the ORT execution-provider route needs a 3.11 venv. `libnoe` has cp310–313 builds, so `NOE_Engine` is fine.
- 1 GiB per ASID is driver policy, not silicon (`aipu_mm.c` → `aipu_mm_add_iova_region()`); the hardware limit is 32 bits of address per ASID.

Working tree on the board: `~/zhouyi/` — `venv/`, `tinygrad-npu-examples/`, `sky1-zhouyi-v3-driver/`, `sdk-26q2/`, `models/`, `backup/`.
