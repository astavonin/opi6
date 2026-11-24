# openpilot's driving model on the NPU

comma.ai's `supercombo` compiles for the Zhouyi and runs on this board at **73 ms per frame (13.7 Hz)**. `modeld` runs at `DT_MDL = 0.05`, so it wants **20 Hz / 50 ms** — this is 1.46× too slow as built.

```
Input tensor count is 7.   Output tensor count is 4.
outputs: [(2580,), (1966080,), (1056,), (65536,)]
latency ms: mean 72.98  min 63.94  max 82.41  p50 72.15
```

Output shapes are right: 2580 driving outputs plus the three state tensors. GBuilder estimates ~141 MB of DDR traffic per inference, about 6 ms at port speed, so the gap is launch and compute overhead rather than bandwidth — there is room to chase.

**Accuracy is unvalidated.** Calibration used synthetic noise, so the quantized weights are fitted to garbage statistics. The Optimizer's reported output cosine against the float reference was 0.984 / 1.0 / 1.0 / 0.999 *on that noise*, which says the pipeline is faithful, not that the model is. Real numbers need recorded route frames.

## Why it fits the NPU at all

The model has no internal recurrent state: it takes `state_img_q`, `state_desire_q`, `state_feat_q` and returns `next_state_*`, so the host carries the loop. That makes it a static graph with fixed shapes — 441 nodes, 26 distinct ops, 34.3 M FP16 params, zero control-flow subgraphs — and every one of its ops is covered by the Compass parser. It is, in short, the opposite of an LLM.

## The four transforms it needed

Scripts in `~/work/cix-sdk/op/` on the laptop. Each exists for a measured reason:

| Script | Why |
|---|---|
| `strip_allowzero.py` | the parser rejects opset-14 `allowzero` on Reshape, then cascades into 1050 shape-inference errors. Checked first that all 26 carrying nodes have constant zero-free shape operands, so dropping it is a no-op |
| `patch_mask.py` | one scalar fp16 `-inf` (feeding five `masked_fill` nodes) makes the Optimizer reject the IR; fp16's lowest finite value is identical after softmax |
| `add_batch_axis.py` | declares a leading batch axis of 1 on all seven inputs, plus a Reshape that drops it, so the model agrees with the Optimizer's DataLoader convention |
| `uint8_to_fp16_queue.py` | runs the image queue in FP16 and casts back at the uint8 output, so all slices share one dtype class — see the `clip` symbol bug in [npu-compass-toolchain.md](npu-compass-toolchain.md) |

Model files are LFS and **not** on GitHub — `.lfsconfig` points at HuggingFace. The fetch recipe is in `planning/npu/downloads.md`.

## What is not done

Only the model runs. The rest of openpilot is a different project:

- `camerad` is Qualcomm-specific, and our MIPI path panics the kernel anyway
- supercombo expects comma's camera intrinsics; another lens needs new `DEVICE_CAMERAS` entries and recalibration
- `dmonitoring_model.onnx` (201 nodes, 3.6 M params, same op set) is not compiled yet
- a road-going build is a regulatory question, not a porting one; panda enforces actuation limits regardless of host

The realistic target is a replay bench: recorded routes through supercombo on the NPU, publishing `modelV2`.
