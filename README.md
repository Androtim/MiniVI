# MiniVI

**MiniVI** is a low-VRAM (**8 GB VRAM**) and **16–32 GB RAM** focused fork built on top of [DoubleGhosty/cool_fox](https://github.com/DoubleGhosty/cool_fox), combining upstream multi-vendor (NVIDIA + AMD) renderer ports and Windows 10 Agility SDK compatibility with MiniVI's aggressive 8 GB VRAM streaming & memory-budget engine.

> **No game files, assets, keys, or binaries are included in this repository.** You must supply your own legal executable and asset dump at runtime. Never reference proprietary asset/title names or commit binaries (`cargo test -p xtask` enforces this strictly).

---

## Key Capabilities

### Upstream Base (`DoubleGhosty/cool_fox`)
- **Multi-GPU & Multi-OS Compatibility:** Supports NVIDIA GeForce and AMD Radeon, Windows 11, Windows 10 (`--features agility-sdk` with `scripts\get-agility-sdk.ps1`), and Wine/Proton.
- **Renderer Ports & Frame Pacing:** `VICTORY_PORT_GUARD=1` and `VICTORY_PORT_JOURNAL=1` save ~2–5 ms/frame on all GPUs (`VICTORY_PORT_CONSTANTS=1` + `VICTORY_PORT_CBV=1` available for AMD 16 GB+ cards), alongside uncapped 60/120 FPS pacing (`VICTORY_FRAME_INTERVAL_MS`), bindless root-signature probing, render-target bind caching, and Pareto host-memory residency guards.
- **Latest Shader & Lighting Upgrades:** Wave-wide branch EXEC preservation, Wave32 face-relocation & cascade lowering, blendshape initialization ordering, air/march in-scatter clamps (`VICTORY_AMBIENT_MARCH`), time-settled ambient estimation (`VICTORY_AMBIENT_SETTLE`), NaN/Inf froxel cleanup, and automatic idle RT resolve skipping when BVH is disabled.

### MiniVI 8 GB VRAM & 32 GB RAM Layer (Iteration 5)
- **Top-Mip Dimension Cap & All-Texture Streaming (`VICTORY_LEVELS_ALL=1`, `VICTORY_LEVELS_MAX_DIM=<px>`, `VICTORY_LEVELS_RECLAIM=1`):** streams eligible 2D mipmapped textures through `CreateReservedResource` with a 256 KiB floor on `<= 9 GiB` GPUs, drops oversized top mips above `MAX_DIM`, preserves `ResourceMinLODClamp`, and safely reclaims unheld tile runs via `host::retire`.
- **VRAM-Scaled Pools & RT Arenas:** scales render-target headroom (`<= budget / 4`), ripe/spare texture pool blocks with refusal cooldowns, RT card buffers (`VICTORY_MEMORY_CARD_MB`), address-indexed RT/BVH arena pages (`VICTORY_RT_MEMORY_MB`: `512` MiB on `<= 6 GiB`, `1024` MiB on `<= 9 GiB`), host snapshot pools (`VICTORY_SNAPSHOT_POOL_MB`), DirectStorage staging (`VICTORY_DSTORAGE_STAGING_MB`), and idle list pools (`VICTORY_LIST_IDLE_MOST` / `VICTORY_LIST_POOL_MOST`, trimming under RAM pressure).
- **Texture Mip Drop & Out-of-Room Retry (`VICTORY_TEXTURE_MIP_DROP=0..3`):** starts oversized placed textures down a configurable number of mips (`1` recommended on 8 GB RT) and retries temporary `E_OUTOFMEMORY` textures after 1000 ms instead of blacking them out permanently.
- **Visual, Stability & Ergonomic Fixes:**
  - **F3 Live Stats Overlay:** toggle FPS, frame time, draw counts, RAM, and VRAM telemetry in both `diag` and `release` builds.
  - **Ambient Probe Cleanup & RT Safety Band (`VICTORY_AMBIENT_RT`):** filters violet/magenta garbage probes in indirect lighting and keeps RT diffuse light inside `[least, most]` of the local estimate.
  - **32-Lane Water-Light Filter (`VICTORY_WATER_LIGHT=1` to enable):** skips the two 64-lane tiled water-light compute shaders on 32-lane GPUs to avoid dark water artifacts and save GPU time.
  - **Ray-Walk Miss Short-Circuit (`VICTORY_BVH_MISS=1`) & NaN Scrubbing (`VICTORY_NAN_SCRUB=1`):** skips stale BVH walks when BVH building is disabled and scrubs NaN/Inf pixel/store fireflies.
  - **Descriptor Safety & Raw View Clamping (`VICTORY_RAW_VIEW_CLAMP`):** validates host heap identity before releasing dynamic slots and clamps dynamic raw SRVs/UAVs inside host buffers.
  - **Helper Thread Priority Boost (`VICTORY_HELPER_PRIORITY`), Embedded DXBC Extent Hashing (`victory shaders`), Adapter Selection (`VICTORY_ADAPTER`), and Bink Intro Skip (`VICTORY_SKIP_BINK=1|all`).**

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
> Pre-warming offline keeps shader translation off gameplay CPU cores. Always pass the same shader-affecting switches (e.g. `VICTORY_BVH_MISS=1`, `VICTORY_NAN_SCRUB=1` for Standard; `VICTORY_FIRSTLANE_OWN=1`, `VICTORY_NAN_SCRUB=1` for Real RT) that your launch preset uses.

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
