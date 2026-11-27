# MiniVI

**MiniVI** is a low-VRAM (**8 GB VRAM**) and **16–32 GB RAM** focused fork of [trustno1-coder/VIctory-NVIDIA](https://github.com/trustno1-coder/VIctory-NVIDIA) and [Marvisak/VIctory](https://github.com/Marvisak/VIctory).

> **No game files, assets, keys, or binaries are included in this repository.** You must supply your own legal dump of the supported title at runtime. Never reference title names or commit proprietary files in issues or PRs (`cargo test -p xtask` enforces this strictly).

---

## Why MiniVI Exists

Most recent compatibility forks target 12–24 GB VRAM GPUs and 64 GB RAM workstations. On **8 GB GPUs** (RTX 3060 Ti / 3070 / 4060 / 4060 Ti / 5060, RX 6600 / 7600) and **32 GB RAM** PCs, streaming fills VRAM past the card's DXGI budget, triggering PCIe paging stalls and `DXGI_ERROR_DEVICE_REMOVED` (`0x887A0005`), or hits descriptor-slot limits on NVIDIA's 1,000,000-view heap cap.

### What MiniVI Adds
- **Opt-in Top-Mip Dimension Cap (`VICTORY_LEVELS_MAX_DIM=<px>` + `VICTORY_LEVELS_ALL=1`) & Mip Drop (`VICTORY_TEXTURE_MIP_DROP=0..3`):** skips oversized mips (e.g. >1024 px or >2048 px) cleanly on reserved on-demand textures (`VICTORY_LEVELS_MIN_KB` defaults to `256` KiB on `<= 9 GiB` GPUs), or starts huge placed textures (`>= 1024` px by default) a configurable number of mips down (`VICTORY_TEXTURE_MIP_DROP=1` for 8 GB RT), while retaining packed tail mips and clamping SRV `MostDetailedMip`.
- **Safe Unheld Tile Reclamation (`VICTORY_LEVELS_RECLAIM=1`):** unmaps subresources (`D3D12_TILE_RANGE_FLAG_NULL`) of standard mips no longer held by the title and retires tile runs through the submission fence queue (`host::retire`) before returning them to the pool.
- **VRAM-Scaled Target Headroom, Pools, Command Lists & RT Arenas:** automatically scales render-target headroom (`<= budget / 4` on `<= 9 GiB` cards), texture pre-allocation (`2` ripe blocks / `3` spare blocks on `<= 9 GiB` vs `12`/`64` on large GPUs) with allocation-refusal cooldown backoff, configurable idle command-list pool bounds (`VICTORY_LIST_POOL_MOST`, `VICTORY_LIST_POOL_IDLE_S`, defaulting to `512` / no TTL and trimming down to `64` under residency pressure without allocator churn), DirectStorage staging floor (`VICTORY_DSTORAGE_STAGING_MB`), RT card-arena budget (`VICTORY_MEMORY_CARD_MB`, `budget / 4` at 85% headroom on `<= 9 GiB`), and address-indexed RT BVH page cap (`VICTORY_RT_MEMORY_MB`: `512` MiB on `<= 6 GiB`, `1024` MiB on `<= 9 GiB`, `3072` MiB above), plus caps/trims host snapshot pools (`VICTORY_SNAPSHOT_POOL_MB`) on `<= 32 GiB` PCs.
- **32 GB Host-RAM Residency Guard (`VICTORY_RESIDENCY=1`) & Wave64 Foliage Visibility (`structure.rs`):** ports the host-memory pressure monitor from `codec-d/cool_fox` / `VIctory-7900XTX` and `DexNom/VIctory` (`76749ce5`) restored wave64 lane-mask recovery for voxel visibility shaders.
- **Landed-Flight Descriptor Table Flush (`VICTORY_RELAY_FLUSH_TABLES=1`) & Safety Hardening:** frees dynamic descriptor table slots immediately when GPU flights land instead of holding them behind `bury_lag`, guards against split-submission table leaks (`#1320`) and reused heap-address frees (`#1324`), pins placed alias source textures under lock (`#1336`), isolates panicking pipeline builds (`#1353`), and creates indirect command signatures outside the cache mutex (`#1393`).
- **Universal F3 Stats Overlay, 32-Lane Water-Light Filter, RT Fault/Ambient Tuning & AMD Relay Safety (Iteration 4B):**
  - **F3 live stats panel in all builds (`diag` and `release`):** toggle with **F3** or start with `VICTORY_PANEL=1` for live FPS, frame time, draw counts, RAM, and VRAM telemetry.
  - **Automatic 32-lane tiled water-light skip (`VICTORY_WATER_LIGHT=1` to re-enable):** skips the two 64-lane tiled water-light compute shaders on 32-lane GPUs by default, removing dark rectangular water blocks and saving ~15 ms GPU/frame while leaving 64-lane AMD execution untouched.
  - **Real RT fault budget & ambient safety band (`VICTORY_BVH_FAULTS_ALL`, `VICTORY_AMBIENT_RT`):** uncaps page-fault intake above `2048` (`8192` in `-RayTracing`), keeps traced indirect diffuse light bounded to `[least, most]` multiples of the local radiance estimate (`0.5,2.0,0.8` in `-RayTracing`), and reduces RT card-buffer pressure (`512` MiB) for extra texture headroom.
  - **Multi-vendor defaults (`-Amd`, `VICTORY_BAKE_SOURCES_MB=512`):** defaults the write relay off on AMD GPUs unless `VICTORY_RELAY` is set explicitly (`play-minivi.ps1 -Amd` omits relay overrides), and raises character decoration bake source budgets to `512` MiB on non-540p presets.
- **Texture Retry, Pooled Readbacks & Safety Hardening (Iteration 4C):**
  - **Retry out-of-room textures (`#3198`):** temporary `E_OUTOFMEMORY` texture failures wait `1000` ms and retry on later draws instead of permanently turning textures black.
  - **Bounded texture readback reuse & ticket refresh (`#1376`, `VICTORY_READBACK_POOL=1` / `VICTORY_READBACK_POOL_MB=64`):** re-registers texture readback tickets when memory is reused, reuses retired readback buffers across closed command lists, forgets released view heaps' RT address runs (`#589`), rejects removed-device fence waits in background workers (`#1366`), and fixes embedded DXBC byte extents during offline shader pre-warming.
- **Texture Decode, Raw View Clamp & Helper Thread Priority (Iteration 4D):**
  - **BC7 rotation field fix (`victory-formats`):** applies BC7 channel rotation only to modes `4` and `5`, preventing corrupted blocks and shift panics on modes `0–3`, `6`, and `7`.
  - **Raw buffer view clamping (`VICTORY_RAW_VIEW_CLAMP=0` restores unclamped):** bounds dynamic raw SRVs and UAVs to the host buffer's byte width and turns unaligned or out-of-range views into null views.
  - **Helper thread priority boost (`VICTORY_HELPER_PRIORITY=0` disables):** keeps background refresh, heap-sync, and landing workers at above-normal priority alongside the submit thread.
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
> [!TIP]
> **Pre-warming shaders offline is strongly recommended on lower-end / mid-range CPUs and 8 GB GPUs.** Live shader translation competes with cutscene streaming and frame recording, causing CPU bottlenecks, hitching, and delayed scene/model loads. Pre-warming once per build keeps CPU cores free during gameplay.

Copy `victory.example.toml` to `victory.toml` and point `game_dir`, `cache_dir`, and `data_dir` at folders **outside** this repository (all paths stay untracked):
```powershell
# 1a. Pre-warm Standard shaders once (for bench / quality / 540p / 720p / 1080p presets):
Remove-Item Env:VICTORY_FIRSTLANE_OWN -ErrorAction SilentlyContinue
$env:VICTORY_BVH_MISS = '1'
$env:VICTORY_NAN_SCRUB = '1'
.\target\diag\victory.exe shaders D:\Path\To\YourDump

# 1b. Or pre-warm Real RT shaders (used by play-minivi.ps1 -RayTracing):
Remove-Item Env:VICTORY_BVH_MISS -ErrorAction SilentlyContinue
$env:VICTORY_FIRSTLANE_OWN = '1'
$env:VICTORY_NAN_SCRUB = '1'
.\target\diag\victory.exe shaders D:\Path\To\YourDump

# 2. Launch Series S (720p internal -> 1080p own upscaler, 8 GB preset):
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
| `VICTORY_TEXTURE_MIP_DROP` / `_MIN_SIZE` | `0` / `1024` | Starts placed textures `>= MIN_SIZE` px `0..3` mips down on low-VRAM cards (leave `0` when testing real RT BVH lighting). |
| `VICTORY_RT_MEMORY_MB` | auto (`512`/`1024`/`3072`) | Caps resident address-indexed RT/BVH arena pages (`512` MiB on `<= 6 GiB`, `1024` MiB on `<= 9 GiB`, `3072` MiB above; clamp `256..=3072`). Pair with `VICTORY_BVH_BUILDER=1` + `VICTORY_FIRSTLANE_OWN=1` (and unset `VICTORY_BVH_MISS` / `VICTORY_AMBIENT`) for real ray tracing. |
| `VICTORY_LIST_POOL_MOST` / `_IDLE_S` | `512` / off | Optional cap and TTL for pooled `HostList` allocators; trims excess idle lists down to `64` under residency pressure without allocator churn. |
| `VICTORY_DSTORAGE_STAGING_MB` | off (`32` MiB) | Raises DirectStorage streaming staging floor (`32..=256` MiB; `64` in presets) to overlap cutscene/world reads. |
| `VICTORY_WINDOW_KB` / `_TAILS` | `4096` / `0` | Optional smaller shadow-window block/tail tracking (default `4096 KiB` avoids overlapping-window RAM growth and CPU overhead). |
| `VICTORY_RESIDENCY=1` | off | Enables host RAM / commit pressure throttling for staging buffers and texture prefetch on <=32 GB systems. |
| `VICTORY_RELAY_FLUSH_TABLES=1` | off | Immediately releases descriptor table slots from landed GPU flights instead of waiting behind `VICTORY_BURY_LAG`. |
| `VICTORY_SKIP_WC_BACK=1` | off (on in presets) | Safe FPS boost: skips reading back GPU-written data mapped onto write-combining guest memory. |
| `VICTORY_SKIP_WC_COMPARE=1` | off (unsafe) | **Experimental / Unsafe:** skips WC card-before compare passes; upstream reported `DXGI_ERROR_DEVICE_REMOVED` on RTX 5080. |
| `VICTORY_CENSUS=1` | off | Logs buffer-copy census counters every `VICTORY_CENSUS_SECONDS` seconds (`diag`/logging). |
| `VICTORY_BAKE_SOURCES` / `_MB` | `1` / `1024` | Pre-uploads decoration bake source textures before bake draws (`VICTORY_BAKE_SOURCES_MB=512` in non-540p presets). |
| `VICTORY_READBACK_POOL` / `_MB` | off / `256` MiB | Reuses retired automatic texture readback buffers within a capped idle pool (`1` / `64` MiB in presets). |
| `VICTORY_RAW_VIEW_CLAMP` | on (`1`) | Clamps dynamic raw buffer views to host buffer bounds (`0` restores unclamped views). |
| `VICTORY_HELPER_PRIORITY` | on (`1`) | Runs helper workers at above-normal Windows thread priority alongside the submit thread (`0` reverts to normal). |
| `VICTORY_PANEL` | off (`F3` toggles) | Shows the live FPS, draws, RAM, and VRAM overlay in both `diag` and `release` builds. |
| `VICTORY_WATER_LIGHT` | auto (off on 32-lane) | Re-enables the two 64-lane tiled water-light compute shaders on 32-lane hosts (`1` forces them on; default skips them to avoid dark water blocks). |
| `VICTORY_BVH_FAULTS_ALL` | `2048` | Maximum RT address-indexed fault pages mapped (`8192` in `play-minivi.ps1 -RayTracing`). |
| `VICTORY_AMBIENT_RT` | off | Keeps traced indirect diffuse light between `<least>,<most>[,<level>]` multiples of the radiance estimate (`0.5,2.0,0.8` in `-RayTracing`). |
| `VICTORY_RELAY` | auto (`off` on AMD) | Defaults off on AMD GPUs unless explicitly set; NVIDIA presets set `1`/`2`. |
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

### Measured Frame Rate & Memory
- **Iteration 1 (`7c3b0ea`, 23.8-minute continuous run):**
  - **World (`draws >= 1000`, `n=253`):** **`9.7` FPS median / `9.7` avg** (`102.9 ms` median, CPU `42.1 ms`, GPU `54.6 ms`, `4,883` draws/frame).
  - **Dense (`draws >= 3000`, `n=185`):** **`9.0` FPS median / `8.8` avg** (`111.2 ms` median).
  - **VRAM:** `7,743 MB` avg / `7,968 MB` peak (`room=false` in `264/272` samples; uncovered the `CreateReservedResource` pool bypass bug fixed in `6837e41`).
- **Iteration 2 (`7a633e6`, 8 GB beach/boat mission run):**
  - **World (`draws >= 1000`, `n=72`):** **`11.2` FPS median / `11.8` avg** (`4.4–19.4` FPS; CPU `37.2 ms` [`18.3 ms` copies], GPU `41.4 ms`, `3,530` draws/frame).
  - **Dense (`draws >= 3000`, `n=49`):** **`10.9` FPS median / `10.7` avg**.
  - **VRAM (`card accounting`):** **`5,084 MB` avg / `5,971 MB` peak** against `6,308–7,181 MB` budget, **`room=false` dropped `264/272 -> 0/92`**, `7,118` live tiled copies saved **`6,027 MB`** VRAM (`0` failed uploads), unmapped top mips dropped `2,132 -> 365 MB` avg, **`0` crashes**.
- **Iteration 3 (`5f0b2ef`) & Iteration 4A follow-up:**
  - `5f0b2ef` fixed `VICTORY_TEXTURE_MIP_DROP` + `VICTORY_LEVELS_ON_DEMAND` over-allocation and added `VICTORY_DSTORAGE_STAGING_MB=64`, keeping `room=false` at `0/228` and `0` crashes, while A/B telemetry caught a CPU/FPS regression (`9.8` med FPS, `24.9 GB` peak RAM) caused by `VICTORY_WINDOW_KB=1024` overlapping windows and the aggressive `128`-list pool cap.
  - **Iteration 4A (`370cd42`):** restored `4096 KiB` shadow windows and `512`-list pooling (trimming to `64` only under pressure), landed `fxceless` stability fixes (`#1320`, `#1324`, `#1336`, `#1353`), and unblocked BVH builder scan shaders with `VICTORY_FIRSTLANE_OWN=1` (`25,779` pre-warmed RT shaders, `25,776` Standard):
    - **Real RT (`-RayTracing`, `n=88`):** **`9.9` FPS median / `9.8` avg** (`11.9–15.5` FPS in outdoor/interior views, 16 RT read + 74 BVH build dispatches/frame), **`5,703 MB` avg / `6,503 MB` peak VRAM (`0/110` `room=false`)**, **`22.0 GB` avg / `25.7 GB` peak RAM**, **`0` crashes**.
    - **720p Bench (`n=305`, 28.5 min continuous):** **`9.7` FPS median / `9.7` avg** (`9.4` med dense), **`5,807 MB` avg / `6,211 MB` peak VRAM (`0/336` `room=false`)**, **`21.4 GB` avg / `26.0 GB` peak RAM**, ending with a captured DRED `0x887A0006` device-hung TDR at `6,932` draws and `45,143` card buffer compares during fast driving (targeted by Iteration 4C parallel card hashing).
  - **Iteration 4B:** enables the F3 stats overlay in all builds, skips 64-lane water-light shaders by default on 32-lane hosts, adds `VICTORY_BVH_FAULTS_ALL` (`8192` in `-RayTracing`) + `VICTORY_AMBIENT_RT` (`0.5,2.0,0.8`), unlocks lock-free command signature creation (`#1393`), raises bake source budget to `512` MiB, and defaults `relay()` off on AMD (`-Amd` switch) without modifying `crates/victory-shader/` (keeping both pre-warmed shader caches valid).
  - **Iteration 4C:** retries temporarily out-of-room textures (`#3198`), adds bounded texture readback buffer pooling (`VICTORY_READBACK_POOL=1`, `64` MiB in presets) and stale ticket re-registration (`#1376`), cleans up released heap RT address runs (`#589`), catches removed devices in background fence waits (`#1366`), and fixes offline embedded DXBC extent hashing — still with zero `crates/victory-shader/` edits.
  - **Iteration 4D:** fixes BC7 channel rotation on non-rotation modes (`0–3`, `6–7`), clamps dynamic raw buffer views inside host buffers (`VICTORY_RAW_VIEW_CLAMP`), and boosts submit-helper thread priorities (`VICTORY_HELPER_PRIORITY`) — zero `crates/victory-shader/` edits.

### Open Caveats / Blockers
- **Dark interiors & night shadows:** RT GI resolve passes are skipped via `scripts/rt_off_hashes.txt` by default, leaving low-light scenes dim under ambient stand-in values; real RT is testable via `play-minivi.ps1 -RayTracing`.
- **Cutscene/character streaming hitches & colored-pixel / dark-face artifacts:** Under CPU DirectStorage streaming, fast camera cuts briefly show low-LOD polygons while meshes/textures stream in, and occasional character face shading/mip artifacts remain under investigation.
- **Startup warm-up:** Pre-warming shaders offline (`victory.exe shaders <GameDir>`) is especially beneficial for lower-end setups and is recommended after translator or flag changes so newly visited passes do not compile live mid-cutscene.
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
- **[ZigZagBoi1/ScarlettPort](https://github.com/ZigZagBoi1/ScarlettPort), [Belobug/VIctory-Belobug-AMD](https://github.com/Belobug/VIctory-Belobug-AMD), [DexNom/VIctory](https://github.com/DexNom/VIctory):** title hooks, fast copies, and Wave64/Wave32 shader fixes (`76749ce5` wave64 restored mask recovery).
