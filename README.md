# MiniVI

**MiniVI** is an experimental **Xbox Series** (**Scarlett** / **GDK**) Windows compatibility layer tuned for **8 GB VRAM** GPUs and **16–32 GB system RAM** hosts. Rebased onto [trustno1-coder/VIctory-NVIDIA](https://github.com/trustno1-coder/VIctory-NVIDIA) (`foxhound` base, commit `0cef07e`), MiniVI combines upstream CPU/texqueue speedups, NVIDIA DLSS Super Resolution, 2x–6x DLSS / FSR 3 Frame Generation, the `F1` settings menu, and the `F3` telemetry overlay with strict DXGI VRAM governance, level-by-level reserved mip streaming, title hang-watchdog disarmament, and BVH traversal fixes.

> **Strictly Clean-Room / Source-Only Repository:** Zero game executables, asset archives, keys, screenshots, or binary artifacts are stored here. Users supply their own legally owned runtime executable and data directory locally. Automated `cargo test -p xtask` policy checks block leaked binaries or prohibited strings on every commit. See [docs/asset-policy.md](docs/asset-policy.md).

---

## Architecture & Component Status

| Component | Workspace Crate | Status | Implementation Scope |
|---|---|---|---|
| PE32+ Image & Relocation Loader | `victory-loader`, `victory-pe` | ✅ Working | Parses `PE32+` headers, resolves delayed/static `imports`, patches `IAT`, sets up `TLS` callbacks, applies relocations, and disarms the 1.0.2.1 hang watchdog (`VICTORY_NO_WATCHDOG=1`) |
| Console Runtime & OS HLE | `victory-hle` | ✅ Working | Implements `kernelx` virtual/placeholder memory (`XMemVirtualAlloc`), `XGameRuntime`, sync primitives, `GameInput` + focused-window mouse/IME support, and `Bink` video hooks |
| `d3d12_xs` to Host `D3D12` Backend | `victory-gpu` | ✅ Working | Translates `d3d12_xs` command lists (`VICTORY_THIN=1`, `VICTORY_JOIN_PARTS=8`), bindless heaps, pooled readbacks, `CreateReservedResource` mip tiling, Streamline DLSS / FSR 3 FG, `F1` menu, and `F3` stats overlay |
| Texture Formats & `BCPack` | `victory-formats` | ✅ Working | Converts console texture swizzles and decodes `BCPack` blocks, paired with GPU memory compare (`VICTORY_WIDE_BACK=1`) |
| `RDNA2` -> `DXIL` Shader Translator | `victory-shader` | ✅ Working | Decodes GFX10 wave64/wave32 microcode, structurizes control flow, restores `-1` BVH instance/procedural returns, allowlists validated `group=64` culling & volumetric water kernels, and supports early depth (`VICTORY_EARLY_DEPTH=1`) + NaN scrubbing (`VICTORY_NAN_SCRUB=1`) |
| Telemetry & Clean-Room Policy | `victory`, `xtask` | ✅ Working | Offline `victory shaders` cache builder, `F3` FPS/VRAM telemetry overlay, and `cargo test -p xtask` source policy checks |

---

## Frame Generation & Upscaling Support

| GPU Tier | Upscaling | Frame Generation | Notes |
|---|---|---|---|
| GeForce RTX 40 / 50 | DLSS Super Resolution (`quality`/`balanced`/`performance`/`dlaa`) | **DLSS Frame Generation** (`2x` on RTX 40, up to `6x` on RTX 50) | Run `.\scripts\get-nvidia-sdks.ps1` or `.\Get-NVIDIA-DLSS.cmd` once to fetch NVIDIA's runtime DLLs (`nvidia-sdk\`, git-ignored) |
| GeForce RTX 20 / 30 | DLSS Super Resolution | **AMD FSR 3 Frame Generation** (`2x`) | Run `.\scripts\get-amd-fsr.ps1` / `victory get-fsr` (or optional MFG Unlocker via `F1`) |
| AMD Radeon / Other | Title upscaler (`VICTORY_UPSCALER=6`) | **AMD FSR 3 Frame Generation** (`2x`, Series S profile) | Use `scripts\play-minivi.ps1 -Amd` |

- Press **`F1`** in-game for the live settings menu (DLSS mode/preset, Frame Generation toggle & multiplier, console profile, water-light mode, saved to `victory-settings.txt`).
- Press **`F3`** in-game for the FPS, frame-time, draw count, CPU/GPU timing, RAM, and VRAM panel.
- On **Windows 10**, Shader Model 6.6 requires the D3D12 Agility SDK (`.\scripts\get-d3d12.ps1` or `victory get-d3d12`).

---

## 8 GB VRAM / 16–32 GB RAM Hardening (MiniVI Layer)

- **Reserved Mip Streaming & Reclaim (`tiles.rs`, `texture.rs`, `resource.rs`):** Enables `VICTORY_LEVELS_ON_DEMAND=1`, `VICTORY_LEVELS_ALL=1`, `VICTORY_LEVELS_MAX_DIM`, `VICTORY_LEVELS_RECLAIM=1` (returning unheld standard tiles via `retire`), `256 KiB` tile floor on `<= 9 GiB` GPUs, and optional `VICTORY_TEXTURE_MIP_DROP`.
- **VRAM-Scaled Headroom (`resource.rs`, `memory.rs`, `shadow.rs`):** Caps reserved render-target headroom at `<= budget / 4` on `<= 9 GiB` cards while preserving upstream settle decay (`targets_seen`/`targets_kept`), scales address-indexed RT/BVH page limits (`most_pages_for`, `spare_pages_for`, `VICTORY_BVH_FAULTS_ALL`), and scales card-memory shadow budgets (`memory_card_budget`).
- **Bounded Host Pools & RAM Pressure Trimming (`host.rs`, `list.rs`, `shadow.rs`, `texback.rs`):** Adds bounded `ReadbackPool` (`VICTORY_READBACK_POOL=1`, `VICTORY_READBACK_POOL_MB=64`), RAM-aware CPU snapshot pooling (`snapshot_pool_bytes`, `trim_snapshot_pool`), and idle command-list pool trimming (`trim_on_pressure`, `VICTORY_LIST_POOL_MOST`) under `residency::pressured()`.
- **Watchdog & Shader Completeness (`victory-loader`, `victory-shader`):** Disarms the title hang watchdog (`VICTORY_NO_WATCHDOG=1`), preserves full hair/lighting/world shader coverage alongside upstream `VICTORY_EARLY_DEPTH=1`, `VICTORY_AMBIENT_SPECULAR=1`, and `VICTORY_LEAVE_OUT`, fixes `-1` BVH instance/procedural returns, and allowlists 6 validated `group=64` culling and volumetric water compute kernels for wave32.

---

## Quick Start (Windows 10/11 x64)

### Build
```powershell
cargo build --locked --profile diag --features diagnostics -p victory
# Or release:
cargo build --locked --release -p victory
# Optional Windows 10 Agility SDK + NVIDIA DLSS / AMD FSR3 DLLs:
.\scripts\get-nvidia-sdks.ps1
```

### Pre-Warm Shaders & Launch
> [!TIP]
> Pre-warm offline with the exact shader-affecting switches (`VICTORY_EARLY_DEPTH=1` and `VICTORY_NAN_SCRUB=1` for standard presets; add `VICTORY_FIRSTLANE_OWN=1` for Ray Tracing) so runtime launches hit the cache 100%.

```powershell
$env:VICTORY_EARLY_DEPTH = '1'
$env:VICTORY_NAN_SCRUB = '1'
.\target\diag\victory.exe shaders D:\Path\To\YourDump

# Launch 720p Series S + DLSS Quality (add -FrameGen 2x for 2x DLSS FG):
.\scripts\play-minivi.ps1 -Exe 'D:\Path\To\YourDump\game_scarlett_master.exe' -Preset balanced-720p -Dlss quality
```

---

## Credits

Built on [trustno1-coder/VIctory-NVIDIA](https://github.com/trustno1-coder/VIctory-NVIDIA), which itself builds on [readmet3xt-lab/foxhound](https://github.com/readmet3xt-lab/foxhound), [Marvisak/VIctory](https://github.com/Marvisak/VIctory), [fxceless/victory-fork](https://github.com/fxceless/victory-fork), [codec-d/cool_fox](https://github.com/codec-d/cool_fox), [avatarmanz/VIctory-7900XTX](https://github.com/avatarmanz/VIctory-7900XTX), [Belobug/VIctory-Belobug-AMD](https://github.com/Belobug/VIctory-Belobug-AMD), and [DexNom/VIctory](https://github.com/DexNom/VIctory).

## License

GPL-3.0-or-later, matching `VIctory`, `foxhound`, and `VIctory-NVIDIA`. See [LICENSE](LICENSE) and [docs/asset-policy.md](docs/asset-policy.md).
