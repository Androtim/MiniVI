# MiniVI

**MiniVI** is an experimental **Xbox Series** (**Scarlett** / **GDK**) Windows compatibility layer focused specifically on **8 GB VRAM** GPUs and **16–32 GB system RAM** hosts. Built on [DoubleGhosty/cool_fox](https://github.com/DoubleGhosty/cool_fox) (within the broader VIctory lineage), MiniVI pairs upstream multi-vendor GPU translation (`RDNA2` compute/graphics shaders -> host `D3D12` / `DXIL`) with tight DXGI budget governance, tile-level mip streaming, and clean-room Windows host shims.

> **Strictly Clean-Room / Source-Only Repository:** Zero game executables, asset archives, keys, screenshots, or binary artifacts are stored here. Users supply their own legally owned runtime executable and data directory locally. Automated `cargo test -p xtask` policy checks block leaked binary blobs, titles, or prohibited strings on every commit.

---

## Architecture & Component Status

| Component | Workspace Crate | Status | Implementation Scope |
|---|---|---|---|
| PE32+ Image & Relocation Loader | `victory-loader`, `victory-pe` | ✅ Working | Parses `PE32+` headers, resolves delayed/static `imports`, patches the `IAT`, sets up `TLS` slots/callbacks, and applies base `relocation` fixups |
| Console Runtime & OS HLE | `victory-hle` | ✅ Working | Implements `kernelx` virtual/placeholder memory (`XMemVirtualAlloc`), `XGameRuntime` (`xgameruntime`) services, sync primitives, GameInput, and `Bink` hooks |
| `d3d12_xs` to Host `D3D12` Backend | `victory-gpu` | ✅ Working | Translates `d3d12_xs` `command list` packets, bindless `descriptor` heaps, async `pipeline` compilation, `CreateReservedResource` mip `tiling`, and memory pacing |
| Texture Formats & `BCPack` | `victory-formats` | ✅ Working | Performs console tile `swizzle` layout detiling/mapping and `BCPack` block-compressed asset decoding |
| `RDNA2` -> `DXIL` Shader Translator | `victory-shader` | ✅ Working | Decodes GFX10 wave64/wave32 microcode, structurizes control flow, and emits validated `DXIL` plus internal `HLSL` composer/utility kernels |
| Streaming & `DirectStorage` I/O | `victory-core`, `victory-gpu` | 🟡 Active Tuning | Hosts bounded `DirectStorage` staging buffers (`VICTORY_DSTORAGE_STAGING_MB`) and non-blocking GPU tile residency streaming |
| Ray Tracing (BVH Emulation) | `victory-gpu`, `victory-shader` | 🟡 Optional / Heavy | Supports live software-addressed BVH builds (`-RayTracing`) or fast ray-miss execution (`VICTORY_BVH_MISS=1`, `VICTORY_RT_NO_ARENAS=1`) |
| Telemetry & Clean-Room Policy | `victory`, `xtask` | ✅ Working | Universal in-app `F3` FPS/VRAM stats overlay, offline `victory shaders` cache builder, and `cargo test -p xtask` source guardrails |

---

## Subsystem Overview

### 1. `PE32+` Loader & Runtime Linking (`victory-loader`, `victory-pe`)
MiniVI's `PE loader` maps console `PE32+` binaries directly into the host Windows 10/11 address space without external emulation VMs:
- **Section Mapping & `relocation`:** Maps executable sections with host page protections and processes base `relocation` blocks alongside write-watch tracking (`MEM_WRITE_WATCH`).
- **`imports` & `IAT` Binding:** Walks import descriptors and patches the Import Address Table (`IAT`) to redirect console system calls (`kernelx`, `xgameruntime`, `d3d12_xs`) straight into Rust `HLE` entry points.
- **`TLS` & Thread Lifecycle:** Allocates Thread Local Storage (`TLS`) directories, invokes static `TLS` callbacks, and registers safe watchdog teardown handlers across MSVC and GNU toolchains.

### 2. High-Level Emulation: `kernelx`, `XGameRuntime`, & `Bink` (`victory-hle`)
The `HLE` layer bridges GDK operating-system expectations to native Win32 APIs:
- **`kernelx` Memory & Sync:** Emulates 32-bit constrained allocations, 64 KiB placeholder reservations (`XMemVirtualAlloc` / `VirtualAlloc2`), physical page mapping, events, semaphores, and worker thread pools (`VICTORY_HELPER_PRIORITY`).
- **`XGameRuntime` (`xgameruntime`) & Input:** Provides asynchronous task queues, user/storage stubs, and low-latency HID/GameInput translation with focused-window mouse camera support (`VICTORY_GAMEPAD_MOUSE=0` to disable).
- **Media (`Bink`):** Intercepts `Bink` video playback entry points and optionally fast-skips blocking intro cinematics (`VICTORY_SKIP_BINK=1|all`).

### 3. `RDNA2` -> `DXIL` Recompiler & `HLSL` Host Passes (`victory-shader`, `victory-gpu`)
Hardware shaders compiled for console `RDNA2` wavefronts are statically lowered at load time or offline (`victory shaders`):
- **Wave64 -> Wave32 Compatibility:** Recovers Wave64 scalar masks, runs LDS-flag multi-wave idioms cleanly on NVIDIA 32-lane warps, and falls back to per-lane SCC branch splitting (`cool_fox` `#80`) when wave-wide lowering would fail.
- **Correctness & Scrubbing:** Emits clean `DXIL` containers checked with DXIL validation, optional ray-miss short-circuiting (`VICTORY_BVH_MISS=1`), and NaN/Inf arithmetic scrubbing (`VICTORY_NAN_SCRUB=1`).
- **Native `HLSL` Utility Shaders:** Compiles custom `HLSL` passes on startup for two-plane Series S linear-sRGB presentation with 1-LSB IGN dithering (`compose.rs`), GPU card-memory hash comparison, and probe-based ambient lighting estimation.

### 4. `d3d12_xs` Translation & 8 GB VRAM Engine (`victory-gpu`, `victory-formats`)
Translating `d3d12_xs` into desktop `D3D12` on an 8 GB GPU requires avoiding PCIe stalls and out-of-budget committed allocations:
- **Reserved `tiling` & Swizzle Conversion:** Intercepts `CreateReservedResource` cleanly outside the committed pool so thousands of 2D mipmapped textures stream individual tiles (`VICTORY_LEVELS_ALL=1`, `VICTORY_LEVELS_MAX_DIM`, `VICTORY_LEVELS_RECLAIM=1`), with console texture `swizzle` layout conversion handled inside `victory-formats` alongside `BCPack` decoding and opt-in compute shader detiling (`VICTORY_GPU_DETILE=1|alt`).
- **Descriptors, Commands, & Async Pipelines:** Manages bindless `descriptor` heaps (`1,000,000` view clamp with `HostHeap` ID checks), `command list` pool trimming under host RAM pressure (`VICTORY_LIST_POOL_MOST`), fresh-open command lists (`VICTORY_FRESH_OPEN`), multi-worker `pipeline` compilation, release/diag shader leave-out (`VICTORY_LEAVE_OUT`), and deferred pipeline library stores (`VICTORY_LIBRARY_STORE_LATER=1`).
- **`DirectStorage` & No-RT Speedups:** Enforces a configurable `DirectStorage` staging floor (`VICTORY_DSTORAGE_STAGING_MB`), offloads texture readbacks onto a coalescing background writer (`VICTORY_TEXBACK_ASYNC`), skips redundant ray-skinning and `_BVH` ray-trace compute passes when `VICTORY_BVH_MISS=1`, provides a zero-VRAM No-RT fast path (`VICTORY_RT_NO_ARENAS=1`), and enables `VICTORY_PORT_CONSTANTS=1`, `VICTORY_PORT_GUARD=1`, `VICTORY_PORT_JOURNAL=1`, and `VICTORY_HEAP_RECHECK=0` (-15 ms/frame prepare overhead) for fast host buffer tracking.

---

## Key Capabilities & Recent Engineering

- **Multi-GPU & Multi-OS Support:** Runs on NVIDIA GeForce (RTX 4060 Ti 8 GB reference target) and AMD Radeon (`-Amd` toggle), Windows 11, Windows 10 (`--features agility-sdk` via `scripts\get-agility-sdk.ps1`), and Wine/Proton.
- **VRAM-Scaled Memory Budgeting:** Scales render-target headroom (`<= budget / 4`), texture pools, RT card arenas (`VICTORY_MEMORY_CARD_MB`), address-indexed BVH arenas (`VICTORY_RT_MEMORY_MB`), readback pools (`VICTORY_READBACK_POOL=1`), and host snapshot pools automatically for `<= 9 GiB` GPUs.
- **Visual & Stability Hardening:** Universal `F3` FPS/VRAM telemetry overlay (`diag` and `release`), 32-lane tiled water-light auto-skip (`VICTORY_WATER_LIGHT=1`), out-of-memory texture retries, BC7 mode rotation fix, linear-sRGB Series S plane composition, big-compare slice underflow protection, and clean `ID3D12CommandQueue` suspend/resume (`0xb8`/`0xc0`) shutdown handling.

---

## Quick Start (Windows 10/11 x64)

### Build
```powershell
cargo build --locked --profile diag --features diagnostics -p victory
# Or release:
cargo build --locked --release -p victory
# On Windows 10, add --features agility-sdk and run scripts\get-agility-sdk.ps1
```

### Pre-Warm Shaders & Launch
> [!TIP]
> Pre-warming offline keeps shader translation off gameplay CPU cores. Always pass the same shader-affecting switches (`VICTORY_BVH_MISS=1`, `VICTORY_NAN_SCRUB=1` for Standard; `VICTORY_FIRSTLANE_OWN=1`, `VICTORY_NAN_SCRUB=1` for Real RT) that your launch preset uses.

```powershell
# Standard cache pre-warm:
Remove-Item Env:VICTORY_FIRSTLANE_OWN -ErrorAction SilentlyContinue
$env:VICTORY_BVH_MISS = '1'
$env:VICTORY_NAN_SCRUB = '1'
.\target\diag\victory.exe shaders D:\Path\To\YourDump

# Launch Series S 720p (NVIDIA / 8 GB default):
.\scripts\play-minivi.ps1 -Exe D:\Path\To\YourDump\game_scarlett_master.exe -Preset balanced-720p

# Launch on AMD Radeon:
.\scripts\play-minivi.ps1 -Exe D:\Path\To\YourDump\game_scarlett_master.exe -Preset quality-720p -Amd
```

Double-clickable wrappers live in `scripts/` (`play-minivi-540p.cmd`, `play-minivi-720p.cmd`, `play-minivi-720p-quality.cmd`, `play-minivi-1080p.cmd`), alongside upstream multi-GPU launchers (`Play-VIctory.cmd`, `Play-VIctory-AMD.cmd`, `Play-VIctory-4GB.cmd`).

---

## Testing & Verification

Every pull request and push to `main` is validated with MSVC Clippy (`-D warnings`, default and `--all-features`) and automated `cargo test` suites covering PE loading, formats, HLE stubs, RDNA2 shader lowering, D3D12 host synchronization, and clean-room repository hygiene:

```powershell
cargo test --locked -p xtask
cargo test --workspace --exclude victory-gpu --locked
cargo test -p victory-gpu --locked -- --test-threads=1
```

*Licensed under **GPL-3.0-or-later**. Upstream credits: `DoubleGhosty/cool_fox`, `trustno1-coder/VIctory-NVIDIA`, `Marvisak/VIctory`, `fxceless/victory-fork`, `avatarmanz/VIctory-7900XTX`, `DexNom/VIctory`, `Belobug/VIctory-Belobug-AMD`, and community contributors.*
