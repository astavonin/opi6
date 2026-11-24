# Compiling your own models for the NPU

ONNX → `.cix` with CIX's Compass compiler (`CixBuilder 6.1.3407.2`, from `cix_noe_sdk_25_q3_release.tar.gz`). The compiler is x86-only and Python 3.10-only, so it runs on the laptop in a container, not on the board. Static shapes only.

Verified by compiling openpilot's supercombo ([npu-openpilot.md](npu-openpilot.md)) and a two-layer control model, both of which then ran on the board.

## Four stages, driven by hand

```
cixparse -c parse.cfg     # ONNX -> float Compass IR (.txt graph + .bin weights)
cixopt   -c opt.cfg       # quantize / choose precision -> optimized IR
cixgb    ir.txt -w ir.bin --target X2_1204MP3 -o model.elf
cixpack  model.elf model.cix 0 1
```

`cixbuild` runs all four from one config, but its Simplify pass renames the output tensor while leaving the old name in the graph header, and the Optimizer then dies with a `KeyError`. Drive the stages yourself.

## The traps, in the order you'll hit them

**`cixpack` is not optional.** `cixgb` emits a raw AIPU ELF (`7f 45 4c 46`); the runtime wants CIX's FlatBuffer container (`14 00 00 00 10 00 1c 00`, which is what any hub `.cix` starts with). Feed it the ELF and `libnoe` segfaults inside `noe_load_graph` with nothing in `dmesg`.

**The wheel ships its binaries non-executable.** `chmod +x` both `AIPUBuilder/_C/bin/*` — that's the copy on GBuilder's `PATH` — and `AIPUBuilder/cixpack`. The symptom is `sh: 1: aipuoas: Permission denied`, reported as a generic "Build Subgraph error".

**`cixopt` reads every field from `[Common]`.** Anything under `[Optimizer]` is silently ignored and the output lands in a default `opt_log/`. `cixparse` and `cixgb` use their own sections.

**Calibration data arrives one rank too high.** The Optimizer feeds samples through a torch DataLoader, which collates and so prepends a batch axis — the model's inputs must declare one. Use `numpymultiinputwithoutbatchdimdataset` with a single `.npy` holding `{ir_tensor_name: array}` at pre-batch shapes. The generic `generaldict` plugin assumes axis 0 is a batch and mangles anything shaped like `[132,1,8]`.

**Run the container as yourself** (`--user $(id -u):$(id -g) -e HOME=/tmp`) from the first command, or root-owned outputs block every later run. GBuilder also needs `LD_LIBRARY_PATH` covering `AIPUBuilder/simulator-lib` and `AIPUBuilder/_C`.

## Precision is negotiated, not chosen

`trigger_float_op = float16_preferred` silently falls back to all-int8. Forcing it with `!` then fails, because the X2 layer lib has no float activation×activation MatMul ("Scalar Matmul does NOT support X2") and no FP16 convolution for 25 of 36 convs. Weight-only (`float16_act_int_wht`) is worse — 241 errors.

What builds is the per-node form:

```ini
trigger_float_op = float16_preferred! & <[MatMul,Convolution,DepthwiseConv,FullyConnected]:disable>
```

int8 matrix ops, FP16 for everything else. Valid global values are `disable`, `{float16,bfloat16,float32}_preferred`, and `*_act_int_wht`, each optionally suffixed `!` to force.

## One vendor library bug to design around

`tpccllib_x2.a` exports the symbol `clip` from both the i8u8 and the i16u16 StrideSlice object. A graph whose slices span both dtype classes pulls in both and `aipuold` fails with `duplicate symbol: clip`. Keep every Slice on one dtype class — for supercombo that meant running its uint8 image queue in FP16 and casting back at the output.
