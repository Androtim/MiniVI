//! A 2560x1440 SDR display for the supported Series X retail image (the game,
//! 1.0.2.1): the title presents at 3840x2160 on Series X, its scene drawn at
//! 2560x1440 and scaled up by its own temporal pass. With 1440p asked for
//! (`VICTORY_NATIVE_1440P=1`, or `VICTORY_RENDER_1080P=1` for a 1920x1080
//! scene scaled to 1440p), the image's SDR display mode, the UI memory pool,
//! the legacy UI flag and the temporal scene scale are patched before it is
//! mapped: the title then makes a 1440p output, lays its UI out on the
//! 3840x2160 size its menus are authored for and scales it onto the 2560x1440
//! targets (as Series S does at 1080p), and no 4K pass runs.
//!
//! The legacy UI flag (`0xA9438F4`, byte) is what scales the UI: the title
//! sets it from its console preset, 1 on Series S, 0 on Series X, where the
//! output is always 3840x2160 and nothing needs scaling. Left at 0 with the
//! 1440p output, menus and the HUD were laid out on a 2560x1440 stage with
//! their 4K-sized content, 1.5 times too large and overlapping.
//!
//! Ported from DexNom's fork (DexNom/VIctory, `apps/victory/src/native_1440p.rs`,
//! GPL-3.0-or-later), its native 1440p part only. Every field is checked
//! against the stock bytes first: another build is refused, not patched.

use anyhow::{Context, Result, ensure};
use victory_formats::texture::{Dimension, Swizzle, Texture, TextureDesc};
use victory_hle::streamline::Mode;
use victory_loader::PreparedImage;

/// Whether `bytes` are the stock ones whose BLAKE3 hash (hex) is `hash`.
/// The stock bytes of each place patched are kept as their hash only: no
/// bytes of the title are in this repository.
fn same(bytes: &[u8], hash: &str) -> bool {
    blake3::hash(bytes).to_hex().as_str() == hash
}

pub(super) const RETAIL_BUILD: &str = "b99f876b74d4a77f03af5f878223b27bd647b5c35a79d5decd9f716504239e93";
pub(super) const WIDTH: u32 = 2560;
pub(super) const HEIGHT: u32 = 1440;
const SDR_MODE: u32 = 0x0615_c100;
const STOCK_SDR_MODE: &str = "abfb5438d8153b6a0b8d08f33f4f0066e5383925b55aacc5f669131f3f51d4cf";
const LEGACY_UI_WIDTH: u32 = 3840;
const LEGACY_UI_HEIGHT: u32 = 2160;
/// The UI memory pool's size in the UI setup at `0x247AD10`: `mov ecx,
/// 0x4000000`, the Series X value (Series S: `0x5200000`, picked by
/// `cmovne` on the title's Series S check).
const UI_POOL: u32 = 0x0247_ad4a;
const TEMPORAL_SCALE: u32 = 0x028f_1e7e;
/// The legacy UI flag from the console preset: `mov al, [rdi+0x1e8]`, then
/// stored to the flag (`mov [rsi+0x13c], al`).
const LEGACY_UI_PRESET: u32 = 0x01e0_fb69;
const STOCK_LEGACY_UI_PRESET: &str = "79b808935d64ed64f88414b9bb8f696c996005b2ce05e5a81ac93b3c6218f739";
/// The settings update storing the flag again: `mov [rsi+0x13c], r8b`.
const LEGACY_UI_FLAG_STORE: u32 = 0x0261_92f9;
const STOCK_LEGACY_UI_FLAG_STORE: &str = "edaab24aa453924381dd65cfc5724a1e254c071d1894f738ddb20dd6f7d8e809";

/// Bytes of one 64 KiB-aligned, 64 KiB-tiled RGBA8 UI surface.
fn ui_surface_bytes(width: u32, height: u32) -> Result<u64> {
    let texture = Texture::new(&TextureDesc {
        dimension: Dimension::Tex2d,
        width,
        height,
        depth_or_array: 1,
        mips: 1,
        format: 28,
        samples: 1,
        swizzle: Swizzle::SW_64KB_D_X,
    })
    .map_err(|error| anyhow::anyhow!("UI surface layout ({width}x{height}): {error:?}"))?;
    Ok(texture.size.next_multiple_of(64 * 1024))
}

