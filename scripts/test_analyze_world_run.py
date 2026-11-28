#!/usr/bin/env python3
"""Unit tests for `scripts/analyze-world-run.py`."""

from __future__ import annotations

import importlib.util
import pathlib
import struct
import sys
import tempfile
import unittest
import zlib

SCRIPT_PATH = pathlib.Path(__file__).with_name("analyze-world-run.py")
SPEC = importlib.util.spec_from_file_location("analyze_world_run", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
MOD = importlib.util.module_from_spec(SPEC)
sys.modules["analyze_world_run"] = MOD
SPEC.loader.exec_module(MOD)


def _write_rgb_png(path: pathlib.Path, w: int, h: int, rows: bytearray) -> None:
    def chunk(kind: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(kind + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    idat = zlib.compress(bytes(rows), level=3)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b""))


def make_textured_world_png(path: pathlib.Path, dark: bool = False, flat: bool = False, magenta: bool = False) -> None:
    w, h = 320, 180
    rows = bytearray()
    for y in range(h):
        rows.append(0)
        for x in range(w):
            if magenta:
                r, g, b = 255, 0, 255
            elif flat:
                r, g, b = 90, 90, 90
            elif dark:
                r, g, b = (25, 25, 28) if (20 <= x <= 40 and 20 <= y <= 40) else (2, 2, 3)
            else:
                bx, by = (x // 4) * 4, (y // 4) * 4
                detail = ((x * 29 + y * 17) & 31)
                r = 60 + ((bx * 7 + by * 11) % 120) + detail
                g = 70 + ((bx * 3 + by * 13) % 110) + detail
                b = 65 + ((bx * 11 + by * 5) % 120) + detail
            rows.extend((r, g, b))
    _write_rgb_png(path, w, h, rows)


HEALTHY_LOG = """\
2026-11-28T03:00:00.000000Z INFO victory_gpu::tiles: host copies of title textures take the card's memory level by level (VICTORY_LEVELS_ON_DEMAND=1) tier=4 on=true floor_kb=256 all=true max_dim=2048
2026-11-28T03:00:01.000000Z INFO victory_gpu::host: 30.0 fps, 33.3 ms/frame (0.2 preparing: copies 0.0 ms 0.0 MB, textures 0.0 ms 0.0 MB; 0.0 on the GPU; 0.0 copying back 0.0 MB), 5 draws/frame, dropped 0 without a host pipeline (0 being made) and 0 indirect (0 of all these left out on purpose); heap buffers 0.0 passes 0.0 ms; textures picked by index: 100 uploaded so far (10 MB), 0 waiting, 0 passed over unmapped
2026-11-28T03:00:10.000000Z INFO victory_gpu::capture: the first frame of 500 draws or more: frames 202 and 206 are captured frame=200
2026-11-28T03:00:15.000000Z INFO victory_gpu::host: 24.5 fps, 40.8 ms/frame (8.1 preparing: copies 1.5 ms 10.0 MB, textures 1.2 ms 12.0 MB; 28.0 on the GPU; 2.1 copying back 1.0 MB), 3200 draws/frame, dropped 2 without a host pipeline (0 being made) and 0 indirect (0 of all these left out on purpose); heap buffers 1.0 passes 1.0 ms; textures picked by index: 4000 uploaded so far (900 MB), 120 waiting, 10 passed over unmapped
2026-11-28T03:00:16.000000Z INFO victory_gpu::resource: card accounting: room true, the card 5400 MB in use of a budget of 6904 MB; host copies of textures the title fills: 5000 alive 1500 MB, of which 100 MB are levels whose title memory is not mapped (10 copies with such a level); title textures without a host copy: 100 never had one, 200 had one let go; of the host copies 1200 are made level by level and hold 450 MB of tiles
2026-11-28T03:00:17.000000Z INFO victory_gpu::host: new card memory waited for until it is mapped (VICTORY_WAIT_RESIDENT=0: not), since the start: 120 times, 45.0 ms, the longest 2.1 ms
2026-11-28T03:00:20.000000Z INFO victory_gpu::host: 25.1 fps, 39.8 ms/frame (7.8 preparing: copies 1.4 ms 9.5 MB, textures 1.1 ms 10.0 MB; 27.1 on the GPU; 2.0 copying back 1.0 MB), 3400 draws/frame, dropped 1 without a host pipeline (0 being made) and 0 indirect (0 of all these left out on purpose); heap buffers 1.0 passes 1.0 ms; textures picked by index: 4200 uploaded so far (940 MB), 80 waiting, 10 passed over unmapped
2026-11-28T03:00:25.000000Z INFO victory_gpu::host: 25.4 fps, 39.4 ms/frame (7.5 preparing: copies 1.2 ms 9.0 MB, textures 1.0 ms 9.0 MB; 26.8 on the GPU; 1.9 copying back 1.0 MB), 3500 draws/frame, dropped 0 without a host pipeline (0 being made) and 0 indirect (0 of all these left out on purpose); heap buffers 1.0 passes 1.0 ms; textures picked by index: 4300 uploaded so far (960 MB), 60 waiting, 10 passed over unmapped
2026-11-28T03:00:26.000000Z INFO victory_gpu::resource: card accounting: room true, the card 5450 MB in use of a budget of 6904 MB; host copies of textures the title fills: 5100 alive 1520 MB, of which 90 MB are levels whose title memory is not mapped (10 copies with such a level); title textures without a host copy: 100 never had one, 200 had one let go; of the host copies 1250 are made level by level and hold 460 MB of tiles
2026-11-28T03:00:27.000000Z INFO victory_gpu::host: new card memory waited for until it is mapped (VICTORY_WAIT_RESIDENT=0: not), since the start: 130 times, 52.0 ms, the longest 2.1 ms
"""


class AnalyzeWorldRunTests(unittest.TestCase):
    def test_healthy_run_passes_all_gates(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            log = root / "err.log"
            frames = root / "frames"
            frames.mkdir()
            log.write_text(HEALTHY_LOG, encoding="utf-8")
            # Pre-world frame should be ignored cleanly even if dark.
            make_textured_world_png(frames / "frame-16.png", dark=True)
            make_textured_world_png(frames / "frame-206.png")
            make_textured_world_png(frames / "frame-230.png")

            summary = MOD.analyze_run(log, frames_dir=frames, expect_levels_on_demand=True)
            self.assertTrue(summary["ok"], summary["checks"])
            self.assertEqual(summary["performance"]["world_windows"], 3)
            self.assertEqual(summary["vram"]["levels_on_demand_alive_max"], 1250)
            self.assertEqual(summary["visuals"]["world_png_count"], 2)

    def test_catches_over_vram_waiting_textures_zero_tiled_and_mapped_stalls(self) -> None:
        broken_log = """\
2026-11-28T03:00:00.000000Z INFO victory_gpu::tiles: host copies of title textures take the card's memory level by level (VICTORY_LEVELS_ON_DEMAND=1) tier=4 on=true floor_kb=256 all=true max_dim=2048
2026-11-28T03:00:10.000000Z INFO victory_gpu::host: 5.5 fps, 181.0 ms/frame (40.0 preparing: copies 10.0 ms 40.0 MB, textures 2.0 ms 10.0 MB; 100.0 on the GPU; 35.0 copying back 5.0 MB), 4500 draws/frame, dropped 120 without a host pipeline (0 being made) and 0 indirect (0 of all these left out on purpose); heap buffers 1.0 passes 2.0 ms; textures picked by index: 65000 uploaded so far (20000 MB), 15000 waiting, 18000 passed over unmapped
2026-11-28T03:00:11.000000Z INFO victory_gpu::resource: card accounting: room false, the card 8000 MB in use of a budget of 6904 MB; host copies of textures the title fills: 7600 alive 3450 MB, of which 2550 MB are levels whose title memory is not mapped (2100 copies); of the host copies 0 are made level by level and hold 0 MB of tiles
2026-11-28T03:00:12.000000Z INFO victory_gpu::host: new card memory waited for until it is mapped (VICTORY_WAIT_RESIDENT=0: not), since the start: 10000 times, 10000.0 ms, the longest 500.0 ms
2026-11-28T03:00:15.000000Z INFO victory_gpu::host: 5.8 fps, 172.0 ms/frame (38.0 preparing: copies 10.0 ms 40.0 MB, textures 2.0 ms 10.0 MB; 98.0 on the GPU; 34.0 copying back 5.0 MB), 4600 draws/frame, dropped 115 without a host pipeline (0 being made) and 0 indirect (0 of all these left out on purpose); heap buffers 1.0 passes 2.0 ms; textures picked by index: 65100 uploaded so far (20010 MB), 14000 waiting, 18100 passed over unmapped
2026-11-28T03:00:20.000000Z INFO victory_gpu::host: 6.0 fps, 166.0 ms/frame (36.0 preparing: copies 10.0 ms 40.0 MB, textures 2.0 ms 10.0 MB; 95.0 on the GPU; 33.0 copying back 5.0 MB), 4700 draws/frame, dropped 110 without a host pipeline (0 being made) and 0 indirect (0 of all these left out on purpose); heap buffers 1.0 passes 2.0 ms; textures picked by index: 65200 uploaded so far (20020 MB), 13500 waiting, 18200 passed over unmapped
2026-11-28T03:00:22.000000Z INFO victory_gpu::host: new card memory waited for until it is mapped (VICTORY_WAIT_RESIDENT=0: not), since the start: 12500 times, 14000.0 ms, the longest 500.0 ms
"""
        with tempfile.TemporaryDirectory() as tmp:
            log = pathlib.Path(tmp) / "err.log"
            log.write_text(broken_log, encoding="utf-8")
            summary = MOD.analyze_run(log, allow_no_frames=True)
            self.assertFalse(summary["ok"])
            failed = {c["name"] for c in summary["checks"] if not c["ok"]}
            self.assertIn("VRAM within card budget", failed)
            self.assertIn("Texture streaming healthy", failed)
            self.assertIn("Residency stalls bounded", failed)

    def test_catches_visual_dark_flat_and_magenta_frames(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            log = root / "err.log"
            log.write_text(HEALTHY_LOG, encoding="utf-8")
            for mode in ("dark", "flat", "magenta"):
                fdir = root / mode
                fdir.mkdir()
                make_textured_world_png(
                    fdir / "frame-206.png",
                    dark=(mode == "dark"),
                    flat=(mode == "flat"),
                    magenta=(mode == "magenta"),
                )
                summary = MOD.analyze_run(log, frames_dir=fdir)
                self.assertFalse(summary["ok"], f"{mode} frame should fail visual check")
                failed = {c["name"] for c in summary["checks"] if not c["ok"]}
                self.assertIn("Visual lighting & texture detail", failed)

    def test_ab_comparison_catches_fps_vram_and_lighting_regressions(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            log_a = root / "a.log"
            frames_a = root / "frames_a"
            frames_a.mkdir()
            log_a.write_text(HEALTHY_LOG, encoding="utf-8")
            make_textured_world_png(frames_a / "frame-206.png")
            baseline = MOD.analyze_run(log_a, frames_dir=frames_a)

            # Build B drops FPS to 15, pushes VRAM +400 MB, and goes flat/dark.
            log_b = root / "b.log"
            frames_b = root / "frames_b"
            frames_b.mkdir()
            regressed = (
                HEALTHY_LOG.replace("25.1 fps", "15.0 fps")
                .replace("25.4 fps", "15.2 fps")
                .replace("24.5 fps", "14.8 fps")
                .replace("5450 MB", "5850 MB")
            )
            log_b.write_text(regressed, encoding="utf-8")
            make_textured_world_png(frames_b / "frame-206.png", flat=True)
            current = MOD.analyze_run(log_b, frames_dir=frames_b, baseline=baseline)
            self.assertFalse(current["ok"])
            failed = {c["name"] for c in current["checks"] if not c["ok"]}
            self.assertIn("A/B FPS non-regression", failed)
            self.assertIn("A/B VRAM non-regression", failed)
            self.assertIn("A/B Lighting/detail non-regression", failed)


if __name__ == "__main__":
    unittest.main()
