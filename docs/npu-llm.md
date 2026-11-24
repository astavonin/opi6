# LLMs on the NPU

They work, but only on a third-party kernel driver. The vendor stack cannot do it: Compass compiles static graphs, and autoregressive decode needs a growing KV cache.

The route is [Reonarudo/tinygrad-npu-examples](https://github.com/Reonarudo/tinygrad-npu-examples) — a tinygrad backend with hand-written GEMM kernels submitted as TCB-chain jobs, bypassing `libnoe` entirely.

## Getting it to run on this board

Every job timed out on the stock 5.11.0 driver — a one-task kernel over two floats included, exception vector 0, nothing in `dmesg`. Ruled out one at a time: a [known stale-command-pool race](https://github.com/n4hy/NPU_OrangePi6Plus), the 25Q3 toolchain, `ZHOUYI_TEXT_GM=0`, single core, no chain fusion, runtime PM forced on, and configuring the clusters with a vendor inference first. `ZHOUYI_HANG_ID=2` showed the task's start stamp still poison — the TEC never began executing.

The author's suspicion ([issue #1](https://github.com/Reonarudo/tinygrad-npu-examples/issues/1)) was our unaligned ASID0 base, `0x780000000`. Aligning it down to its 4 GiB floor — a one-line change to `aipu_mm_set_asid_base()`, whose multi-region path already does this — **did not help**. The 5.11 line is simply not a driver this backend runs on.

What works is **their driver**, [sky1-zhouyi-v3-driver](https://github.com/Reonarudo/sky1-zhouyi-v3-driver) (CIX 6.2.0-1 plus hardening and the zero-copy WBUF/SLOT ioctls), with one local patch:

> `sky1_npu_devfreq_init()` calls `dev_pm_domain_attach_by_name(dev, "perf")`, which returns NULL on 6.6 — probe aborts with `-EFAULT` and no `/dev/aipu` appears. DVFS is optional, so warn and continue instead of failing. The examples are measured at default clocks anyway.

With that, on `6.6.89-cix`:

```
aipu devfreq init failed (-14); continuing without DVFS
AIPU KMD (v6.2.0-1+zv3.1) probe start...
V3 IOVA domain: total 0x400000000 (4 ASIDs x 4GB slots, 3GB usable)
```

ASID bases become `0x0` — 4 GiB-aligned by construction — `zero_copy` reports `True`, and the backend runs: elementwise correct, 8×8 matmul error `0.0`.

**This costs the vendor stack.** `libnoe` 2.0.4 is built against the 5.11 UAPI and fails its first `QUERY_CAP` against a 6.x driver. Restore it with `apt remove cix-npu-driver-dkms`, then reload the stock module.

## What fits in 16 GB

Author's measurements on an Orion O6N (29 GB RAM), for orientation:

| Model | Decode tok/s | Resident | Here? |
|---|---|---|---|
| Gemma 4 E2B | 8.4 plain, **18–22** speculative | ~3 GB RAM, 2.4 GB packed | yes |
| Gemma 4 E4B | 4.3 → **11.0** | 5 GB packed | yes |
| Ternary Bonsai 2 2B / 4B / 9B | 10→57 / 6.9→16-24 / 4.5→9-14 | — | yes |
| Ring-mini-2.0 | **12.5** | 11 GB | tight |
| gpt-oss-20b, LFM2.5-24B, Qwen3.6-35B | 4.9 / 9.2 / 4.7 | 14.6–23.6 GB | no |
| Qwen3-30B-A3B | prefill **62.4** (CPU 31.3), decode 9.6 (CPU 17.4) | 26 GB | no |

The NPU wins on prefill and on leaving all 12 cores free, not on raw decode — its DDR port is narrower than what the CPU sees, so speculative decoding is what makes it pay. For comparison, llama.cpp on the CPU does 36 tok/s on a 1.5B Q4 with no driver surgery at all.

## Second route, untested

The vendor toolchain may be able to take a fixed-window decode graph. Its parser already covers a modern decoder's full op set (`GroupQueryAttentionMs`, `RotaryEmbeddingMs`, `SkipSimplifiedLayerNormalizationMs`, `MatMulNBitsMs`), and ONNX exports already pass KV as explicit tensors — Qwen3-0.6B's has 59 inputs and 57 outputs with no control flow. Fixing its four dynamic axes to constants would give a static decode graph. Appeal: no kernel changes, so the vendor stack survives. Caveat: a developer who tried the 26Q1 SDK reported no w4a16 GEMM kernel exists, so int4 may parse and then fail to build.
