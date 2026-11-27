## Summary
<!-- What does this PR change, and what problem or regression does it fix? -->

## Rig Specs Tested On
- **CPU:** 
- **GPU & VRAM:** 
- **System RAM:** 
- **OS & GPU Driver:** 

## Run Settings & Profile
- **Build & Commit SHA:** `release` / `diag` @ `<sha>`
- **Console Profile & Internal Resolution / Scale:** `series-s` / `series-x` — e.g. `720p` (`0.6666667`) / `1080p` (`1.0`)
- **Ray Tracing:** `off` / `on` (`-RayTracing`)
- **Upscaling:** `off` / `DLSS quality` / `DLSS balanced` / `DLSS performance` / `title upscaler`
- **Frame Generation:** `off` / `DLSS 2x..6x` / `FSR 3 2x`
- **Launcher Command / Preset & Extra `VICTORY_*` Overrides:** 
- **Scene / Area & Session Length:** 

## Measurements & Verification
- **Base FPS (without Frame Gen):** avg / median (and drops if any)
- **Frame-Gen FPS (if enabled):** 
- **VRAM / RAM Usage:** avg / peak
- **Crashes / DRED Resets:** `0` / describe
- **Automated Checks:**
  - [ ] `cargo clippy --workspace --all-targets --locked -- -D warnings`
  - [ ] `cargo clippy --workspace --all-targets --all-features --locked -- -D warnings`
  - [ ] `cargo test --locked -p xtask`
  - [ ] Relevant crate unit tests (`cargo test ...`)