/// Patches `image` for a 2560x1440 output; the scene is drawn at 2560x1440,
/// or at 1920x1080 with `render_1080p`. Returns the scene's size.
pub(super) fn prepare(image: &mut PreparedImage, render_1080p: bool) -> Result<(u32, u32)> {
    ensure!(
        image.original_hash.to_hex().as_str() == RETAIL_BUILD,
        "1440p output is only known for the retail build {RETAIL_BUILD}"
    );

    let mode = field::<16>(image, SDR_MODE)?;
    ensure!(same(&mode[..], STOCK_SDR_MODE), "unexpected Series X SDR mode");
    mode[..4].copy_from_slice(&WIDTH.to_le_bytes());
    mode[4..8].copy_from_slice(&HEIGHT.to_le_bytes());

    // With the legacy UI flag set, the UI setup makes two 3840x2160 legacy
    // UI surfaces and two 2560x1440 UI targets in one pool, and asserts that
    // no more than 0x1FFFFF of it is left over (`0x247AF25`). Rounded to
    // 2 MiB: 0x5E00000 (94 MiB). The stock Series X 64 MiB had no room for
    // the legacy surfaces (the title's allocator asserted, `int3` at
    // `0x56A2AFD`).
    let pool_size = u32::try_from(
        (ui_surface_bytes(LEGACY_UI_WIDTH, LEGACY_UI_HEIGHT)? * 2 + ui_surface_bytes(WIDTH, HEIGHT)? * 2)
            .next_multiple_of(2 << 20),
    )?;
    let pool = field::<5>(image, UI_POOL)?;
    ensure!(*pool == [0xb9, 0, 0, 0, 4], "unexpected Series X UI pool size");
    pool[1..].copy_from_slice(&pool_size.to_le_bytes());

    // The legacy UI flag set on Series X too: the preset's byte loads as 1
    // (`mov al, 1`), and the settings update stores 1 (`mov byte [rsi+0x13c],
    // 1`). The rest of the preset stays Series X.
    let preset = field::<6>(image, LEGACY_UI_PRESET)?;
    ensure!(same(&preset[..], STOCK_LEGACY_UI_PRESET), "unexpected legacy UI preset load");
    *preset = [0xb0, 0x01, 0x90, 0x90, 0x90, 0x90];
    let store = field::<7>(image, LEGACY_UI_FLAG_STORE)?;
    ensure!(same(&store[..], STOCK_LEGACY_UI_FLAG_STORE), "unexpected legacy UI flag store");
    *store = [0xc6, 0x86, 0x3c, 0x01, 0x00, 0x00, 0x01];

    let scale = field::<4>(image, TEMPORAL_SCALE)?;
    ensure!(*scale == (2.0f32 / 3.0).to_le_bytes(), "unexpected Series X temporal scene scale");
    let (render_width, render_height) = if render_1080p { (1920, 1080) } else { (WIDTH, HEIGHT) };
    *scale = (render_width as f32 / WIDTH as f32).to_le_bytes();
    // The Settings preview panels' viewport (`0x58048D4`) loads the legacy
    // UI size, which is right with the legacy flag set: left stock.
    Ok((render_width, render_height))
}

/// The title's renderer selection: `mov eax, 6; cmovne eax, ecx` (the
/// title's own temporal pass, or on Series S with the upscaler there the
/// FidelityFX path, 7).
const RENDERER_SELECTION: u32 = 0x007e_9421;
const STOCK_RENDERER_SELECTION: &str = "f0633abf37df17124108b1e37be64645bd4b2412b0524c2f89334f22bd948464";
/// The FidelityFX path's render size: the console check's result (Series S)
/// is noted as the FidelityFX quality mode and picks the scaled branch
/// (`movzx eax, al; mov [r14+0x90], eax; test al, al; jne`), whose scale
/// multiplies the output size.
const UPSCALER_SIZING: u32 = 0x028e_f69a;
const STOCK_UPSCALER_SIZING: &str = "2ae2ac102d12ca003cb218413ef018e4dba68fc2003654a30c1743e13a820ffd";
/// The native branch's load of 1.0, and the scaled branch's of the scale.
const NATIVE_LOAD: u32 = 0x028e_f6a8;
const STOCK_NATIVE_LOAD: &str = "2579c24601d173b086a8136edf54ffd82720e6bf186f9139274bb09a45ddadf5";
const SCALED_LOAD: u32 = 0x028e_f6b2;
const STOCK_SCALED_LOAD: &str = "e218882c95d2e16163a409d55b3451519414eb87c4d6220785dc09852d4e14f4";
/// The scale the scaled branch loads (shared with other code: not written).
const UPSCALER_SCALE: u32 = 0x0615_d95c;

