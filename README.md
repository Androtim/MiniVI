# MiniVI

**MiniVI** is a low-VRAM (**8 GB VRAM**) and **16–32 GB RAM** focused fork of [trustno1-coder/VIctory-NVIDIA](https://github.com/trustno1-coder/VIctory-NVIDIA) and [Marvisak/VIctory](https://github.com/Marvisak/VIctory).

> **No game files, assets, keys, or binaries are included in this repository.** You must supply your own legal dump of the supported title at runtime. Never reference title names or commit proprietary files in issues or PRs (`cargo test -p xtask` enforces this strictly).

---

## Why MiniVI Exists

Most recent compatibility forks target 12–24 GB VRAM GPUs and 64 GB RAM workstations. On **8 GB GPUs** (RTX 3060 Ti / 3070 / 4060 / 4060 Ti / 5060, RX 6600 / 7600) and **32 GB RAM** PCs, streaming fills VRAM past the card's DXGI budget, triggering PCIe paging stalls and `DXGI_ERROR_DEVICE_REMOVED` (`0x887A0005`), or hits descriptor-slot limits on NVIDIA's 1,000,000-view heap cap.

### What MiniVI Adds
- **Opt-in Top-Mip Dimension Cap (`VICTORY_LEVELS_MAX_DIM=<px>` + `VICTORY_LEVELS_ALL=1`) & Mip Drop (`VICTORY_TEXTURE_MIP_DROP=0..3`):** skips oversized mips (e.g. >1024 px or >2048 px) cleanly on reserved on-demand textures (`VICTORY_LEVELS_MIN_KB` defaults to `256` KiB on `<= 9 GiB` GPUs), or starts huge placed textures (`>= 1024` px by default) a configurable number of mips down (`VICTORY_TEXTURE_MIP_DROP=1` for 8 GB RT), while retaining packed tail mips and clamping SRV `MostDetailedMip`.
- **Safe Unheld Tile Reclamation (`VICTORY_LEVELS_RECLAIM=1`):** unmaps subresources (`D3D12_TILE_RANGE_FLAG_NULL`) of standard mips no longer held by the title and retires tile runs through the submission fence queue (`host::retire`) before returning them to the pool.
- **VRAM-Scaled Target Headroom, Pools & RT Arenas:** automatically scales render-target headroom (`<= budget / 4` on `<= 9 GiB` cards), texture pre-allocation (`2` ripe blocks / `3` spare blocks on `<= 9 GiB` vs `12`/`64` on large GPUs) with allocation-refusal cooldown backoff, RT card-arena budget (`VICTORY_MEMORY_CARD_MB`, `budget / 4` at 85% headroom on `<= 9 GiB`), and address-indexed RT BVH page cap (`VICTORY_RT_MEMORY_MB`: `512` MiB on `<= 6 GiB`, `1024` MiB on `<= 9 GiB`, `3072` MiB above), plus caps/trims host snapshot pools (`VICTORY_SNAPSHOT_POOL_MB`) on `<= 32 GiB` PCs.
- **32 GB Host-RAM Residency Guard (`VICTORY_RESIDENCY=1`):** ports the host-memory pressure monitor and staging/prefetch admission guard from `codec-d/cool_fox` / `VIctory-7900XTX`.
- **Landed-Flight Descriptor Table Flush (`VICTORY_RELAY_FLUSH_TABLES=1`):** frees dynamic descriptor table slots immediately when GPU flights land instead of holding them behind `bury_lag` (prevents dynamic heap exhaustion on NVIDIA 1M view heaps).
- **NVIDIA & Visual Quality Base:** builds on `VIctory-NVIDIA` (Series S two-plane UI compose, `VICTORY_DYNAMIC_SLOTS=524288`, `VICTORY_BVH_MISS=1`, `VICTORY_OWN_UPSCALER=1`, `VICTORY_RENDER_SCALE`, `VICTORY_NAN_SCRUB=1`, and RT resolve skip list).
- **Wave 1 Visual & FPS Fixes (`fxceless` upstream ports):**
  - **Min-LOD Preservation (`#1210`):** keeps `ResourceMinLODClamp` intact when shifting `MostDetailedMip` on streamed texture views so partially resident textures stay sharp.
  - **Early Depth Stencil (`#907`):** emits `ForceEarlyDepthStencil` on depth-before-shader pixel programs, fixing translucent hair/glass depth artefacts.
  - **WC Readback Skip (`VICTORY_SKIP_WC_BACK=1`, `#868`):** skips unnecessary readback copies on CPU write-combining memory (~97% of WC copy traffic). *(Experimental `VICTORY_SKIP_WC_COMPARE=1` is off by default due to an upstream RTX 5080 device-loss report.)*
  - **Bake Source Pre-Upload (`VICTORY_BAKE_SOURCES=1`, `#1264`):** uploads character/decoration bake source textures right before bake draws (`VICTORY_BAKE_SOURCES_MB=256` recommended on 8 GB cards).

---

## Quick Start (Windows 10/11 x64)

### Requirements
- **OS / CPU:** Windows 10 or Windows 11 x64, AVX2 CPU, 16–32 GB RAM (adequate page file recommended).
- **GPU:** Direct3D 12 GPU with Shader Model 6.6 + Mesh Shaders (e.g., NVIDIA RTX 3060 / 4060 Ti 8 GB or AMD RDNA 2+).
- **Toolchain:** Rust `1.98.1` (pinned in `rust-toolchain.toml`, MSVC or `x86_64-pc-windows-gnu` + MinGW-w64).

### Build
Build the `diag` profile (`opt-level = 3` + diagnostics switches needed for `VICTORY_SKIP_PIPELINES`):
```powershell
cargo build --locked --profile diag --features diagnostics -p victory
```
Or plain release (`VICTORY_SKIP_PIPELINES` is ignored in `--release`):
```powershell
cargo build --locked --release -p victory
```

### Run (Portable Scripts)
Copy `victory.example.toml` to `victory.toml` and point `game_dir`, `cache_dir`, and `data_dir` at folders **outside** this repository (all paths stay untracked):
```powershell
# Pre-warm shaders once (NVIDIA example):
$env:VICTORY_BVH_MISS = '1'
$env:VICTORY_NAN_SCRUB = '1'
.\target\diag\victory.exe shaders D:\Path\To\YourDump

# Launch Series S (720p internal -> 1080p own upscaler, 8 GB preset):
.\scripts\play-minivi.ps1 -Exe D:\Path\To\YourDump\game_scarlett_master.exe -Preset balanced-720p
```
Double-clickable wrappers are also in `scripts/`:
- `scripts\play-minivi-540p.cmd` (`VICTORY_RENDER_SCALE=0.5`, lowest GPU/VRAM load)
- `scripts\play-minivi-720p.cmd` (`VICTORY_RENDER_SCALE=0.6666667`, balanced 8 GB)
- `scripts\play-minivi-720p-quality.cmd` (`VICTORY_RENDER_SCALE=0.6666667`, 2048 px mip cap + indoor ambient shading/reflect + WC skip)
- `scripts\play-minivi-1080p.cmd` (`VICTORY_RENDER_SCALE=1.0`, native 1080p)

---

## Switches Added by MiniVI

| Switch | Default | Purpose |
|---|---|---|
| `VICTORY_LEVELS_ALL=1` | off | Allows large placed 2D mipmapped textures (`>= VICTORY_LEVELS_MIN_KB`, defaulting to `256` KiB on `<= 9 GiB` GPUs vs `1024` KiB above) with already-committed pages to use `CreateReservedResource`. |
| `VICTORY_LEVELS_MAX_DIM=<px>` | off | Skips mip levels with `max(w, h) > <px>` on on-demand textures (minimum `64`; keeps packed tail). Try `1024` or `2048` on 8 GB GPUs. |
| `VICTORY_LEVELS_RECLAIM=1` | off | Unmaps standard mips no longer held and returns tiles to the pool safely after GPU fences complete. |
| `VICTORY_TEXTURE_MIP_DROP` / `_MIN_SIZE` | `0` / `1024` | Starts placed textures `>= MIN_SIZE` px `0..3` mips down on low-VRAM cards (`1` useful when testing `VICTORY_RAYS=1` on 8 GB cards). |
| `VICTORY_RT_MEMORY_MB` | auto (`512`/`1024`/`3072`) | Caps resident address-indexed RT/BVH arena pages (`512` MiB on `<= 6 GiB`, `1024` MiB on `<= 9 GiB`, `3072` MiB above; clamp `256..=3072`). |
| `VICTORY_RESIDENCY=1` | off | Enables host RAM / commit pressure throttling for staging buffers and texture prefetch on <=32 GB systems. |
| `VICTORY_RELAY_FLUSH_TABLES=1` | off | Immediately releases descriptor table slots from landed GPU flights instead of waiting behind `VICTORY_BURY_LAG`. |
| `VICTORY_SKIP_WC_BACK=1` | off (on in presets) | Safe FPS boost: skips reading back GPU-written data mapped onto write-combining guest memory. |
| `VICTORY_SKIP_WC_COMPARE=1` | off (unsafe) | **Experimental / Unsafe:** skips WC card-before compare passes; upstream reported `DXGI_ERROR_DEVICE_REMOVED` on RTX 5080. |
| `VICTORY_CENSUS=1` | off | Logs buffer-copy census counters every `VICTORY_CENSUS_SECONDS` seconds (`diag`/logging). |
| `VICTORY_BAKE_SOURCES` / `_MB` | `1` / `1024` | Pre-uploads decoration bake source textures before bake draws (`VICTORY_BAKE_SOURCES_MB=256` recommended for 8 GB presets). |
| `VICTORY_AMBIENT_SHADE` / `_REFLECT` | off | Indoor ambient shading (`1.2,0.85` in presets) and reflection balance (`0.65`). |
| `VICTORY_RIPE_BLOCKS` | auto (`2` on `<=9 GiB`, `12` on `>12 GiB`) | Pre-allocated 64 MiB texture pool blocks kept ahead of draws. |
| `VICTORY_MEMORY_CARD_MB` | auto (`budget/4` on `<=9 GiB`, `4096` on `>12 GiB`) | Max VRAM allocated to address-indexed RT/BVH memory copies before spilling to shared host memory. |
| `VICTORY_SNAPSHOT_POOL_MB` | auto (`128` on `<=32 GiB`, `512` above) | Max RAM kept in the buffer snapshot pool (trimmed under `VICTORY_RESIDENCY=1` pressure). |

---

## Tested Status & Benchmarks (Self-Reported)

- **Test System (`gpu: [NVIDIA]`):** Intel Core i7-13700F, NVIDIA GeForce RTX 4060 Ti 8 GB (driver `32.0.16.2124`), 32 GB RAM, Windows 11 Home x64.
- **Profile:** Xbox Series S (`1280x720` internal via `VICTORY_RENDER_SCALE=0.6666667`, own upscaler to `1920x1080`, `scripts/rt_off_hashes.txt` active, no frame generation).

### Verified Milestones (`7c3b0ea`, 23.8-minute continuous session)
- **`loads` & `boots`:** Binary loads (`0 missing` imports across all modules) and reaches display output.
- **`menu`:** First-run menus and intro video at **`30.0` FPS median** (`33.3 ms/frame`, `draws < 100`, `n=12` telemetry samples).
- **`world` & `playable`:** Played cleanly through the opening cutscenes, playable cell, prison yard, bank tutorial, wanted street escape, parking garage sequence, and open-world boat sequence (`14,803+` frames, `0` crashes, `0` `DXGI_ERROR_DEVICE_REMOVED`, `0` refused buffer views).

### Measured Frame Rate & Memory (`7c3b0ea`)
- **World (`draws >= 1000`, `n=253`):** **`9.7` FPS median / `9.7` avg** (`102.9 ms/frame` median, `1.8–17.7` FPS range; CPU `42.1 ms` avg [`22.5 ms` copies], GPU `54.6 ms` avg, copy-back `5.7 ms` avg, `4,883` draws/frame avg).
- **Dense open-world (`draws >= 3000`, `n=185`):** **`9.0` FPS median / `8.8` avg** (`111.2 ms/frame` median, `3.7–12.6` FPS range, `5,937` draws/frame avg).
- **VRAM (`card accounting`):** `7,743 MB` avg / `7,968 MB` peak against `6,599–6,896 MB` DXGI local budget (`room=false` in `264/272` samples). That run revealed `0` tiled host copies because `host_texture_as(..., reserved=true)` was still intercepted by the committed texture pool (`2,132 MB` held in unmapped mip levels), fixed immediately afterwards by bypassing the pool for `reserved` resources (post-fix benchmark pending).

### Open Caveats / Blockers
- **Dark interiors & night shadows:** RT GI resolve passes are skipped via `scripts/rt_off_hashes.txt` by default, leaving low-light scenes dim under ambient stand-in values.
- **Delayed / missing textures under saturated VRAM:** Before the `!reserved` pool bypass fix, crowded scenes showed missing surface textures and occasional untextured/dark character faces during fast camera cuts.
- **Startup warm-up & streaming hitches:** First seconds stall briefly (`~2–3 FPS`) while the D3D12 pipeline library compiles and newly encountered character/scene textures stream in.
- **Windows TDR (`0x887A0006` without page faults):** With Windows' default 2-second `TdrDelay`, heavy zoom/cutscene bursts on 8 GB cards can trip `DXGI_ERROR_DEVICE_HUNG` even with VRAM headroom available; increasing Windows `TdrDelay` (e.g., `8`–`10` seconds) prevents premature driver resets during complex frames.
- **NVIDIA-only testing so far:** Tested only on RTX 4060 Ti 8 GB; AMD and Intel GPUs remain untested.

---

## Contributing
PRs from low-VRAM / NVIDIA testers are very welcome!
1. Open a Pull Request targeting `main` (direct pushes are restricted).
2. Run `cargo test -p xtask` and `cargo test --workspace --locked` before opening your PR.
3. Never commit game files, hashes of proprietary binaries beyond existing compatibility shims, or title names.
4. Keep new tuning/behavior opt-in and include GPU/VRAM/RAM telemetry in your PR description.

---

## Credits & Upstream Projects (GPL-3.0-or-later)
MiniVI stands on the shoulders of the open-source VIctory ecosystem:
- **[Marvisak/VIctory](https://github.com/Marvisak/VIctory):** core loader, HLE runtime, D3D12 translation, and shader recompiler.
- **[trustno1-coder/VIctory-NVIDIA](https://github.com/trustno1-coder/VIctory-NVIDIA):** NVIDIA capped-heap dynamic slots, Series S UI composition, render-scale / upscaler / watchdog hooks, `VICTORY_BVH_MISS`, NaN scrub, and RT resolve skip list.
- **[avatarmanz/VIctory-7900XTX](https://github.com/avatarmanz/VIctory-7900XTX)** & **[fxceless/victory-fork](https://github.com/fxceless/victory-fork):** write relay, levels-on-demand (`tiles.rs`), card buffer compares, multithreading, and Series S compose (`#1189`).
- **Low-VRAM Community Forks:** `antikohza` / [Impre-visible/victory-gtx1660](https://github.com/Impre-visible/victory-gtx1660) (`VICTORY_TEXTURE_MIP_DROP` onto held levels), `miaohaixiang1-netizen/cool-fox-12gb` (refused pool-growth backoff), and `Dolberthi/neptune-dolberth-nvidia-8gb` (streaming/room balance findings).
- **[codec-d/cool_fox](https://github.com/DoubleGhosty/cool_fox):** 32 GB RAM residency admission & staging pool guards (`residency.rs`).
- **[ZigZagBoi1/ScarlettPort](https://github.com/ZigZagBoi1/ScarlettPort), [Belobug/VIctory-Belobug-AMD](https://github.com/Belobug/VIctory-Belobug-AMD), [DexNom/VIctory](https://github.com/DexNom/VIctory):** title hooks, fast copies, and Wave64/Wave32 shader fixes.
