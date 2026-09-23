#!/usr/bin/env python3
"""Procedural texture generator for "Chase: Open World".

Every texture used by the Godot project is generated here, so the repository
contains no third party art: the assets are original, licence-free and
reproducible (`python3 tools/generate_textures.py`).

The generated files live in assets/textures/ and are committed to the repo;
GitHub Actions only *verifies* that they exist (see tools/validate_project.py).

Design notes
------------
* All textures tile perfectly (periodic noise + patterns whose period divides
  the image size), because the world is built from repeated materials.
* Road textures are "strips": X = across the road, Y = along the road, so a
  dashed centre line repeats automatically when the ribbon is UV mapped.
* Facade textures cover one 4 m x 3 m module (width x height) with one window,
  which keeps UV maths trivial: uv = (metres_x / 4, metres_y / 3).
"""

from __future__ import annotations

import argparse
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "textures")


# --------------------------------------------------------------------------- noise
def rng(seed: int) -> np.random.Generator:
    return np.random.default_rng(seed)


def lattice(size: int, cells: int, seed: int) -> np.ndarray:
    """Tileable value noise in [0, 1]."""
    cells = max(cells, 2)
    grid = rng(seed).random((cells, cells))
    t = np.arange(size) / size * cells
    i0 = np.floor(t).astype(int) % cells
    i1 = (i0 + 1) % cells
    f = t - np.floor(t)
    f = f * f * (3.0 - 2.0 * f)
    a = grid[np.ix_(i0, i0)]
    b = grid[np.ix_(i1, i0)]
    c = grid[np.ix_(i0, i1)]
    d = grid[np.ix_(i1, i1)]
    fx = f[:, None]
    fy = f[None, :]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def fbm(size: int, base_cells: int, octaves: int, seed: int, gain: float = 2.0, persistence: float = 0.5) -> np.ndarray:
    total = np.zeros((size, size))
    norm = 0.0
    amp = 1.0
    cells = float(base_cells)
    for o in range(octaves):
        total += amp * lattice(size, int(round(cells)), seed + o * 131)
        norm += amp
        amp *= persistence
        cells *= gain
    return total / max(norm, 1e-6)


def speckles(size: int, count: int, radius: float, seed: int, shape: tuple[int, int] | None = None) -> np.ndarray:
    """Random blobs, wrapped at the edges so the result stays tileable."""
    h, w = (size, size) if shape is None else shape
    img = Image.new("L", (w, h), 0)
    draw = ImageDraw.Draw(img)
    r = rng(seed)
    for _ in range(count):
        x = float(r.random() * w)
        y = float(r.random() * h)
        rr = float(radius * (0.5 + r.random()))
        for dx in (-w, 0, w):
            for dy in (-h, 0, h):
                draw.ellipse((x + dx - rr, y + dy - rr, x + dx + rr, y + dy + rr), fill=int(120 + 135 * r.random()))
    return np.asarray(img).astype(np.float32) / 255.0


def gradient(stops: list[tuple[float, tuple[int, int, int]]], values: np.ndarray) -> np.ndarray:
    """Maps a [0, 1] array onto a colour ramp -> (H, W, 3) uint8."""
    values = np.clip(values, 0.0, 1.0)
    out = np.zeros(values.shape + (3,), dtype=np.float32)
    for i in range(len(stops) - 1):
        t0, c0 = stops[i]
        t1, c1 = stops[i + 1]
        mask = (values >= t0) & (values <= t1)
        if not np.any(mask):
            continue
        f = (values[mask] - t0) / max(t1 - t0, 1e-6)
        for ch in range(3):
            out[..., ch][mask] = c0[ch] + (c1[ch] - c0[ch]) * f
    out[values <= stops[0][0]] = stops[0][1]
    out[values >= stops[-1][0]] = stops[-1][1]
    return out


def save(name: str, array: np.ndarray) -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    array = np.clip(array, 0, 255).astype(np.uint8)
    mode = "RGBA" if array.ndim == 3 and array.shape[2] == 4 else "RGB"
    Image.fromarray(array, mode).save(os.path.join(OUT_DIR, name), optimize=True)


def rgb(r, g, b):
    return (r, g, b)


def font(size: int) -> ImageFont.ImageFont:
    """Scaled bitmap font (Pillow >= 10.1 can size the built-in font)."""
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()


def draw_centred_text(draw, centre, text, fill, size):
    fnt = font(size)
    bbox = draw.textbbox((0, 0), text, font=fnt)
    draw.text((centre[0] - (bbox[2] - bbox[0]) / 2, centre[1] - (bbox[3] - bbox[1]) / 2 - bbox[1]), text, fill=fill, font=fnt)


def tint(base: np.ndarray, color_a, color_b, seed: int, strength: float = 1.0) -> np.ndarray:
    """Tints a grayscale [0,1] field between two colours with extra grain."""
    grain = (rng(seed).random(base.shape) - 0.5) * 14.0 * strength
    out = np.zeros(base.shape + (3,), dtype=np.float32)
    for ch in range(3):
        out[..., ch] = color_a[ch] + (color_b[ch] - color_a[ch]) * base + grain
    return out


def to_pil(array: np.ndarray) -> Image.Image:
    return Image.fromarray(np.clip(array, 0, 255).astype(np.uint8))


def from_pil(image: Image.Image) -> np.ndarray:
    return np.asarray(image).astype(np.float32)


# ----------------------------------------------------------------------- terrain
def terrain_textures() -> None:
    size = 512
    g1 = fbm(size, 4, 4, 11)
    g2 = fbm(size, 16, 3, 12)
    g3 = fbm(size, 64, 2, 13)
    blades = speckles(size, 900, 2.0, 21)
    stones = speckles(size, 90, 4.0, 22)

    grass = np.clip(g1 * 0.55 + g2 * 0.3 + blades * 0.28 + g3 * 0.12, 0, 1)
    save("terrain_grass.png", tint(grass, (54, 86, 44), (128, 158, 84), 31))

    dry = np.clip(g1 * 0.5 + g2 * 0.3 + blades * 0.2 + g3 * 0.2, 0, 1)
    save("terrain_grass_dry.png", tint(dry, (108, 106, 62), (176, 168, 108), 32))

    dirt = np.clip(g1 * 0.6 + g3 * 0.25 + stones * 0.35, 0, 1)
    save("terrain_dirt.png", tint(dirt, (78, 62, 44), (150, 126, 92), 33))

    ripples = 0.5 + 0.5 * np.sin(np.linspace(0, math.pi * 10, size))[None, :]
    sand = np.clip(g1 * 0.35 + g2 * 0.25 + ripples * 0.35 + g3 * 0.15, 0, 1)
    save("terrain_sand.png", tint(sand, (188, 164, 116), (232, 214, 170), 34))

    strata = (0.5 + 0.5 * np.sin(np.linspace(0, math.pi * 3, size)))[:, None]
    rock = np.clip(g1 * 0.4 + g2 * 0.3 + strata * 0.3 + g3 * 0.2, 0, 1)
    save("terrain_rock.png", tint(rock, (74, 72, 70), (162, 158, 152), 35))

    gravel = np.clip(g2 * 0.5 + stones * 0.6 + g3 * 0.3, 0, 1)
    save("terrain_gravel.png", tint(gravel, (92, 88, 84), (168, 164, 158), 36))