/// Makes the title render through its FidelityFX upscaler path (renderer 7,
/// as Series S does) with the scene at `mode`'s scale of the output, so that
/// DLSS can take its upscale dispatches over (`victory_hle::modules::fidelityfx`).
/// On Series X the stock title uses its own temporal pass instead and never
/// loads its upscaler. The FidelityFX quality mode the title notes is
/// `mode`'s; the temporal scene scale (the title's own pass, and
/// `prepare`'s 1440p patch) is set to the same scale, as the stock Series X
/// image pairs them (2/3 each). Every patched instruction is checked against
/// the stock bytes first; nothing is written if one differs.
///
/// From DexNom's fork (DexNom/VIctory, `apps/victory/src/native_1440p.rs`,
/// `prepare_fsr_4k`, GPL-3.0-or-later), there for a 4K output; kept here
/// with the 1440p one.
pub(super) fn prepare_upscaler(image: &mut PreparedImage, mode: Mode) -> Result<()> {
    ensure!(
        image.original_hash.to_hex().as_str() == RETAIL_BUILD,
        "the upscaler path is only known for the retail build {RETAIL_BUILD}"
    );
    ensure!(same(&field::<8>(image, RENDERER_SELECTION)?[..], STOCK_RENDERER_SELECTION), "unexpected renderer selection");
    ensure!(same(&field::<14>(image, UPSCALER_SIZING)?[..], STOCK_UPSCALER_SIZING), "unexpected upscaler render size selection");
    ensure!(same(&field::<10>(image, NATIVE_LOAD)?[..], STOCK_NATIVE_LOAD), "unexpected upscaler native scale load");
    ensure!(same(&field::<8>(image, SCALED_LOAD)?[..], STOCK_SCALED_LOAD), "unexpected upscaler scaled load");
    ensure!(*field::<4>(image, UPSCALER_SCALE)? == (2.0f32 / 3.0).to_le_bytes(), "unexpected upscaler scale");
    let temporal = f32::from_le_bytes(*field::<4>(image, TEMPORAL_SCALE)?);
    ensure!(
        temporal == 2.0 / 3.0 || temporal == 1.0,
        "unexpected temporal scene scale {temporal} (stock 2/3, or 1 with the 1440p output)"
    );
    // Renderer 7 every time it is asked (the console check has run).
    *field::<8>(image, RENDERER_SELECTION)? = [0xb8, 7, 0, 0, 0, 0x90, 0x90, 0x90];
    // `mov eax, mode; mov [r14+0x90], eax; jmp scaled`.
    *field::<14>(image, UPSCALER_SIZING)? = [0xb8, mode.ffx_mode(), 0, 0, 0, 0x41, 0x89, 0x86, 0x90, 0, 0, 0, 0xeb, 0x0a];
    if mode != Mode::Quality {
        // The jump leaves the native branch unreached: its load's operand
        // becomes a literal of ours, which the scaled branch loads.
        let literal = NATIVE_LOAD + 4;
        *field::<4>(image, literal)? = mode.scale().to_le_bytes();
        let displacement = literal as i32 - (SCALED_LOAD as i32 + 8);
        *field::<4>(image, SCALED_LOAD + 4)? = displacement.to_le_bytes();
    }
    *field::<4>(image, TEMPORAL_SCALE)? = mode.scale().to_le_bytes();
    Ok(())
}

