# MiniVI

**MiniVI** is a low-VRAM (**8 GB VRAM**) and **16–32 GB RAM** focused fork of [trustno1-coder/VIctory-NVIDIA](https://github.com/trustno1-coder/VIctory-NVIDIA) and [Marvisak/VIctory](https://github.com/Marvisak/VIctory).

> **No game files, assets, keys, or binaries are included in this repository.** You must supply your own legal dump of the supported title at runtime. Never reference title names or commit proprietary files in issues or PRs (`cargo test -p xtask` enforces this strictly).

---

## Why MiniVI Exists

Most recent compatibility forks target 12–24 GB VRAM GPUs and 64 GB RAM workstations. On **8 GB GPUs** (RTX 3060 Ti / 3070 / 4060 / 4060 Ti / 5060, RX 6600 / 7600) and **32 GB RAM** PCs, streaming fills VRAM past the card's DXGI budget, triggering PCIe paging stalls and `DXGI_ERROR_DEVICE_REMOVED` (`0x887A0005`), or hits descriptor-slot limits on NVIDIA's 1,000,000-view heap cap.

### What MiniVI Adds
- **Opt-in Top-Mip Dimension Cap (`VICTORY_LEVELS_MAX_DIM=<px>` + `VICTORY_LEVELS_ALL=1`):** skips oversized mips (e.g. >1024 px or >2048 px) cleanly on reserved on-demand textures while retaining packed tail mips and clamping SRV `MostDetailedMip`, cutting texture VRAM usage dramatically without breaking BCn alignment.
- **Safe Unheld Tile Reclamation (`VICTORY_LEVELS_RECLAIM=1`):** unmaps subresources (`D3D12_TILE_RANGE_FLAG_NULL`) of standard mips no longer held by the title and retires tile runs through the submission fence queue (`host::retire`) before returning them to the pool.
- **VRAM-Scaled Target Headroom (`resource::targets_room_kept`):** automatically scales reserved render-target headroom to `<= budget / 4` on `<= 9 GiB` GPUs unless overridden by `VICTORY_CARD_ROOM_FOR_TARGETS_MB`.
- **32 GB Host-RAM Residency Guard (`VICTORY_RESIDENCY=1`):** ports the host-memory pressure monitor and staging/prefetch admission guard from `codec-d/cool_fox` / `VIctory-7900XTX`.
- **Landed-Flight Descriptor Table Flush (`VICTORY_RELAY_FLUSH_TABLES=1`):** frees dynamic descriptor table slots immediately when GPU flights land instead of holding them behind `bury_lag` (prevents dynamic heap exhaustion on NVIDIA 1M view heaps).
- **NVIDIA & Visual Quality Base:** builds on `VIctory-NVIDIA` (Series S two-plane UI compose, `VICTORY_DYNAMIC_SLOTS=524288`, `VICTORY_BVH_MISS=1`, `VICTORY_OWN_UPSCALER=1`, `VICTORY_RENDER_SCALE`, `VICTORY_NAN_SCRUB=1`, and RT resolve skip list).

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
- `scripts\play-minivi-1080p.cmd` (`VICTORY_RENDER_SCALE=1.0`, native 1080p)

---

## Switches Added by MiniVI

| Switch | Default | Purpose |
|---|---|---|
| `VICTORY_LEVELS_ALL=1` | off | Allows large placed 2D mipmapped textures (`>= VICTORY_LEVELS_MIN_KB`) with already-committed pages to use `CreateReservedResource`. |
| `VICTORY_LEVELS_MAX_DIM=<px>` | off | Skips mip levels with `max(w, h) > <px>` on on-demand textures (minimum `64`; keeps packed tail). Try `1024` or `2048` on 8 GB GPUs. |
| `VICTORY_LEVELS_RECLAIM=1` | off | Unmaps standard mips no longer held and returns tiles to the pool safely after GPU fences complete. |
| `VICTORY_RESIDENCY=1` | off | Enables host RAM / commit pressure throttling for staging buffers and texture prefetch on <=32 GB systems. |
| `VICTORY_RELAY_FLUSH_TABLES=1` | off | Immediately releases descriptor table slots from landed GPU flights instead of waiting behind `VICTORY_BURY_LAG`. |

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
- **[codec-d/cool_fox](https://github.com/DoubleGhosty/cool_fox):** 32 GB RAM residency admission & staging pool guards (`residency.rs`).
- **[ZigZagBoi1/ScarlettPort](https://github.com/ZigZagBoi1/ScarlettPort), [Belobug/VIctory-Belobug-AMD](https://github.com/Belobug/VIctory-Belobug-AMD), [DexNom/VIctory](https://github.com/DexNom/VIctory):** title hooks, fast copies, and Wave64/Wave32 shader fixes.