# ------------------------------------------------------------------------- roads
def _asphalt_base(size: int, seed: int, base: tuple[int, int, int]) -> np.ndarray:
    coarse = fbm(size, 8, 3, seed)
    fine = fbm(size, 64, 2, seed + 7)
    cracks = np.clip(fbm(size, 12, 2, seed + 15), 0, 1)
    patches = speckles(size, 10, 22.0, seed + 21)
    darkness = np.clip(coarse * 0.35 + fine * 0.35 + cracks * 0.2, 0, 1)
    out = tint(darkness, (base[0] * 0.80, base[1] * 0.80, base[2] * 0.82), (base[0] * 1.16, base[1] * 1.16, base[2] * 1.18), seed + 3)
    out *= (0.93 + 0.14 * patches)[..., None]
    return out


def _road_canvas(width: int = 512, height: int = 512) -> tuple[Image.Image, ImageDraw.ImageDraw]:
    img = Image.new("RGBA", (width, height))
    return img, ImageDraw.Draw(img)


def _draw_line(draw, x0, y0, x1, y1, color, width):
    draw.line((x0, y0, x1, y1), fill=color, width=int(width))


def _marking(img: Image.Image, draw: ImageDraw.ImageDraw, box, color, alpha=232):
    draw.rectangle(box, fill=color + (alpha,))


def road_textures() -> None:
    size = 512
    asphalt = _asphalt_base(size, 41, (74, 74, 78))

    # --- plain asphalt (intersections, driveways, parking entrances)
    save("road_asphalt_plain.png", asphalt)

    # --- city street, 13 m wide: dashed centre line + edge lines
    img = to_pil(asphalt.copy()).convert("RGBA")
    draw = ImageDraw.Draw(img)
    # edges: 13 m -> 512 px, so 1 m = 39.4 px
    ppm = size / 13.0
    _marking(img, draw, (int(0.35 * ppm), 0, int(0.55 * ppm), size), (238, 236, 226))
    _marking(img, draw, (int(size - 0.55 * ppm), 0, int(size - 0.35 * ppm), size), (238, 236, 226))
    dash = 5.0 * ppm
    gap = 3.0 * ppm
    y = 0.0
    while y < size:
        _marking(img, draw, (int(size / 2 - 0.14 * ppm), int(y), int(size / 2 + 0.14 * ppm), int(min(y + dash, size))), (240, 236, 214))
        y += dash + gap
    img = img.filter(ImageFilter.GaussianBlur(0.6))
    save("road_asphalt_city.png", from_pil(img.convert("RGB")))

    # --- avenue, 23 m wide: double yellow centre + lane dashes
    img = to_pil(asphalt.copy()).convert("RGBA")
    draw = ImageDraw.Draw(img)
    ppm = size / 23.0
    _marking(img, draw, (int(0.5 * ppm), 0, int(0.72 * ppm), size), (236, 234, 224))
    _marking(img, draw, (int(size - 0.72 * ppm), 0, int(size - 0.5 * ppm), size), (236, 234, 224))
    for cx in (size / 2 - 0.4 * ppm, size / 2 + 0.4 * ppm):
        _marking(img, draw, (int(cx - 0.12 * ppm), 0, int(cx + 0.12 * ppm), size), (228, 196, 74))
    dash = 4.5 * ppm
    gap = 3.5 * ppm
    for lane_x in (size * 0.27, size * 0.73):
        y = 0.0
        while y < size:
            _marking(img, draw, (int(lane_x - 0.11 * ppm), int(y), int(lane_x + 0.11 * ppm), int(min(y + dash, size))), (238, 234, 212))
            y += dash + gap
    img = img.filter(ImageFilter.GaussianBlur(0.6))
    save("road_asphalt_avenue.png", from_pil(img.convert("RGB")))

    # --- highway carriageway, 12 m = 3 lanes
    img = to_pil(asphalt.copy()).convert("RGBA")
    draw = ImageDraw.Draw(img)
    ppm = size / 12.0
    _marking(img, draw, (int(0.35 * ppm), 0, int(0.55 * ppm), size), (238, 236, 226))
    _marking(img, draw, (int(size - 0.55 * ppm), 0, int(size - 0.35 * ppm), size), (238, 236, 226))
    dash = 6.0 * ppm
    gap = 3.0 * ppm
    for lane_x in (size / 3.0, size * 2.0 / 3.0):
        y = 0.0
        while y < size:
            _marking(img, draw, (int(lane_x - 0.11 * ppm), int(y), int(lane_x + 0.11 * ppm), int(min(y + dash, size))), (240, 238, 218))
            y += dash + gap
    img = img.filter(ImageFilter.GaussianBlur(0.6))
    save("road_asphalt_highway.png", from_pil(img.convert("RGB")))

    # --- rural asphalt, 9 m, worn centre line, gravel edges
    img = to_pil(asphalt.copy()).convert("RGBA")
    draw = ImageDraw.Draw(img)
    ppm = size / 9.0
    dash = 4.0 * ppm
    gap = 4.0 * ppm
    y = 0.0
    while y < size:
        _marking(img, draw, (int(size / 2 - 0.1 * ppm), int(y), int(size / 2 + 0.1 * ppm), int(min(y + dash, size))), (214, 210, 196), 180)
        y += dash + gap
    edges = from_pil(img.convert("RGB"))
    gravel = tint(fbm(size, 48, 3, 77), (96, 92, 86), (168, 162, 152), 78)
    edge_px = int(0.9 * ppm)
    edges[:, :edge_px] = edges[:, :edge_px] * 0.45 + gravel[:, :edge_px] * 0.55
    edges[:, -edge_px:] = edges[:, -edge_px:] * 0.45 + gravel[:, -edge_px:] * 0.55
    save("road_asphalt_rural.png", edges)

    # --- dirt track with ruts
    dirt = tint(np.clip(fbm(size, 6, 4, 61) * 0.6 + fbm(size, 48, 2, 62) * 0.4, 0, 1), (96, 76, 54), (156, 132, 98), 63)
    ruts = np.zeros(size, dtype=np.float32)
    xs = np.arange(size)
    for centre in (size * 0.34, size * 0.66):
        ruts += np.exp(-((xs - centre) ** 2) / (2 * (14.0 ** 2)))
    ruts = np.clip(ruts, 0, 1)
    dirt = dirt * (1.0 - 0.3 * ruts)[None, :, None]
    pebbles = speckles(size, 260, 3.0, 64)
    dirt = dirt * (1.0 + 0.22 * pebbles)[..., None]
    save("road_dirt_track.png", dirt)

    # --- gravel road
    gravel2 = tint(np.clip(fbm(size, 10, 3, 71) * 0.5 + speckles(size, 700, 2.6, 72) * 0.7, 0, 1), (104, 100, 94), (176, 170, 160), 73)
    save("road_gravel_road.png", gravel2)