fn field<const N: usize>(image: &mut PreparedImage, rva: u32) -> Result<&mut [u8; N]> {
    let offset = image.info.rva_to_file_offset(rva).context("display profile field missing")? as usize;
    image
        .bytes
        .get_mut(offset..offset + N)
        .context("incomplete display profile field")?
        .try_into()
        .context("invalid display profile field length")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// With the retail executable named by `VICTORY_DISPLAY_PROFILE_TEST_IMAGE`
    /// (not part of the repository): the four fields hold what a 1440p
    /// output needs, for both scene sizes; without it, nothing is checked.
    #[test]
    fn patches_the_retail_image_for_1440p() {
        let Some(path) = std::env::var_os("VICTORY_DISPLAY_PROFILE_TEST_IMAGE") else {
            return;
        };
        let bytes = std::fs::read(path).unwrap();
        for (render_1080p, scene) in [(false, (2560, 1440)), (true, (1920, 1080))] {
            let mut image = victory_loader::prepare(&bytes).unwrap();
            assert_eq!(prepare(&mut image, render_1080p).unwrap(), scene);
            let mode = *field::<16>(&mut image, SDR_MODE).unwrap();
            assert_eq!(mode[..4], WIDTH.to_le_bytes());
            assert_eq!(mode[4..8], HEIGHT.to_le_bytes());
            let scale = f32::from_le_bytes(*field::<4>(&mut image, TEMPORAL_SCALE).unwrap());
            assert_eq!((WIDTH as f32 * scale) as u32, scene.0);
            // The UI pool holds two legacy surfaces and two 1440p targets.
            assert_eq!(*field::<5>(&mut image, UI_POOL).unwrap(), [0xb9, 0x00, 0x00, 0xe0, 0x05]);
            // The legacy UI flag is set from the preset and by the update.
            assert_eq!(*field::<6>(&mut image, LEGACY_UI_PRESET).unwrap(), [0xb0, 0x01, 0x90, 0x90, 0x90, 0x90]);
            assert_eq!(
                *field::<7>(&mut image, LEGACY_UI_FLAG_STORE).unwrap(),
                [0xc6, 0x86, 0x3c, 0x01, 0x00, 0x00, 0x01]
            );
            // Patched once, the image is no longer the stock one: refused.
            assert!(prepare(&mut image, render_1080p).is_err());
        }
    }

    /// With the retail executable (as above): the upscaler path at each
    /// scale, alone (4K output) and after the 1440p patch; the scaled
    /// branch then loads the mode's scale and the noted mode is its
    /// FidelityFX mode.
    #[test]
    fn patches_the_upscaler_path() {
        let Some(path) = std::env::var_os("VICTORY_DISPLAY_PROFILE_TEST_IMAGE") else {
            return;
        };
        let bytes = std::fs::read(path).unwrap();
        for native in [false, true] {
            for mode in [Mode::Dlaa, Mode::Quality, Mode::Balanced, Mode::Performance, Mode::UltraPerformance] {
                let mut image = victory_loader::prepare(&bytes).unwrap();
                if native {
                    prepare(&mut image, false).unwrap();
                }
                prepare_upscaler(&mut image, mode).unwrap();
                assert_eq!(*field::<8>(&mut image, RENDERER_SELECTION).unwrap(), [0xb8, 7, 0, 0, 0, 0x90, 0x90, 0x90]);
                let sizing = *field::<14>(&mut image, UPSCALER_SIZING).unwrap();
                assert_eq!(sizing[1], mode.ffx_mode());
                assert_eq!(sizing[12..], [0xeb, 0x0a]);
                // The jump lands on the scaled load.
                assert_eq!(UPSCALER_SIZING + 14 + 0x0a, SCALED_LOAD);
                let disp = i32::from_le_bytes(*field::<4>(&mut image, SCALED_LOAD + 4).unwrap());
                let loaded = (SCALED_LOAD + 8).wrapping_add_signed(disp);
                assert_eq!(f32::from_le_bytes(*field::<4>(&mut image, loaded).unwrap()), mode.scale());
                assert_eq!(f32::from_le_bytes(*field::<4>(&mut image, TEMPORAL_SCALE).unwrap()), mode.scale());
                // The shared constant stays as it was.
                assert_eq!(*field::<4>(&mut image, UPSCALER_SCALE).unwrap(), (2.0f32 / 3.0).to_le_bytes());
                // Patched once, refused.
                assert!(prepare_upscaler(&mut image, mode).is_err());
            }
        }
    }
}
