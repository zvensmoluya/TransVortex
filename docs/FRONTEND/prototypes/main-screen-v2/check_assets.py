#!/usr/bin/env python3
"""Validate generated PNG assets for the main-screen-v2 prototype."""

from __future__ import annotations

import argparse
import struct
import sys
import zlib
from pathlib import Path


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def parse_png(path: Path) -> tuple[int, int, int, int, bytes]:
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError("not a PNG file")

    pos = len(PNG_SIGNATURE)
    width = height = bit_depth = color_type = None
    idat_chunks: list[bytes] = []

    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        chunk_type = data[pos + 4 : pos + 8]
        chunk_start = pos + 8
        chunk_end = chunk_start + length
        crc_end = chunk_end + 4
        if crc_end > len(data):
            raise ValueError("truncated PNG chunk")

        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type = struct.unpack(
                ">IIBB", data[chunk_start : chunk_start + 10]
            )
        elif chunk_type == b"IDAT":
            idat_chunks.append(data[chunk_start:chunk_end])
        elif chunk_type == b"IEND":
            break

        pos = crc_end

    if None in (width, height, bit_depth, color_type):
        raise ValueError("missing IHDR")
    if not idat_chunks:
        raise ValueError("missing IDAT")

    return width, height, bit_depth, color_type, zlib.decompress(b"".join(idat_chunks))


def pixel_alpha_samples(
    raw: bytes, width: int, height: int, bit_depth: int, color_type: int
) -> list[int]:
    if bit_depth != 8:
        raise ValueError(f"unsupported bit depth: {bit_depth}")

    channels_by_type = {4: 2, 6: 4}
    channels = channels_by_type.get(color_type)
    if channels is None:
        return []

    stride = width * channels
    rows: list[bytes] = []
    pos = 0
    previous = bytearray(stride)

    for _ in range(height):
        filter_type = raw[pos]
        pos += 1
        row = bytearray(raw[pos : pos + stride])
        pos += stride
        recon = bytearray(stride)
        bpp = channels

        for i, value in enumerate(row):
            left = recon[i - bpp] if i >= bpp else 0
            up = previous[i]
            upper_left = previous[i - bpp] if i >= bpp else 0
            if filter_type == 0:
                recon[i] = value
            elif filter_type == 1:
                recon[i] = (value + left) & 0xFF
            elif filter_type == 2:
                recon[i] = (value + up) & 0xFF
            elif filter_type == 3:
                recon[i] = (value + ((left + up) // 2)) & 0xFF
            elif filter_type == 4:
                predictor = paeth(left, up, upper_left)
                recon[i] = (value + predictor) & 0xFF
            else:
                raise ValueError(f"unsupported filter type: {filter_type}")

        rows.append(bytes(recon))
        previous = recon

    points = [
        (0, 0),
        (width - 1, 0),
        (0, height - 1),
        (width - 1, height - 1),
        (width // 2, 0),
        (width // 2, height - 1),
        (0, height // 2),
        (width - 1, height // 2),
    ]
    return [rows[y][x * channels + channels - 1] for x, y in points]


def paeth(left: int, up: int, upper_left: int) -> int:
    p = left + up - upper_left
    pa = abs(p - left)
    pb = abs(p - up)
    pc = abs(p - upper_left)
    if pa <= pb and pa <= pc:
        return left
    if pb <= pc:
        return up
    return upper_left


def validate(path: Path) -> tuple[bool, str]:
    try:
        width, height, bit_depth, color_type, raw = parse_png(path)
        has_alpha = color_type in (4, 6)
        if not has_alpha:
            return False, f"{width}x{height}, color_type={color_type}, no alpha channel"

        samples = pixel_alpha_samples(raw, width, height, bit_depth, color_type)
        transparent_samples = sum(1 for alpha in samples if alpha == 0)
        if transparent_samples < 4:
            return (
                False,
                f"{width}x{height}, alpha channel exists, but edges are not transparent",
            )

        return True, f"{width}x{height}, alpha channel present, transparent edges OK"
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", help="PNG file or directory to validate")
    args = parser.parse_args()

    target = Path(args.path)
    paths = sorted(target.glob("*.png")) if target.is_dir() else [target]
    if not paths:
        print(f"No PNG files found: {target}", file=sys.stderr)
        return 1

    failed = False
    for path in paths:
        ok, message = validate(path)
        status = "PASS" if ok else "FAIL"
        print(f"{status} {path}: {message}")
        failed = failed or not ok

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())

