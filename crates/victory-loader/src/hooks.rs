//! Opt-in compatibility hooks for known title builds.
//!
//! Only per-build offsets and short byte signatures live here (clean-room policy:
//! nothing of the title itself). Every hook checks the build's hash and the
//! exact bytes it replaces, and does nothing otherwise.

use crate::frame_rate::Patched;
use crate::resolution::{Site, write};

/// First 16 hex digits of the BLAKE3 of the 1.0.2.1 title executable.
const BUILD_1_0_2_1: &str = "b99f876b74d4a77f";

/// Environment variable that turns the watchdog hook on.
pub(crate) const NO_WATCHDOG_ENV: &str = "VICTORY_NO_WATCHDOG";

/// Whether `VICTORY_NO_WATCHDOG` asks to disarm the title's hang watchdog
/// (`VICTORY_NO_WATCHDOG=1`; unset or `0` leaves it untouched).
pub(crate) fn watchdog_requested(value: Option<&std::ffi::OsStr>) -> bool {
    value.is_some_and(|v| v != "0")
}

struct WatchdogSite {
    site: Site,
    replacement: &'static [u8],
}

/// The title's watchdog thread ends the process on purpose when its main
/// thread has not advanced for about 30 one-second ticks. Two places do it:
/// the handler it calls (`mov dword ptr [0], imm32`) and, when the handler
/// returns or is unset, a fallback right after the call (`mov dword ptr [0],
/// 0; int3`). Jumping over the whole block returns the loop to its normal
/// path; the first patch makes the handler harmless if something else calls it.
const WATCHDOG: &[WatchdogSite] = &[
    WatchdogSite {
        site: Site {
            at: 0x2215c27,
            what: "watchdog: skip the call and the fallback fault",
            // mov rax, [rip + disp32] (the handler pointer)
            bytes: &[0x48, 0x8B, 0x05, 0x1A, 0x07, 0xFA, 0x04],
        },
        // jmp +0x18 (to the loop's normal continuation), then NOPs
        replacement: &[0xEB, 0x18, 0x90, 0x90, 0x90, 0x90, 0x90],
    },
    WatchdogSite {
        site: Site {
            at: 0x23cf683,
            what: "watchdog: handler's deliberate fault",
            bytes: &[0xC7, 0x04, 0x25, 0, 0, 0, 0, 0x21, 0xD4, 0x8B, 0x4D],
        },
        // an eleven-byte NOP
        replacement: &[0x66, 0x66, 0x2E, 0x0F, 0x1F, 0x84, 0, 0, 0, 0, 0],
    },
];

/// Applies the watchdog patches whose bytes match. Returns how many applied.
///
/// # Safety
/// `base` is the mapped image of `size` bytes whose original BLAKE3 is `hash`,
/// and no title code is running yet.
pub(crate) unsafe fn disarm_watchdog(base: usize, size: usize, hash: &blake3::Hash) -> usize {
    if !hash.to_hex().starts_with(BUILD_1_0_2_1) {
        return 0;
    }
    WATCHDOG
        .iter()
        .filter(|entry| {
            // SAFETY: forwarded from this function's contract.
            let status = unsafe { write(base, size, &entry.site, entry.replacement) };
            match status {
                Patched::Done => {
                    tracing::info!(what = entry.site.what, "hook applied");
                    true
                }
                Patched::Differs => {
                    tracing::warn!(what = entry.site.what, "hook skipped: the bytes are not the expected ones");
                    false
                }
                Patched::Failed(why) => {
                    tracing::warn!(what = entry.site.what, why, "hook failed");
                    false
                }
            }
        })
        .count()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn watchdog_flag_parses_explicitly() {
        use std::ffi::OsStr;
        assert!(!watchdog_requested(None));
        assert!(!watchdog_requested(Some(OsStr::new("0"))));
        assert!(watchdog_requested(Some(OsStr::new("1"))));
    }

    #[test]
    fn watchdog_patches_preserve_instruction_lengths() {
        assert_eq!(WATCHDOG.len(), 2);
        for entry in WATCHDOG {
            assert!(!entry.site.bytes.is_empty());
            assert_eq!(entry.replacement.len(), entry.site.bytes.len());
        }
    }

    #[test]
    fn unknown_build_skips_watchdog_hooks() {
        let other = blake3::hash(b"other-build");
        // SAFETY: unknown hash returns before touching `base`.
        assert_eq!(unsafe { disarm_watchdog(0, 0, &other) }, 0);
    }
}
