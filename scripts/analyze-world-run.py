#!/usr/bin/env python3
"""End-to-end in-world log + screenshot analyzer and A/B regression gate.

Parses runtime logs from 3D world execution (`draws/frame >= 500`), inspects
captured PNG screenshots under `VICTORY_CAPTURE`, verifies stability, VRAM,
texture streaming, residency stalls, and visual lighting/detail thresholds, and
optionally compares against a baseline `summary.json`.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime
import json
from pathlib import Path
import re
import statistics
import struct
import sys
from typing import Any
import zlib

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
TS_PREFIX_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)\s+(.*)$")

FPS_RE = re.compile(
    r"([\d.]+)\s+fps,\s*([\d.]+)\s+ms/frame\s*"
    r"\(([\d.]+)\s+preparing:.*?;\s*([\d.]+)\s+on the GPU;\s*([\d.]+)\s+copying back\s+[\d.]+\s+MB\),\s*"
    r"(\d+)\s+draws/frame,\s*dropped\s+(\d+)\s+without a host pipeline.*?"
    r"textures picked by index:\s*(\d+)\s+uploaded so far\s+\([\d.]+\s+MB\),\s*(\d+)\s+waiting,\s*(\d+)\s+passed over unmapped"
)

ACCOUNTING_RE = re.compile(
    r"card accounting:\s+room\s+(true|false),\s+the card\s+(\d+)\s+MB in use of a budget of\s+(\d+)\s+MB;\s*"
    r"host copies of textures the title fills:\s+\d+\s+alive\s+\d+\s+MB,\s+"
    r"of which\s+(\d+)\s+MB are levels whose title memory is not mapped.*?"
    r"of the host copies\s+(\d+)\s+are made level by level and hold\s+(\d+)\s+MB of tiles"
)

TILES_STATUS_RE = re.compile(
    r"textures with levels on demand:\s+(\d+)\s+alive\s+\((\d+)\s+made so far\),\s*(\d+)\s+MB of the card"
)

LEVELS_ENABLED_RE = re.compile(
    r"host copies of title textures take the card's memory level by level.*?\bon=(true|false)\b"
)

MAPPED_WAIT_RE = re.compile(
    r"new card memory waited for until it is mapped.*?since the start:\s*(\d+)\s+times,\s*([\d.]+)\s+ms,\s*the longest\s+([\d.]+)\s+ms"
)

RESIDENT_WAIT_RE = re.compile(
    r"new memory waited for\s+\(VICTORY_WAIT_RESIDENT=0:\s+not\),\s+since the start:\s*(\d+)\s+times,\s*([\d.]+)\s+ms,\s*the longest\s+([\d.]+)\s+ms"
)

WORLD_FRAME_CAPTURE_RE = re.compile(
    r"the first frame of 500 draws or more:.*?frames\s+(\d+)\s+and\s+(\d+)\s+are captured"
)
WORLD_FRAME_FIELD_RE = re.compile(
    r"the first frame of 500 draws or more:.*\bframe=(\d+)\b"
)

GPU_DETILE_RE = re.compile(
    r"gpu detile:\s*(\d+)\s+uploads.*?card ring full\s+(\d+).*?verify:\s*(\d+)\s+checked,\s*(\d+)\s+differed"
)

CRASH_RE = re.compile(r"0xc0000005|unhandled exception|DeviceRemoved|DXGI_ERROR_DEVICE|panicked at")
NO_HOST_TEXTURE_RE = re.compile(r"no host texture")
UNTRANSLATED_RE = re.compile(r"shader does not translate")
AMBIENT_ACTIVE_RE = re.compile(r"victory_gpu::ambient:.*?\b(\d+)\s+frames,\s*(\d+)\s+dispatches")
FRAME_PNG_RE = re.compile(r"^frame-(\d+)\.png$", re.IGNORECASE)


@dataclass
class LogEntry:
    ts: datetime | None
    text: str


def parse_ts(raw: str) -> datetime | None:
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None


def load_entries(paths: list[Path]) -> list[LogEntry]:
    entries: list[LogEntry] = []
    for path in paths:
        if not path.is_file():
            continue
        raw_lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        cur_ts: datetime | None = None
        cur_parts: list[str] = []
        for raw in raw_lines:
            line = ANSI_RE.sub("", raw).strip()
            if not line:
                continue
            m = TS_PREFIX_RE.match(line)
            if m:
                if cur_parts:
                    entries.append(LogEntry(cur_ts, re.sub(r"\s+", " ", " ".join(cur_parts))))
                cur_ts = parse_ts(m.group(1))
                cur_parts = [m.group(2)]
            else:
                cur_parts.append(line)
        if cur_parts:
            entries.append(LogEntry(cur_ts, re.sub(r"\s+", " ", " ".join(cur_parts))))
    return entries


def percentile(values: list[float], q: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = (len(ordered) - 1) * q
    lo = int(idx)
    hi = min(lo + 1, len(ordered) - 1)
    frac = idx - lo
    return ordered[lo] * (1.0 - frac) + ordered[hi] * frac


def _paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def read_png_rgb(path: Path) -> tuple[int, int, bytes]:
    """Decode an 8-bit RGB (type 2) or RGBA (type 6) PNG using stdlib only."""
    blob = path.read_bytes()
    if not blob.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError(f"{path} is not a PNG file")
    pos = 8
    w = h = bit_depth = color_type = 0
    idat_parts: list[bytes] = []
    while pos + 8 <= len(blob):
        length = struct.unpack(">I", blob[pos:pos + 4])[0]
        kind = blob[pos + 4:pos + 8]
        data = blob[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            w, h, bit_depth, color_type, comp, filt, interlace = struct.unpack(">IIBBBBB", data)
            if bit_depth != 8 or color_type not in (2, 6) or comp != 0 or filt != 0 or interlace != 0:
                raise ValueError(
                    f"{path}: unsupported PNG format depth={bit_depth} type={color_type} interlace={interlace}"
                )
        elif kind == b"IDAT":
            idat_parts.append(data)
        elif kind == b"IEND":
            break

    if w == 0 or h == 0:
        return (w, h, b"")

    bpp = 3 if color_type == 2 else 4
    stride = w * bpp
    raw = zlib.decompress(b"".join(idat_parts))
    prev = bytearray(stride)
    rgb = bytearray(w * h * 3)
    src = 0
    for y in range(h):
        ftype = raw[src]
        src += 1
        row = bytearray(raw[src:src + stride])
        src += stride
        if ftype == 1:
            for i in range(bpp, stride):
                row[i] = (row[i] + row[i - bpp]) & 0xFF
        elif ftype == 2:
            for i in range(stride):
                row[i] = (row[i] + prev[i]) & 0xFF
        elif ftype == 3:
            for i in range(stride):
                left = row[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:
            for i in range(stride):
                a = row[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + _paeth(a, b, c)) & 0xFF
        elif ftype != 0:
            raise ValueError(f"{path}: unsupported PNG filter {ftype}")
        prev = row
        dst_base = y * w * 3
        if bpp == 3:
            rgb[dst_base:dst_base + w * 3] = row
        else:
            for x in range(w):
                s_off = x * 4
                d_off = dst_base + x * 3
                rgb[d_off:d_off + 3] = row[s_off:s_off + 3]
    return (w, h, bytes(rgb))


def analyze_png(path: Path) -> dict[str, Any]:
    orig_w, orig_h, data = read_png_rgb(path)
    if orig_w == 0 or orig_h == 0:
        return {
            "path": str(path),
            "width": orig_w,
            "height": orig_h,
            "mean_luma": 0.0,
            "p10_luma": 0.0,
            "p50_luma": 0.0,
            "p95_luma": 0.0,
            "near_black_pct": 100.0,
            "near_white_pct": 0.0,
            "edge_energy": 0.0,
            "mean_saturation": 0.0,
            "magenta_pct": 0.0,
            "cyan_pct": 0.0,
        }

    # Subsample deterministically to at most ~480px wide for fast analysis.
    step = max(1, (orig_w + 479) // 480)
    w = (orig_w + step - 1) // step
    h = (orig_h + step - 1) // step
    total_pixels = w * h
    orig_stride = orig_w * 3

    lumas: list[float] = []
    luma_sum = 0.0
    near_black = 0
    near_white = 0
    sat_sum = 0.0
    magenta = 0
    cyan = 0
    edge_sum = 0
    edge_count = 0

    for sy in range(h):
        y = sy * step
        row_off = y * orig_stride
        up_off = (y - step) * orig_stride if sy > 0 else 0
        for sx in range(w):
            x = sx * step
            off = row_off + x * 3
            r = data[off]
            g = data[off + 1]
            b = data[off + 2]
            luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            lumas.append(luma)
            luma_sum += luma
            if luma < 8.0:
                near_black += 1
            if luma > 250.0:
                near_white += 1
            mx = r if r >= g and r >= b else (g if g >= b else b)
            mn = r if r <= g and r <= b else (g if g <= b else b)
            sat_sum += (mx - mn) / max(1, mx)
            if r > 240 and g < 15 and b > 240:
                magenta += 1
            if r < 15 and g > 240 and b > 240:
                cyan += 1
            if sx > 0:
                poff = off - step * 3
                edge_sum += abs(r - data[poff]) + abs(g - data[poff + 1]) + abs(b - data[poff + 2])
                edge_count += 3
            if sy > 0:
                uoff = up_off + x * 3
                edge_sum += abs(r - data[uoff]) + abs(g - data[uoff + 1]) + abs(b - data[uoff + 2])
                edge_count += 3

    return {
        "path": str(path),
        "width": orig_w,
        "height": orig_h,
        "mean_luma": round(luma_sum / total_pixels, 2),
        "p10_luma": round(percentile(lumas, 0.10), 2),
        "p50_luma": round(percentile(lumas, 0.50), 2),
        "p95_luma": round(percentile(lumas, 0.95), 2),
        "near_black_pct": round(near_black * 100.0 / total_pixels, 2),
        "near_white_pct": round(near_white * 100.0 / total_pixels, 2),
        "edge_energy": round(edge_sum / max(1, edge_count), 2),
        "mean_saturation": round(sat_sum / total_pixels, 3),
        "magenta_pct": round(magenta * 100.0 / total_pixels, 3),
        "cyan_pct": round(cyan * 100.0 / total_pixels, 3),
    }


def compute_stall_rate(
    samples: list[tuple[datetime | None, int, float, float]],
    first_world_ts: datetime | None,
) -> dict[str, Any]:
    if not samples:
        return {
            "total_calls": 0,
            "total_ms": 0.0,
            "longest_ms": 0.0,
            "world_rate_ms_per_sec": 0.0,
            "world_rate_calls_per_sec": 0.0,
            "world_samples": 0,
        }
    last_calls, last_ms, last_longest = samples[-1][1], samples[-1][2], samples[-1][3]
    in_world = [
        s for s in samples
        if first_world_ts is None or s[0] is None or s[0] >= first_world_ts
    ]
    pre_world = [
        s for s in samples
        if first_world_ts is not None and s[0] is not None and s[0] < first_world_ts
    ]
    rate_ms = 0.0
    rate_calls = 0.0
    if len(in_world) >= 2 and in_world[0][0] is not None and in_world[-1][0] is not None:
        dt = (in_world[-1][0] - in_world[0][0]).total_seconds()
        if dt > 0.0:
            rate_ms = max(0.0, in_world[-1][2] - in_world[0][2]) / dt
            rate_calls = max(0, in_world[-1][1] - in_world[0][1]) / dt
    elif len(in_world) == 1 and pre_world and in_world[0][0] is not None and pre_world[-1][0] is not None:
        dt = (in_world[0][0] - pre_world[-1][0]).total_seconds()
        if dt > 0.0:
            rate_ms = max(0.0, in_world[0][2] - pre_world[-1][2]) / dt
            rate_calls = max(0, in_world[0][1] - pre_world[-1][1]) / dt
    elif len(in_world) == 1 and samples[0][0] is None:
        rate_ms = in_world[0][2]
        rate_calls = float(in_world[0][1])

    return {
        "total_calls": last_calls,
        "total_ms": round(last_ms, 1),
        "longest_ms": round(last_longest, 1),
        "world_rate_ms_per_sec": round(rate_ms, 2),
        "world_rate_calls_per_sec": round(rate_calls, 2),
        "world_samples": len(in_world),
    }


def analyze_run(
    log_path: Path,
    stdout_path: Path | None = None,
    frames_dir: Path | None = None,
    expect_levels_on_demand: bool = False,
    allow_no_frames: bool = False,
    baseline: dict[str, Any] | None = None,
) -> dict[str, Any]:
    paths = [log_path]
    if stdout_path is not None:
        paths.append(stdout_path)
    entries = load_entries(paths)

    fps_windows: list[dict[str, Any]] = []
    accounting_raw: list[tuple[datetime | None, dict[str, Any]]] = []
    tiles_status_raw: list[tuple[datetime | None, int, int, int]] = []
    mapped_samples: list[tuple[datetime | None, int, float, float]] = []
    resident_samples: list[tuple[datetime | None, int, float, float]] = []
    levels_on_demand_requested = expect_levels_on_demand
    first_world_frame: int | None = None
    crashes = 0
    no_host_texture_errors = 0
    untranslated_shaders = 0
    ambient_specular_active = False
    gpu_detile: dict[str, int] | None = None

    for idx, entry in enumerate(entries):
        text = entry.text
        if CRASH_RE.search(text):
            crashes += 1
        if NO_HOST_TEXTURE_RE.search(text):
            no_host_texture_errors += 1
        if UNTRANSLATED_RE.search(text):
            untranslated_shaders += 1

        if m := AMBIENT_ACTIVE_RE.search(text):
            if int(m.group(1)) > 0 or int(m.group(2)) > 0:
                ambient_specular_active = True

        if m := LEVELS_ENABLED_RE.search(text):
            if m.group(1) == "true":
                levels_on_demand_requested = True

        if first_world_frame is None:
            if m := WORLD_FRAME_FIELD_RE.search(text):
                first_world_frame = int(m.group(1))
            elif m := WORLD_FRAME_CAPTURE_RE.search(text):
                first_world_frame = max(0, int(m.group(1)) - 2)

        if m := FPS_RE.search(text):
            fps_windows.append({
                "idx": idx,
                "ts": entry.ts,
                "fps": float(m.group(1)),
                "frame_ms": float(m.group(2)),
                "preparing_ms": float(m.group(3)),
                "gpu_ms": float(m.group(4)),
                "copyback_ms": float(m.group(5)),
                "draws": int(m.group(6)),
                "dropped_no_pipeline": int(m.group(7)),
                "uploaded_textures": int(m.group(8)),
                "waiting_textures": int(m.group(9)),
                "unmapped_textures": int(m.group(10)),
            })

        if m := ACCOUNTING_RE.search(text):
            used_mb = int(m.group(2))
            budget_mb = int(m.group(3))
            accounting_raw.append((
                entry.ts,
                {
                    "room": m.group(1) == "true",
                    "used_mb": used_mb,
                    "budget_mb": budget_mb,
                    "over_budget_mb": max(0, used_mb - budget_mb),
                    "unmapped_mips_mb": int(m.group(4)),
                    "by_level_n": int(m.group(5)),
                    "by_level_mb": int(m.group(6)),
                },
            ))

        if m := TILES_STATUS_RE.search(text):
            tiles_status_raw.append((entry.ts, int(m.group(1)), int(m.group(2)), int(m.group(3))))

        if m := MAPPED_WAIT_RE.search(text):
            mapped_samples.append((entry.ts, int(m.group(1)), float(m.group(2)), float(m.group(3))))

        if m := RESIDENT_WAIT_RE.search(text):
            resident_samples.append((entry.ts, int(m.group(1)), float(m.group(2)), float(m.group(3))))

        if m := GPU_DETILE_RE.search(text):
            gpu_detile = {
                "uploads": int(m.group(1)),
                "card_ring_full": int(m.group(2)),
                "verify_checked": int(m.group(3)),
                "verify_differed": int(m.group(4)),
            }

    world_windows = [w for w in fps_windows if w["draws"] >= 500]
    first_world_ts = world_windows[0]["ts"] if world_windows else None
    first_world_idx = world_windows[0]["idx"] if world_windows else None

    if world_windows:
        fps_vals = [w["fps"] for w in world_windows]
        frame_ms_vals = [w["frame_ms"] for w in world_windows]
        prep_ms_vals = [w["preparing_ms"] for w in world_windows]
        gpu_ms_vals = [w["gpu_ms"] for w in world_windows]
        cb_ms_vals = [w["copyback_ms"] for w in world_windows]
        dropped_vals = [w["dropped_no_pipeline"] for w in world_windows]
        waiting_vals = [w["waiting_textures"] for w in world_windows]
        perf = {
            "world_windows": len(world_windows),
            "max_draws": max(w["draws"] for w in world_windows),
            "median_fps": round(statistics.median(fps_vals), 2),
            "mean_fps": round(statistics.fmean(fps_vals), 2),
            "min_fps": round(min(fps_vals), 2),
            "p10_fps": round(percentile(fps_vals, 0.10), 2),
            "median_frame_ms": round(statistics.median(frame_ms_vals), 2),
            "median_preparing_ms": round(statistics.median(prep_ms_vals), 2),
            "median_gpu_ms": round(statistics.median(gpu_ms_vals), 2),
            "median_copyback_ms": round(statistics.median(cb_ms_vals), 2),
            "median_dropped_no_pipeline": round(statistics.median(dropped_vals), 1),
            "max_dropped_no_pipeline": max(dropped_vals),
            "final_uploaded_textures": world_windows[-1]["uploaded_textures"],
            "final_waiting_textures": world_windows[-1]["waiting_textures"],
            "max_waiting_textures": max(waiting_vals),
        }
    else:
        perf = {
            "world_windows": 0,
            "max_draws": max((w["draws"] for w in fps_windows), default=0),
            "median_fps": 0.0,
            "mean_fps": 0.0,
            "min_fps": 0.0,
            "p10_fps": 0.0,
            "median_frame_ms": 0.0,
            "median_preparing_ms": 0.0,
            "median_gpu_ms": 0.0,
            "median_copyback_ms": 0.0,
            "median_dropped_no_pipeline": 0.0,
            "max_dropped_no_pipeline": 0,
            "final_uploaded_textures": fps_windows[-1]["uploaded_textures"] if fps_windows else 0,
            "final_waiting_textures": fps_windows[-1]["waiting_textures"] if fps_windows else 0,
            "max_waiting_textures": max((w["waiting_textures"] for w in fps_windows), default=0),
        }

    if first_world_idx is None:
        in_world_acct: list[dict[str, Any]] = []
        in_world_tiles: list[tuple[int, int, int]] = []
    else:
        in_world_acct = [
            a for ts, a in accounting_raw
            if first_world_ts is None or ts is None or ts >= first_world_ts
        ]
        in_world_tiles = [
            (alive, made, mb) for ts, alive, made, mb in tiles_status_raw
            if first_world_ts is None or ts is None or ts >= first_world_ts
        ]

    tiles_alive_max = max(
        [a["by_level_n"] for a in in_world_acct] + [t[0] for t in in_world_tiles] + [0]
    )
    tiles_mb_max = max(
        [a["by_level_mb"] for a in in_world_acct] + [t[2] for t in in_world_tiles] + [0]
    )

    if in_world_acct:
        room_false_count = sum(1 for a in in_world_acct if not a["room"])
        vram = {
            "samples": len(in_world_acct),
            "budget_mb_min": min(a["budget_mb"] for a in in_world_acct),
            "used_mb_max": max(a["used_mb"] for a in in_world_acct),
            "used_mb_median": round(statistics.median(a["used_mb"] for a in in_world_acct), 1),
            "max_over_budget_mb": max(a["over_budget_mb"] for a in in_world_acct),
            "room_false_count": room_false_count,
            "room_false_ratio": round(room_false_count / len(in_world_acct), 3),
            "unmapped_mips_mb_max": max(a["unmapped_mips_mb"] for a in in_world_acct),
            "unmapped_mips_mb_median": round(
                statistics.median(a["unmapped_mips_mb"] for a in in_world_acct), 1
            ),
            "levels_on_demand_requested": levels_on_demand_requested,
            "levels_on_demand_alive_max": tiles_alive_max,
            "levels_on_demand_tiles_mb_max": tiles_mb_max,
        }
    else:
        vram = {
            "samples": 0,
            "budget_mb_min": 0,
            "used_mb_max": 0,
            "used_mb_median": 0.0,
            "max_over_budget_mb": 0,
            "room_false_count": 0,
            "room_false_ratio": 0.0,
            "unmapped_mips_mb_max": 0,
            "unmapped_mips_mb_median": 0.0,
            "levels_on_demand_requested": levels_on_demand_requested,
            "levels_on_demand_alive_max": tiles_alive_max,
            "levels_on_demand_tiles_mb_max": tiles_mb_max,
        }

    stalls = {
        "mapped": compute_stall_rate(mapped_samples, first_world_ts),
        "resident": compute_stall_rate(resident_samples, first_world_ts),
    }

    frame_metrics: list[dict[str, Any]] = []
    if frames_dir is not None and frames_dir.is_dir():
        candidates: list[tuple[int, Path]] = []
        for entry in frames_dir.iterdir():
            if not entry.is_file():
                continue
            m = FRAME_PNG_RE.match(entry.name)
            if not m:
                continue
            num = int(m.group(1))
            if first_world_frame is not None and num < first_world_frame:
                continue
            candidates.append((num, entry))
        candidates.sort(key=lambda item: item[0])
        for num, path in candidates:
            info = analyze_png(path)
            info["frame"] = num
            frame_metrics.append(info)

    if frame_metrics:
        visuals = {
            "world_png_count": len(frame_metrics),
            "median_mean_luma": round(statistics.median(f["mean_luma"] for f in frame_metrics), 2),
            "best_mean_luma": max(f["mean_luma"] for f in frame_metrics),
            "median_near_black_pct": round(statistics.median(f["near_black_pct"] for f in frame_metrics), 2),
            "median_edge_energy": round(statistics.median(f["edge_energy"] for f in frame_metrics), 2),
            "best_edge_energy": max(f["edge_energy"] for f in frame_metrics),
            "median_saturation": round(statistics.median(f["mean_saturation"] for f in frame_metrics), 3),
            "max_magenta_pct": max(f["magenta_pct"] for f in frame_metrics),
            "max_cyan_pct": max(f["cyan_pct"] for f in frame_metrics),
            "frames": frame_metrics,
        }
    else:
        visuals = {
            "world_png_count": 0,
            "median_mean_luma": 0.0,
            "best_mean_luma": 0.0,
            "median_near_black_pct": 100.0,
            "median_edge_energy": 0.0,
            "best_edge_energy": 0.0,
            "median_saturation": 0.0,
            "max_magenta_pct": 0.0,
            "max_cyan_pct": 0.0,
            "frames": [],
        }

    checks: list[dict[str, Any]] = []

    def add_check(name: str, ok: bool, detail: str) -> None:
        checks.append({"name": name, "ok": bool(ok), "detail": detail})

    add_check(
        "Reached real 3D world",
        perf["world_windows"] >= 3 and perf["max_draws"] >= 500,
        f"world_windows={perf['world_windows']}, max_draws={perf['max_draws']}",
    )
    add_check(
        "Zero crashes / DRED / panics",
        crashes == 0 and no_host_texture_errors == 0,
        f"crashes={crashes}, no_host_texture_errors={no_host_texture_errors}, untranslated={untranslated_shaders}",
    )

    if vram["samples"] > 0:
        add_check(
            "VRAM within card budget",
            vram["max_over_budget_mb"] <= 128 and vram["room_false_ratio"] < 0.80,
            f"used_max={vram['used_mb_max']} MB, budget_min={vram['budget_mb_min']} MB, "
            f"over={vram['max_over_budget_mb']} MB, room_false={vram['room_false_ratio']:.1%}",
        )
    else:
        add_check("VRAM within card budget", False, "no in-world card accounting samples recorded")

    waiting_ok = perf["final_waiting_textures"] < 5000 and (
        perf["max_waiting_textures"] < 10000
        or perf["final_waiting_textures"] < 0.5 * perf["max_waiting_textures"]
    )
    lod_ok = (not levels_on_demand_requested) or (tiles_alive_max > 0)
    add_check(
        "Texture streaming healthy",
        waiting_ok and lod_ok,
        f"final_waiting={perf['final_waiting_textures']}, max_waiting={perf['max_waiting_textures']}, "
        f"levels_on_demand_requested={levels_on_demand_requested}, levels_on_demand_alive={tiles_alive_max}",
    )

    mapped_rate = stalls["mapped"]["world_rate_ms_per_sec"]
    add_check(
        "Residency stalls bounded",
        mapped_rate <= 50.0,
        f"mapped_rate={mapped_rate} ms/world_sec (total {stalls['mapped']['total_calls']} calls, "
        f"{stalls['mapped']['total_ms']} ms, longest {stalls['mapped']['longest_ms']} ms)",
    )

    if not allow_no_frames:
        vis_ok = (
            visuals["world_png_count"] >= 1
            and visuals["median_mean_luma"] >= 15.0
            and visuals["median_near_black_pct"] <= 70.0
            and visuals["median_edge_energy"] >= 6.0
            and visuals["max_magenta_pct"] < 1.0
        )
        add_check(
            "Visual lighting & texture detail",
            vis_ok,
            f"pngs={visuals['world_png_count']}, luma={visuals['median_mean_luma']}, "
            f"near_black={visuals['median_near_black_pct']}%, edge_energy={visuals['median_edge_energy']}, "
            f"magenta={visuals['max_magenta_pct']}%",
        )

    ab_deltas: dict[str, Any] = {}
    if baseline is not None:
        b_perf = baseline.get("performance", {})
        b_vram = baseline.get("vram", {})
        b_vis = baseline.get("visuals", {})

        b_fps = float(b_perf.get("median_fps", 0.0))
        add_check(
            "A/B FPS non-regression",
            perf["median_fps"] >= b_fps * 0.90,
            f"current={perf['median_fps']} fps vs baseline={b_fps} fps",
        )

        b_used = int(b_vram.get("used_mb_max", 0))
        if b_used > 0 and vram["samples"] > 0:
            add_check(
                "A/B VRAM non-regression",
                vram["used_mb_max"] <= b_used + 256,
                f"current={vram['used_mb_max']} MB vs baseline={b_used} MB",
            )

        b_wait = int(b_perf.get("final_waiting_textures", 0))
        add_check(
            "A/B Waiting textures non-regression",
            perf["final_waiting_textures"] <= b_wait + 500,
            f"current={perf['final_waiting_textures']} vs baseline={b_wait}",
        )

        b_drop = float(b_perf.get("median_dropped_no_pipeline", 0.0))
        add_check(
            "A/B Pipeline drops non-regression",
            perf["median_dropped_no_pipeline"] <= b_drop + 10.0,
            f"current={perf['median_dropped_no_pipeline']} vs baseline={b_drop}",
        )

        if not allow_no_frames and b_vis.get("world_png_count", 0) > 0 and visuals["world_png_count"] > 0:
            b_luma = float(b_vis.get("median_mean_luma", 0.0))
            b_edge = float(b_vis.get("median_edge_energy", 0.0))
            add_check(
                "A/B Lighting/detail non-regression",
                visuals["median_mean_luma"] >= b_luma * 0.75 and visuals["median_edge_energy"] >= b_edge * 0.80,
                f"luma {visuals['median_mean_luma']} vs {b_luma}; edge_energy {visuals['median_edge_energy']} vs {b_edge}",
            )

        ab_deltas = {
            "fps_delta": round(perf["median_fps"] - b_fps, 2),
            "vram_max_delta_mb": vram["used_mb_max"] - b_used,
            "waiting_delta": perf["final_waiting_textures"] - b_wait,
            "luma_delta": round(visuals["median_mean_luma"] - float(b_vis.get("median_mean_luma", 0.0)), 2),
            "edge_energy_delta": round(visuals["median_edge_energy"] - float(b_vis.get("median_edge_energy", 0.0)), 2),
        }

    overall_ok = all(c["ok"] for c in checks)
    return {
        "ok": overall_ok,
        "log": str(log_path),
        "first_world_frame": first_world_frame,
        "performance": perf,
        "vram": vram,
        "stalls": stalls,
        "stability": {
            "crashes": crashes,
            "no_host_texture_errors": no_host_texture_errors,
            "untranslated_shaders": untranslated_shaders,
            "ambient_specular_active": ambient_specular_active,
            "gpu_detile": gpu_detile,
        },
        "visuals": visuals,
        "checks": checks,
        "ab_deltas": ab_deltas,
    }


def format_markdown(summary: dict[str, Any], baseline: dict[str, Any] | None = None) -> str:
    p = summary["performance"]
    v = summary["vram"]
    s = summary["stalls"]
    vis = summary["visuals"]
    lines = [
        f"## In-World Verification Summary ({'PASS' if summary['ok'] else 'FAIL'})",
        "",
        "### Gates",
    ]
    for c in summary["checks"]:
        tag = "PASS" if c["ok"] else "FAIL"
        lines.append(f"- **[{tag}] {c['name']}** — {c['detail']}")

    lines.extend([
        "",
        "### Key Telemetry (In-World `draws >= 500`)",
        f"- **FPS / Frame Time:** median `{p['median_fps']} fps` (`{p['median_frame_ms']} ms`), min `{p['min_fps']} fps`, max draws `{p['max_draws']}` across `{p['world_windows']}` windows",
        f"- **Breakdown:** preparing `{p['median_preparing_ms']} ms`, GPU `{p['median_gpu_ms']} ms`, copyback `{p['median_copyback_ms']} ms`",
        f"- **VRAM:** max `{v['used_mb_max']} MB` / budget min `{v['budget_mb_min']} MB` (`over={v['max_over_budget_mb']} MB`, `room=false` `{v['room_false_ratio']:.1%}`), unmapped mips median `{v['unmapped_mips_mb_median']} MB`, tiled alive max `{v['levels_on_demand_alive_max']}` (`{v['levels_on_demand_tiles_mb_max']} MB`)",
        f"- **Texture Queue:** uploaded `{p['final_uploaded_textures']}`, final waiting `{p['final_waiting_textures']}`, max waiting `{p['max_waiting_textures']}`",
        f"- **Residency Stalls:** `mapped()` rate `{s['mapped']['world_rate_ms_per_sec']} ms/s` (`{s['mapped']['total_calls']}` calls, `{s['mapped']['total_ms']} ms` total, max `{s['mapped']['longest_ms']} ms`)",
        f"- **Visual PNGs ({vis['world_png_count']}):** median luma `{vis['median_mean_luma']}`, near-black `{vis['median_near_black_pct']}%`, edge energy `{vis['median_edge_energy']}`, max magenta `{vis['max_magenta_pct']}%`",
    ])
    if baseline is not None and summary.get("ab_deltas"):
        d = summary["ab_deltas"]
        lines.extend([
            "",
            "### A/B Delta vs Baseline",
            f"| Metric | Baseline | Current | Delta |",
            f"| --- | ---: | ---: | ---: |",
            f"| Median FPS | {baseline['performance']['median_fps']} | {p['median_fps']} | {d['fps_delta']:+.2f} |",
            f"| Max VRAM (MB) | {baseline['vram']['used_mb_max']} | {v['used_mb_max']} | {d['vram_max_delta_mb']:+d} |",
            f"| Waiting Textures | {baseline['performance']['final_waiting_textures']} | {p['final_waiting_textures']} | {d['waiting_delta']:+d} |",
            f"| Median Luma | {baseline['visuals']['median_mean_luma']} | {vis['median_mean_luma']} | {d['luma_delta']:+.2f} |",
            f"| Median Edge Energy | {baseline['visuals']['median_edge_energy']} | {vis['median_edge_energy']} | {d['edge_energy_delta']:+.2f} |",
        ])
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True, type=Path, help="Path to stderr log")
    parser.add_argument("--stdout", type=Path, default=None, help="Optional stdout log")
    parser.add_argument("--frames-dir", type=Path, default=None, help="Directory with frame-*.png captures")
    parser.add_argument("--expect-levels-on-demand", action="store_true", help="Require tiled textures > 0")
    parser.add_argument("--allow-no-frames", action="store_true", help="Skip screenshot visual gates when inspecting logs only")
    parser.add_argument("--baseline", type=Path, default=None, help="Optional baseline summary.json for A/B gating")
    parser.add_argument("--out-json", type=Path, default=None, help="Write JSON summary to this path")
    parser.add_argument("--out-md", type=Path, default=None, help="Write Markdown report to this path")
    args = parser.parse_args(argv)

    baseline_data = None
    if args.baseline is not None:
        baseline_data = json.loads(args.baseline.read_text(encoding="utf-8"))

    summary = analyze_run(
        log_path=args.log,
        stdout_path=args.stdout,
        frames_dir=args.frames_dir,
        expect_levels_on_demand=args.expect_levels_on_demand,
        allow_no_frames=args.allow_no_frames,
        baseline=baseline_data,
    )

    md = format_markdown(summary, baseline_data)
    print(md)

    if args.out_json is not None:
        args.out_json.parent.mkdir(parents=True, exist_ok=True)
        args.out_json.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    if args.out_md is not None:
        args.out_md.parent.mkdir(parents=True, exist_ok=True)
        args.out_md.write_text(md, encoding="utf-8")

    return 0 if summary["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