# ---------------------------------------------------------------------- surfaces
def surface_textures() -> None:
    size = 512
    # sidewalk: paving slabs (0.5 m grid, 8 x 8 slabs per tile = 4 m)
    img = to_pil(tint(fbm(size, 8, 3, 81), (150, 148, 142), (196, 194, 188), 82)).convert("RGB")
    draw = ImageDraw.Draw(img)
    step = size // 8
    for i in range(9):
        draw.line((i * step, 0, i * step, size), fill=(120, 118, 112), width=3)
        draw.line((0, i * step, size, i * step), fill=(120, 118, 112), width=3)
    stains = speckles(size, 60, 12.0, 83)
    arr = from_pil(img) * (1.0 - 0.16 * stains)[..., None]
    save("surface_sidewalk.png", arr)

    # concrete with expansion joints (2 m grid)
    img = to_pil(tint(fbm(size, 6, 3, 91), (158, 156, 150), (204, 202, 196), 92)).convert("RGB")
    draw = ImageDraw.Draw(img)
    step = size // 4
    for i in range(5):
        draw.line((i * step, 0, i * step, size), fill=(126, 124, 118), width=4)
        draw.line((0, i * step, size, i * step), fill=(126, 124, 118), width=4)
    arr = from_pil(img)
    crack = np.clip(fbm(size, 24, 2, 93), 0.55, 1.0)
    arr *= (0.82 + 0.18 * crack)[..., None]
    save("surface_concrete.png", arr)

    # plaza: light tiles in a checker pattern with diagonal accents
    arr = from_pil(to_pil(tint(fbm(size, 10, 3, 101), (176, 172, 164), (214, 210, 202), 102)).convert("RGB"))
    img = to_pil(arr).convert("RGB")
    draw = ImageDraw.Draw(img)
    step = size // 8
    for ix in range(8):
        for iy in range(8):
            if (ix + iy) % 2 == 0:
                draw.rectangle((ix * step + 3, iy * step + 3, (ix + 1) * step - 3, (iy + 1) * step - 3), fill=(196, 190, 180))
    for i in range(9):
        draw.line((i * step, 0, i * step, size), fill=(150, 146, 138), width=3)
        draw.line((0, i * step, size, i * step), fill=(150, 146, 138), width=3)
    save("surface_plaza.png", from_pil(img))

    # parking lot: asphalt + white bays (bays 2.5 m wide, 5 m long, tile = 10 m)
    arr = _asphalt_base(size, 111, (70, 70, 74)).copy()
    img = to_pil(arr).convert("RGBA")
    draw = ImageDraw.Draw(img)
    ppm = size / 10.0
    for i in range(4):
        x = i * 2.5 * ppm
        draw.rectangle((int(x), int(size * 0.42), int(x + 0.12 * ppm), size), fill=(238, 234, 220, 210))
    draw.rectangle((0, int(size * 0.42), size, int(size * 0.42 + 0.12 * ppm)), fill=(238, 234, 220, 210))
    save("surface_parking.png", from_pil(img.convert("RGB")))

    # curb stone strip (X = across, Y = along) - painted kerb blocks
    img = Image.new("RGB", (128, 512), (168, 166, 160))
    draw = ImageDraw.Draw(img)
    draw.rectangle((0, 0, 128, 40), fill=(198, 196, 190))
    for i in range(0, 512, 64):
        draw.line((0, i, 128, i), fill=(138, 136, 130), width=3)
    grain = (rng(121).random((512, 128)) - 0.5) * 16.0
    arr = from_pil(img) + grain[..., None]
    save("surface_curb.png", arr)


# ---------------------------------------------------------------------- facades
FACADE_W, FACADE_H = 512, 384  # one module = 4 m wide x 3 m tall


