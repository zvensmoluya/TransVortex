"""Extract alpha from images that contain a rendered checkerboard background.

This is a production-asset helper for generated frontend images. Some image
models draw a fake transparency checkerboard instead of returning a PNG with an
alpha channel. This script removes only checkerboard-colored pixels connected to
the image boundary, then writes a real RGBA PNG.
"""

from __future__ import annotations

import argparse
from collections import Counter, deque
from pathlib import Path

try:
    from PIL import Image, ImageFilter
except ImportError as exc:  # pragma: no cover - environment guard
    raise SystemExit(
        "Pillow is required. Install it with: python -m pip install pillow"
    ) from exc


RGB = tuple[int, int, int]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert fake checkerboard transparency into a real alpha PNG."
    )
    parser.add_argument("--input", required=True, help="Source PNG with fake checkerboard background.")
    parser.add_argument("--out", required=True, help="Output RGBA PNG path.")
    parser.add_argument(
        "--tolerance",
        type=int,
        default=18,
        help="RGB distance tolerance for checkerboard colors. Default: 18.",
    )
    parser.add_argument(
        "--sample-step",
        type=int,
        default=8,
        help="Pixel step for border color sampling. Default: 8.",
    )
    parser.add_argument(
        "--edge-contract",
        type=int,
        default=1,
        help="Grow the removed background by this many pixels. Default: 1.",
    )
    parser.add_argument(
        "--edge-feather",
        type=float,
        default=0.5,
        help="Feather alpha edge radius in pixels. Default: 0.5.",
    )
    return parser.parse_args()


def rgb_distance(a: RGB, b: RGB) -> int:
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]), abs(a[2] - b[2]))


def quantize(color: RGB, bucket: int = 8) -> RGB:
    return tuple((channel // bucket) * bucket for channel in color)  # type: ignore[return-value]


def sample_border_colors(image: Image.Image, step: int) -> list[RGB]:
    rgb = image.convert("RGB")
    width, height = rgb.size
    pixels = rgb.load()
    colors: list[RGB] = []

    for x in range(0, width, step):
        colors.append(pixels[x, 0])
        colors.append(pixels[x, height - 1])
    for y in range(0, height, step):
        colors.append(pixels[0, y])
        colors.append(pixels[width - 1, y])

    counts = Counter(quantize(color) for color in colors)
    return [color for color, _count in counts.most_common(4)]


def is_background(color: RGB, background_colors: list[RGB], tolerance: int) -> bool:
    return any(rgb_distance(color, bg) <= tolerance for bg in background_colors)


def flood_boundary_background(
    image: Image.Image, background_colors: list[RGB], tolerance: int
) -> Image.Image:
    rgb = image.convert("RGB")
    width, height = rgb.size
    pixels = rgb.load()
    visited = bytearray(width * height)
    queue: deque[tuple[int, int]] = deque()

    def index(x: int, y: int) -> int:
        return y * width + x

    def enqueue_if_background(x: int, y: int) -> None:
        i = index(x, y)
        if visited[i]:
            return
        visited[i] = 1
        if is_background(pixels[x, y], background_colors, tolerance):
            queue.append((x, y))

    for x in range(width):
        enqueue_if_background(x, 0)
        enqueue_if_background(x, height - 1)
    for y in range(height):
        enqueue_if_background(0, y)
        enqueue_if_background(width - 1, y)

    background = Image.new("L", (width, height), 0)
    background_pixels = background.load()

    while queue:
        x, y = queue.popleft()
        background_pixels[x, y] = 255
        for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if nx < 0 or ny < 0 or nx >= width or ny >= height:
                continue
            i = index(nx, ny)
            if visited[i]:
                continue
            visited[i] = 1
            if is_background(pixels[nx, ny], background_colors, tolerance):
                queue.append((nx, ny))

    return background


def make_alpha(background_mask: Image.Image, edge_contract: int, edge_feather: float) -> Image.Image:
    mask = background_mask
    if edge_contract > 0:
        mask = mask.filter(ImageFilter.MaxFilter(edge_contract * 2 + 1))

    alpha = Image.eval(mask, lambda value: 255 - value)
    if edge_feather > 0:
        alpha = alpha.filter(ImageFilter.GaussianBlur(edge_feather))
    return alpha


def main() -> int:
    args = parse_args()
    source = Path(args.input)
    out = Path(args.out)

    image = Image.open(source).convert("RGBA")
    background_colors = sample_border_colors(image, args.sample_step)
    background = flood_boundary_background(image, background_colors, args.tolerance)
    alpha = make_alpha(background, args.edge_contract, args.edge_feather)

    result = image.copy()
    result.putalpha(alpha)
    out.parent.mkdir(parents=True, exist_ok=True)
    result.save(out)

    print(f"Wrote {out}")
    print(f"Detected checkerboard colors: {background_colors}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