def _facade_base(kind: str, seed: int) -> np.ndarray:
    if kind.startswith("brick"):
        img = Image.new("RGB", (FACADE_W, FACADE_H))
        draw = ImageDraw.Draw(img)
        brick_h = 24
        brick_w = 64
        base = (132, 74, 58) if kind.endswith("a") else (108, 82, 70)
        r = rng(seed)
        for row in range(FACADE_H // brick_h):
            offset = 0 if row % 2 == 0 else brick_w // 2
            for col in range(-1, FACADE_W // brick_w + 1):
                x = col * brick_w + offset
                y = row * brick_h
                variation = 0.82 + 0.36 * r.random()
                color = tuple(min(255, int(c * variation)) for c in base)
                draw.rectangle((x + 2, y + 2, x + brick_w - 2, y + brick_h - 2), fill=color)
        arr = from_pil(img)
        grain = (rng(seed + 1).random((FACADE_H, FACADE_W)) - 0.5) * 18.0
        return np.clip(arr + grain[..., None], 0, 255)
    noise = fbm(FACADE_W, 5, 3, seed)[:FACADE_H, :]
    if kind.startswith("plaster"):
        ramp = [(0.0, (196, 186, 168)), (1.0, (236, 228, 212))] if kind.endswith("a") else [(0.0, (176, 178, 182)), (1.0, (222, 224, 228))]
        return gradient(ramp, noise)
    if kind.startswith("concrete"):
        ramp = [(0.0, (140, 140, 138)), (1.0, (192, 192, 190))] if kind.endswith("a") else [(0.0, (120, 122, 126)), (1.0, (176, 178, 182))]
        arr = gradient(ramp, noise)
        # panel joints every 128 px horizontally, 96 px vertically
        arr[:, ::128] *= 0.72
        arr[::96, :] *= 0.78
        return arr
    if kind == "office_glass":
        return gradient([(0.0, (38, 56, 74)), (1.0, (86, 116, 142))], noise)
    if kind == "glass_curtain":
        return gradient([(0.0, (46, 74, 84)), (1.0, (110, 150, 156))], noise)
    if kind == "industrial":
        arr = gradient([(0.0, (118, 124, 128)), (1.0, (168, 174, 178))], noise)
        arr[:, ::48] *= 0.82
        return arr
    return gradient([(0.0, (150, 150, 150)), (1.0, (190, 190, 190))], noise)


def _draw_window(img: Image.Image, x: int, y: int, w: int, h: int, frame: tuple, panes: int = 2, sill: bool = True) -> None:
    draw = ImageDraw.Draw(img)
    draw.rectangle((x, y, x + w, y + h), fill=frame)
    inner = 10
    draw.rectangle((x + inner, y + inner, x + w - inner, y + h - inner), fill=(46, 58, 74))
    # glass shading with a diagonal reflection
    for i in range(h - 2 * inner):
        f = i / float(max(h - 2 * inner, 1))
        shade = int(30 + 46 * f)
        draw.line((x + inner, y + inner + i, x + w - inner, y + inner + i), fill=(shade, shade + 12, shade + 26))
    draw.polygon(
        [
            (x + inner + 8, y + h - inner - 6),
            (x + w - inner - 30, y + inner + 6),
            (x + w - inner - 10, y + inner + 6),
            (x + inner + 28, y + h - inner - 6),
        ],
        fill=(126, 148, 168),
    )
    if panes > 1:
        for p in range(1, panes):
            px = x + inner + int((w - 2 * inner) * p / panes)
            draw.rectangle((px - 4, y + inner, px + 4, y + h - inner), fill=frame)
    if sill:
        draw.rectangle((x - 8, y + h, x + w + 8, y + h + 12), fill=tuple(max(0, c - 24) for c in frame))


def facade_textures() -> None:
    frame_colors = {
        "brick_a": (236, 236, 232),
        "brick_b": (222, 216, 206),
        "plaster_a": (250, 250, 248),
        "plaster_b": (206, 208, 212),
        "concrete_a": (198, 198, 196),
        "concrete_b": (182, 184, 188),
    }
    for kind, frame in frame_colors.items():
        arr = _facade_base("brick" if kind.startswith("brick") else ("plaster" if kind.startswith("plaster") else "concrete"), hash(kind) & 0xFFFF)
        img = to_pil(arr).convert("RGB")
        _draw_window(img, 150, 70, 212, 190, frame)
        # floor separation line
        draw = ImageDraw.Draw(img)
        draw.rectangle((0, FACADE_H - 10, FACADE_W, FACADE_H), fill=tuple(int(c * 0.82) for c in frame))
        draw.rectangle((0, 0, FACADE_W, 6), fill=tuple(int(c * 0.75) for c in frame))
        save(f"facade_{kind}.png", from_pil(img))

    # office glass: window band across the whole module
    arr = _facade_base("office_glass", 501)
    img = to_pil(arr).convert("RGB")
    draw = ImageDraw.Draw(img)
    draw.rectangle((14, 30, FACADE_W - 14, FACADE_H - 24), fill=(58, 76, 96))
    for i in range(30, FACADE_H - 24, 24):
        draw.line((14, i, FACADE_W - 14, i), fill=(38, 52, 68), width=3)
    for i in range(14, FACADE_W - 14, 48):
        draw.line((i, 30, i, FACADE_H - 24), fill=(46, 62, 78), width=4)
    draw.rectangle((14, 30, FACADE_W - 14, 60), fill=(120, 140, 156))
    save("facade_office_glass.png", from_pil(img))

    # glass curtain wall
    arr = _facade_base("glass_curtain", 502)
    img = to_pil(arr).convert("RGB")
    draw = ImageDraw.Draw(img)
    for i in range(0, FACADE_W, 64):
        draw.line((i, 0, i, FACADE_H), fill=(24, 40, 46), width=5)
    for i in range(0, FACADE_H, 48):
        draw.line((0, i, FACADE_W, i), fill=(28, 46, 52), width=5)
    for i in range(0, FACADE_W, 128):
        draw.rectangle((i + 8, 8, i + 120, 40), fill=(90, 126, 134))
    save("facade_glass_curtain.png", from_pil(img))

    # industrial cladding + high window strip
    arr = _facade_base("industrial", 503)
    img = to_pil(arr).convert("RGB")
    draw = ImageDraw.Draw(img)
    for i in range(0, FACADE_W, 32):
        draw.line((i, 0, i, FACADE_H), fill=(96, 102, 106), width=3)
    draw.rectangle((60, 40, FACADE_W - 60, 110), fill=(70, 84, 92))
    draw.rectangle((60, 40, FACADE_W - 60, 110), outline=(52, 60, 66), width=5)
    draw.rectangle((80, FACADE_H - 120, 200, FACADE_H - 20), fill=(110, 116, 120))
    save("facade_industrial.png", from_pil(img))

    # storefront: shop glass, door, sign band, awning strip
    arr = _facade_base("concrete", 504)
    img = to_pil(arr).convert("RGB")
    draw = ImageDraw.Draw(img)
    draw.rectangle((0, 0, FACADE_W, 84), fill=(58, 60, 66))
    draw.rectangle((16, 16, FACADE_W - 16, 68), fill=(196, 92, 62))
    draw.rectangle((24, 24, 300, 60), fill=(238, 234, 228))
    draw.rectangle((320, 26, 470, 58), fill=(238, 234, 228))
    draw.rectangle((0, 84, FACADE_W, FACADE_H), fill=(112, 112, 116))
    draw.rectangle((16, 110, FACADE_W - 16, FACADE_H - 16), fill=(64, 82, 96))
    for x in range(16, FACADE_W - 16, 96):
        draw.line((x, 110, x, FACADE_H - 16), fill=(44, 56, 66), width=6)
    draw.rectangle((FACADE_W // 2 - 42, 110, FACADE_W // 2 + 42, FACADE_H - 16), fill=(84, 96, 106))
    draw.rectangle((FACADE_W // 2 - 6, 150, FACADE_W // 2 + 6, 210), fill=(196, 190, 180))
    save("facade_storefront.png", from_pil(img))

    # roller door / garage front
    img = Image.new("RGB", (FACADE_W, FACADE_H), (120, 122, 126))
    draw = ImageDraw.Draw(img)
    for i in range(0, FACADE_H, 18):
        draw.line((0, i, FACADE_W, i), fill=(96, 98, 102), width=3)
        draw.line((0, i + 1, FACADE_W, i + 1), fill=(150, 152, 156), width=1)
    draw.rectangle((40, FACADE_H - 90, 150, FACADE_H - 20), fill=(70, 72, 76))
    grain = (rng(505).random((FACADE_H, FACADE_W)) - 0.5) * 14.0
    save("facade_roller_door.png", from_pil(img) + grain[..., None])

    # plinth / base strip of a building (dark stone)
    img = Image.new("RGB", (256, 64), (74, 72, 70))
    draw = ImageDraw.Draw(img)
    for i in range(0, 256, 64):
        draw.rectangle((i + 2, 2, i + 62, 62), fill=(92, 90, 88))
    save("building_plinth.png", from_pil(img))


# ---------------------------------------------------------------- roofs & walls
def roof_wall_textures() -> None:
    size = 512
    # flat roof: bitumen sheets with gravel
    arr = tint(fbm(size, 5, 3, 601), (78, 78, 80), (122, 122, 124), 602)
    arr *= (1.0 + 0.3 * speckles(size, 900, 2.0, 603))[..., None]
    img = to_pil(arr).convert("RGB")
    draw = ImageDraw.Draw(img)
    for i in range(0, size, 128):
        draw.line((i, 0, i, size), fill=(96, 96, 98), width=4)
    save("roof_flat.png", from_pil(img))

    # tiles
    img = Image.new("RGB", (size, size), (128, 62, 46))
    draw = ImageDraw.Draw(img)
    r = rng(611)
    row_h = 32
    tile_w = 42
    for row in range(size // row_h):
        offset = 0 if row % 2 == 0 else tile_w // 2
        for col in range(-1, size // tile_w + 1):
            x = col * tile_w + offset
            y = row * row_h
            v = 0.82 + 0.36 * r.random()
            draw.rectangle((x + 1, y + 1, x + tile_w - 2, y + row_h - 2), fill=(int(150 * v), int(74 * v), int(54 * v)))
            draw.line((x, y + row_h - 3, x + tile_w, y + row_h - 3), fill=(96, 44, 34), width=3)
    grain = (rng(612).random((size, size)) - 0.5) * 16.0
    save("roof_tiles.png", from_pil(img) + grain[..., None])

    # standing seam metal roof
    img = Image.new("RGB", (size, size), (152, 154, 158))
    draw = ImageDraw.Draw(img)
    for i in range(0, size, 64):
        draw.rectangle((i, 0, i + 6, size), fill=(126, 128, 132))
        draw.rectangle((i + 6, 0, i + 10, size), fill=(186, 188, 192))
    grain = (rng(621).random((size, size)) - 0.5) * 10.0
    save("roof_metal.png", from_pil(img) + grain[..., None])

    # garden brick wall with coping
    img = Image.new("RGB", (size, size), (126, 76, 60))
    draw = ImageDraw.Draw(img)
    r = rng(631)
    brick_h, brick_w = 32, 96
    for row in range(size // brick_h):
        offset = 0 if row % 2 == 0 else brick_w // 2
        for col in range(-1, size // brick_w + 1):
            x = col * brick_w + offset
            y = row * brick_h
            v = 0.8 + 0.4 * r.random()
            draw.rectangle((x + 2, y + 2, x + brick_w - 3, y + brick_h - 3), fill=(int(136 * v), int(84 * v), int(66 * v)))
    save("wall_garden.png", from_pil(img))

    # plain concrete wall
    arr = gradient([(0.0, (128, 128, 126)), (1.0, (188, 188, 186))], fbm(size, 6, 3, 641))
    arr[:, ::170] *= 0.86
    arr *= (1.0 - 0.12 * speckles(size, 40, 20.0, 642))[..., None]
    save("concrete_wall.png", arr)


# -------------------------------------------------------------- props and misc
def prop_textures() -> None:
    size = 512
    # corrugated metal (painted)
    img = Image.new("RGB", (size, size), (150, 154, 158))
    draw = ImageDraw.Draw(img)
    for i in range(0, size, 32):
        draw.rectangle((i, 0, i + 12, size), fill=(170, 174, 178))
        draw.rectangle((i + 12, 0, i + 22, size), fill=(124, 128, 132))
        draw.rectangle((i + 22, 0, i + 26, size), fill=(190, 194, 198))
    grain = (rng(701).random((size, size)) - 0.5) * 12.0
    save("metal_corrugated.png", from_pil(img) + grain[..., None])

    # container side with corrugation + door lines
    arr = from_pil(to_pil(tint(fbm(size, 6, 2, 711), (70, 108, 150), (130, 164, 198), 712)).convert("RGB"))
    img = to_pil(arr).convert("RGB")
    draw = ImageDraw.Draw(img)
    for i in range(0, size, 24):
        draw.line((i, 0, i, size), fill=(52, 84, 118), width=4)
    for i in range(0, size, 128):
        draw.line((0, i, size, i), fill=(46, 74, 104), width=5)
    draw.rectangle((size - 150, 40, size - 20, size - 40), fill=(64, 96, 130))
    save("container_side.png", from_pil(img))

    # wooden planks
    img = Image.new("RGB", (size, size), (140, 100, 64))
    draw = ImageDraw.Draw(img)
    r = rng(721)
    plank_h = 64
    for i in range(size // plank_h):
        base = 0.78 + 0.34 * r.random()
        draw.rectangle((0, i * plank_h, size, (i + 1) * plank_h - 4), fill=(int(146 * base), int(104 * base), int(66 * base)))
        for k in range(6):
            y = i * plank_h + 8 + k * 8
            draw.line((0, y, size, y), fill=(int(120 * base), int(84 * base), int(52 * base)), width=1)
    for _ in range(18):
        x = r.random() * size
        y = r.random() * size
        draw.ellipse((x - 6, y - 4, x + 6, y + 4), fill=(112, 78, 48))
    grain = (rng(722).random((size, size)) - 0.5) * 12.0
    save("wood_planks.png", from_pil(img) + grain[..., None])

    # wooden picket fence (alpha)
    img = Image.new("RGBA", (512, 256), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    for i in range(0, 512, 32):
        draw.rectangle((i + 2, 24, i + 30, 256), fill=(150, 112, 74, 255))
        draw.polygon([(i + 2, 24), (i + 16, 4), (i + 30, 24)], fill=(150, 112, 74, 255))
        draw.rectangle((i + 2, 24, i + 8, 256), fill=(126, 92, 60, 255))
    draw.rectangle((0, 90, 512, 112), fill=(132, 98, 64, 255))
    draw.rectangle((0, 180, 512, 200), fill=(132, 98, 64, 255))
    save("fence_picket_alpha.png", from_pil(img))

    # chain link fence (alpha)
    img = Image.new("RGBA", (256, 256), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    for k in range(-256, 512, 32):
        draw.line((k, 0, k + 256, 256), fill=(186, 190, 194, 235), width=3)
        draw.line((k + 256, 0, k, 256), fill=(186, 190, 194, 235), width=3)
    save("fence_chain_alpha.png", from_pil(img))

    # metal railing bars (alpha)
    img = Image.new("RGBA", (256, 128), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    for i in range(0, 256, 24):
        draw.rectangle((i + 8, 0, i + 16, 128), fill=(146, 150, 156, 255))
    draw.rectangle((0, 8, 256, 20), fill=(146, 150, 156, 255))
    draw.rectangle((0, 104, 256, 116), fill=(146, 150, 156, 255))
    save("fence_metal_bars_alpha.png", from_pil(img))

    # granite rock
    arr = gradient([(0.0, (86, 86, 88)), (1.0, (162, 160, 158))], np.clip(fbm(size, 10, 3, 731) * 0.7 + fbm(size, 40, 2, 732) * 0.3, 0, 1))
    arr *= (1.0 + 0.25 * speckles(size, 600, 2.0, 733))[..., None]
    save("rock_granite.png", arr)

    # sandstone
    arr = gradient([(0.0, (176, 142, 96)), (1.0, (222, 196, 148))], np.clip(fbm(size, 8, 3, 741) * 0.6 + fbm(size, 32, 2, 742) * 0.4, 0, 1))
    img = to_pil(arr).convert("RGB")
    draw = ImageDraw.Draw(img)
    for i in range(0, size, 64):
        draw.line((0, i, size, i), fill=(158, 126, 86), width=4)
    save("sandstone.png", from_pil(img))

    # tree bark
    arr = gradient([(0.0, (68, 48, 36)), (1.0, (136, 104, 76))], np.clip(fbm(size, 6, 4, 751) * 0.5 + fbm(size, 64, 2, 752) * 0.5, 0, 1))
    save("tree_bark.png", arr)


def foliage_textures() -> None:
    def leaf_cluster(size, count, radius, colors, seed, leaf_len=16, droop=0.0):
        img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)
        r = rng(seed)
        for _ in range(count):
            a = r.random() * math.tau
            rad = (r.random() ** 0.7) * radius
            x = size / 2 + math.cos(a) * rad
            y = size / 2 + math.sin(a) * rad * 0.85 + droop * rad
            length = leaf_len * (0.6 + r.random())
            ang = r.random() * math.tau
            dx = math.cos(ang) * length
            dy = math.sin(ang) * length * 0.55
            color = colors[int(r.random() * len(colors)) % len(colors)]
            draw.ellipse((x - abs(dx), y - abs(dy), x + abs(dx), y + abs(dy)), fill=color + (255,))
        return img

    save("foliage_a.png", from_pil(leaf_cluster(512, 420, 210, [(58, 96, 48), (86, 128, 58), (44, 78, 40), (110, 148, 72)], 801, 18)))
    save("foliage_b.png", from_pil(leaf_cluster(512, 520, 215, [(38, 72, 46), (54, 92, 58), (30, 58, 38), (70, 108, 66)], 802, 12)))
    # pine / conifer texture: dense dark needles
    save("foliage_pine.png", from_pil(leaf_cluster(512, 700, 220, [(34, 62, 42), (46, 82, 52), (26, 50, 34), (58, 96, 58)], 803, 10)))
    # palm fronds
    img = Image.new("RGBA", (512, 512), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    r = rng(804)
    for i in range(9):
        ang = -math.pi / 2 + (i - 4) * 0.42
        length = 190 + r.random() * 60
        x0, y0 = 256, 256
        x1 = x0 + math.cos(ang) * length
        y1 = y0 + math.sin(ang) * length
        draw.line((x0, y0, x1, y1), fill=(58, 104, 52, 255), width=9)
        for t in np.linspace(0.2, 1.0, 12):
            px = x0 + (x1 - x0) * t
            py = y0 + (y1 - y0) * t
            for side in (-1, 1):
                nx = px + side * 14 * math.sin(ang) * 3
                ny = py - side * 14 * math.cos(ang) * 3
                draw.line((px, py, nx, ny), fill=(74, 128, 62, 255), width=5)
    save("foliage_palm.png", from_pil(img))

    # bush
    save("bush_a.png", from_pil(leaf_cluster(256, 260, 100, [(60, 92, 50), (84, 118, 60), (48, 76, 42)], 805, 12)))

    # grass tuft (alpha, anchored at the bottom)
    img = Image.new("RGBA", (256, 256), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    r = rng(806)
    for _ in range(46):
        x = 30 + r.random() * 196
        h = 70 + r.random() * 170
        bend = (r.random() - 0.5) * 60
        draw.line((x, 256, x + bend, 256 - h), fill=(76 + int(r.random() * 40), 112 + int(r.random() * 40), 56, 255), width=3)
    save("grass_tuft.png", from_pil(img))


def sign_textures() -> None:
    # 4x4 atlas of 128 px traffic sign faces
    atlas_size = 512
    img = Image.new("RGBA", (atlas_size, atlas_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    white = (240, 240, 236, 255)
    red = (196, 46, 38, 255)
    blue = (36, 78, 158, 255)
    yellow = (240, 200, 60, 255)
    dark = (40, 42, 46, 255)

    def cell(index):
        cx = (index % 4) * 128
        cy = (index // 4) * 128
        return cx, cy

    def speed_limit(index, value):
        cx, cy = cell(index)
        draw.ellipse((cx + 6, cy + 6, cx + 122, cy + 122), fill=white, outline=red, width=10)
        draw_centred_text(draw, (cx + 64, cy + 66), value, dark, 54)

    # 0: stop
    cx, cy = cell(0)
    draw.regular_polygon((cx + 64, cy + 66, 58), n_sides=8, rotation=22.5, fill=red, outline=white, width=6)
    draw_centred_text(draw, (cx + 64, cy + 66), "STOP", white, 36)
    # 1: yield
    cx, cy = cell(1)
    draw.polygon([(cx + 8, cy + 16), (cx + 120, cy + 16), (cx + 64, cy + 116)], fill=white, outline=red, width=8)
    # 2/3: speed limits
    speed_limit(2, "50")
    speed_limit(3, "80")
    # 4: no entry
    cx, cy = cell(4)
    draw.ellipse((cx + 8, cy + 8, cx + 120, cy + 120), fill=red)
    draw.rectangle((cx + 30, cy + 56, cx + 98, cy + 72), fill=white)
    # 5: one way
    cx, cy = cell(5)
    draw.rectangle((cx + 10, cy + 44, cx + 118, cy + 84), fill=blue)
    draw.polygon([(cx + 92, cy + 24), (cx + 122, cy + 64), (cx + 92, cy + 104)], fill=white)
    # 6: warning - curve
    cx, cy = cell(6)
    draw.regular_polygon((cx + 64, cy + 70, 60), n_sides=3, rotation=-90, fill=white, outline=dark, width=8)
    draw.line((cx + 64, cy + 40, cx + 64, cy + 96), fill=dark, width=8)
    # 7: pedestrian crossing
    cx, cy = cell(7)
    draw.regular_polygon((cx + 64, cy + 70, 60), n_sides=3, rotation=-90, fill=white, outline=dark, width=8)
    draw.rectangle((cx + 54, cy + 40, cx + 62, cy + 86), fill=dark)
    draw.ellipse((cx + 54, cy + 28, cx + 72, cy + 46), fill=dark)
    # 8: parking
    cx, cy = cell(8)
    draw.rectangle((cx + 8, cy + 8, cx + 120, cy + 120), fill=blue, outline=white, width=6)
    draw_centred_text(draw, (cx + 64, cy + 64), "P", white, 72)
    # 9: fuel
    cx, cy = cell(9)
    draw.rectangle((cx + 8, cy + 8, cx + 120, cy + 120), fill=blue, outline=white, width=6)
    draw.rectangle((cx + 40, cy + 44, cx + 76, cy + 96), fill=white)
    draw.rectangle((cx + 76, cy + 56, cx + 96, cy + 88), fill=white)
    # 10: no parking
    cx, cy = cell(10)
    draw.rectangle((cx + 8, cy + 8, cx + 120, cy + 120), fill=blue, outline=red, width=8)
    draw.line((cx + 14, cy + 114, cx + 114, cy + 14), fill=red, width=10)
    # 11: road works
    cx, cy = cell(11)
    draw.regular_polygon((cx + 64, cy + 70, 60), n_sides=3, rotation=-90, fill=yellow, outline=dark, width=8)
    draw_centred_text(draw, (cx + 64, cy + 62), "!", dark, 62)
    # 12: dead end
    cx, cy = cell(12)
    draw.rectangle((cx + 8, cy + 8, cx + 120, cy + 120), fill=white, outline=dark, width=8)
    draw.line((cx + 64, cy + 30, cx + 64, cy + 96), fill=red, width=12)
    draw.rectangle((cx + 40, cy + 84, cx + 88, cy + 100), fill=red)
    # 13: roundabout
    cx, cy = cell(13)
    draw.rectangle((cx + 8, cy + 8, cx + 120, cy + 120), fill=blue, outline=white, width=6)
    draw.ellipse((cx + 34, cy + 34, cx + 94, cy + 94), outline=white, width=10)
    # 14: priority road
    cx, cy = cell(14)
    draw.polygon([(cx + 64, cy + 10), (cx + 118, cy + 64), (cx + 64, cy + 118), (cx + 10, cy + 64)], fill=white, outline=dark, width=6)
    draw.polygon([(cx + 64, cy + 26), (cx + 102, cy + 64), (cx + 64, cy + 102), (cx + 26, cy + 64)], fill=yellow)
    # 15: hospital / services
    cx, cy = cell(15)
    draw.rectangle((cx + 8, cy + 8, cx + 120, cy + 120), fill=blue, outline=white, width=6)
    draw.rectangle((cx + 56, cy + 30, cx + 72, cy + 98), fill=white)
    draw.rectangle((cx + 30, cy + 56, cx + 98, cy + 72), fill=white)
    save("sign_atlas.png", from_pil(img))

    # shop signs
    shop_colors = [(196, 82, 58), (58, 118, 96), (58, 84, 148), (168, 128, 48)]
    for index, color in enumerate(shop_colors):
        img = Image.new("RGB", (256, 64), color)
        draw = ImageDraw.Draw(img)
        draw.rectangle((0, 0, 256, 6), fill=tuple(min(255, c + 40) for c in color))
        draw.rectangle((0, 58, 256, 64), fill=tuple(int(c * 0.7) for c in color))
        r = rng(900 + index)
        x = 14.0
        while x < 240:
            w = 10 + r.random() * 26
            draw.rectangle((x, 22, x + w, 44), fill=(245, 244, 240))
            x += w + 10
        save(f"shop_sign_{chr(ord('a') + index)}.png", from_pil(img))

    # awnings
    for index, (c1, c2) in enumerate([((186, 62, 54), (238, 232, 224)), ((52, 104, 78), (238, 232, 224)), ((210, 158, 60), (60, 54, 48))]):
        img = Image.new("RGB", (256, 128), c2)
        draw = ImageDraw.Draw(img)
        for x in range(0, 256, 48):
            draw.rectangle((x, 0, x + 24, 128), fill=c1)
        noise = (rng(910 + index).random((128, 256)) - 0.5) * 14.0
        save(f"awning_{chr(ord('a') + index)}.png", from_pil(img) + noise[..., None])

    # billboard ads
    for index, (bg, fg, accent) in enumerate([((32, 46, 92), (238, 238, 234), (232, 108, 60)), ((214, 208, 196), (44, 46, 52), (58, 128, 168))]):
        img = Image.new("RGB", (512, 256), bg)
        draw = ImageDraw.Draw(img)
        draw.rectangle((0, 190, 512, 256), fill=accent)
        draw.ellipse((40, 30, 200, 170), fill=fg)
        r = rng(920 + index)
        x = 230.0
        while x < 470:
            w = 20 + r.random() * 40
            draw.rectangle((x, 60, x + w, 86), fill=fg)
            draw.rectangle((x, 104, x + w * 0.8, 126), fill=fg)
            x += w + 16
        save(f"billboard_ad_{chr(ord('a') + index)}.png", from_pil(img))


def particle_textures() -> None:
    size = 128
    yy, xx = np.mgrid[0:size, 0:size]
    dist = np.sqrt((xx - size / 2) ** 2 + (yy - size / 2) ** 2) / (size / 2)
    falloff = np.clip(1.0 - dist, 0.0, 1.0) ** 1.6
    grain = lattice(size, 16, 1001) * 0.6 + lattice(size, 6, 1002) * 0.4

    dust = np.zeros((size, size, 4), dtype=np.float32)
    for ch, value in enumerate((206, 190, 158)):
        dust[..., ch] = value * (0.7 + 0.5 * grain)
    dust[..., 3] = 255.0 * falloff * np.clip(grain * 1.4, 0, 1)
    save("dust_particle.png", dust)

    smoke = np.zeros((size, size, 4), dtype=np.float32)
    for ch, value in enumerate((96, 96, 98)):
        smoke[..., ch] = value * (0.7 + 0.5 * grain)
    smoke[..., 3] = 220.0 * falloff * np.clip(grain * 1.2, 0, 1)
    save("smoke_particle.png", smoke)

    spark = np.zeros((size, size, 4), dtype=np.float32)
    spark[..., 0] = 255
    spark[..., 1] = 230 * (1.0 - dist)
    spark[..., 2] = 160 * (1.0 - dist * 1.4)
    spark[..., 3] = 255.0 * np.clip(1.0 - dist * 1.15, 0, 1) ** 2.0
    save("spark_particle.png", spark)


def car_textures() -> None:
    size = 256
    # tyre tread
    img = Image.new("RGB", (size, size), (34, 34, 36))
    draw = ImageDraw.Draw(img)
    for i in range(0, size, 32):
        draw.rectangle((i, 0, i + 14, size), fill=(52, 52, 54))
        draw.line((i + 7, 0, i + 7, size), fill=(24, 24, 26), width=3)
    for i in range(0, size, 64):
        draw.rectangle((0, i, size, i + 10), fill=(46, 46, 48))
    grain = (rng(1101).random((size, size)) - 0.5) * 10.0
    save("car_tire.png", from_pil(img) + grain[..., None])

    # alloy rim
    img = Image.new("RGB", (size, size), (150, 152, 156))
    draw = ImageDraw.Draw(img)
    cx = cy = size / 2
    draw.ellipse((cx - 118, cy - 118, cx + 118, cy + 118), fill=(96, 98, 102))
    draw.ellipse((cx - 100, cy - 100, cx + 100, cy + 100), fill=(168, 170, 174))
    for i in range(5):
        ang = math.tau * i / 5.0
        x = cx + math.cos(ang) * 62
        y = cy + math.sin(ang) * 62
        draw.line((cx, cy, x, y), fill=(122, 124, 128), width=22)
    draw.ellipse((cx - 26, cy - 26, cx + 26, cy + 26), fill=(120, 122, 126))
    for i in range(6):
        ang = math.tau * i / 6.0
        draw.ellipse((cx + math.cos(ang) * 30 - 6, cy + math.sin(ang) * 30 - 6, cx + math.cos(ang) * 30 + 6, cy + math.sin(ang) * 30 + 6), fill=(70, 72, 76))
    save("car_rim.png", from_pil(img))

    # headlight lens
    img = Image.new("RGB", (128, 64), (216, 222, 232))
    draw = ImageDraw.Draw(img)
    draw.ellipse((6, 6, 70, 58), fill=(238, 242, 250))
    draw.ellipse((14, 14, 62, 50), fill=(206, 216, 234))
    draw.ellipse((74, 10, 122, 54), fill=(232, 226, 206))
    save("car_light_front.png", from_pil(img))

    # tail light lens
    img = Image.new("RGB", (128, 64), (150, 34, 30))
    draw = ImageDraw.Draw(img)
    draw.rectangle((6, 10, 60, 54), fill=(206, 46, 40))
    for x in range(10, 58, 12):
        draw.line((x, 12, x, 52), fill=(160, 30, 28), width=3)
    draw.rectangle((68, 12, 122, 52), fill=(236, 148, 60))
    save("car_light_rear.png", from_pil(img))

    # license plate
    img = Image.new("RGB", (128, 64), (238, 238, 234))
    draw = ImageDraw.Draw(img)
    draw.rectangle((0, 0, 128, 8), fill=(40, 60, 130))
    draw.rectangle((0, 56, 128, 64), fill=(40, 60, 130))
    for i in range(6):
        draw.rectangle((10 + i * 19, 18, 22 + i * 19, 46), fill=(28, 28, 32))
    save("car_plate.png", from_pil(img))


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate all procedural textures")
    parser.add_argument("--list", action="store_true", help="print the file names this generator writes")
    args = parser.parse_args()
    if args.list:
        print("\n".join(sorted(EXPECTED)))
        return 0
    terrain_textures()
    road_textures()
    surface_textures()
    facade_textures()
    roof_wall_textures()
    prop_textures()
    foliage_textures()
    sign_textures()
    particle_textures()
    car_textures()
    print(f"generated {len(EXPECTED)} textures into {os.path.normpath(OUT_DIR)}")
    return 0


EXPECTED = [
    "terrain_grass.png", "terrain_grass_dry.png", "terrain_dirt.png", "terrain_sand.png",
    "terrain_rock.png", "terrain_gravel.png",
    "road_asphalt_plain.png", "road_asphalt_city.png", "road_asphalt_avenue.png",
    "road_asphalt_highway.png", "road_asphalt_rural.png", "road_dirt_track.png", "road_gravel_road.png",
    "surface_sidewalk.png", "surface_concrete.png", "surface_plaza.png", "surface_parking.png",
    "surface_curb.png",
    "facade_brick_a.png", "facade_brick_b.png", "facade_plaster_a.png", "facade_plaster_b.png",
    "facade_concrete_a.png", "facade_concrete_b.png", "facade_office_glass.png",
    "facade_glass_curtain.png", "facade_industrial.png", "facade_storefront.png",
    "facade_roller_door.png", "building_plinth.png",
    "roof_flat.png", "roof_tiles.png", "roof_metal.png", "wall_garden.png", "concrete_wall.png",
    "metal_corrugated.png", "container_side.png", "wood_planks.png",
    "fence_picket_alpha.png", "fence_chain_alpha.png", "fence_metal_bars_alpha.png",
    "rock_granite.png", "sandstone.png", "tree_bark.png",
    "foliage_a.png", "foliage_b.png", "foliage_pine.png", "foliage_palm.png", "bush_a.png",
    "grass_tuft.png",
    "sign_atlas.png", "shop_sign_a.png", "shop_sign_b.png", "shop_sign_c.png", "shop_sign_d.png",
    "awning_a.png", "awning_b.png", "awning_c.png", "billboard_ad_a.png", "billboard_ad_b.png",
    "dust_particle.png", "smoke_particle.png", "spark_particle.png",
    "car_tire.png", "car_rim.png", "car_light_front.png", "car_light_rear.png", "car_plate.png",
]


if __name__ == "__main__":
    sys.exit(main())
