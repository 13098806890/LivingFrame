#!/usr/bin/env python3
"""Extract the three authored paper frames from the visual reference.

The source artwork is a flattened mockup, so this script keeps the original
paper pixels and replaces only the photograph/background with alpha.  A small
style-specific shadow is rebuilt from the extracted silhouette because the
mockup shadow is flattened into the blue presentation background.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter


@dataclass(frozen=True)
class PaperStyle:
    name: str
    crop: tuple[int, int, int, int]
    outer: tuple[tuple[int, int], ...]
    opening: tuple[tuple[int, int], ...]
    shadow_offset: tuple[int, int]
    shadow_blur: float
    shadow_opacity: int
    contact_blur: float
    contact_opacity: int


STYLES = (
    PaperStyle(
        name="soft",
        crop=(20, 185, 500, 765),
        outer=(
            (16, 26), (78, 24), (154, 25), (232, 24), (310, 25), (390, 24),
            (474, 26), (476, 108), (475, 196), (476, 286), (475, 378),
            (476, 468), (474, 559), (392, 561), (310, 560), (228, 562),
            (146, 560), (72, 562), (17, 560), (16, 478), (17, 390),
            (16, 300), (17, 210), (16, 118),
        ),
        opening=((40, 45), (450, 45), (450, 532), (40, 532)),
        shadow_offset=(2, 5),
        shadow_blur=5.5,
        shadow_opacity=76,
        contact_blur=2.8,
        contact_opacity=52,
    ),
    PaperStyle(
        name="fibrous",
        crop=(510, 175, 1010, 775),
        outer=(
            (24, 56), (38, 42), (66, 41), (88, 34), (115, 39), (142, 32),
            (170, 28), (197, 20), (226, 28), (252, 30), (278, 38), (306, 31),
            (337, 34), (364, 29), (394, 33), (422, 28), (451, 35), (469, 44),
            (472, 82), (468, 112), (475, 145), (467, 178), (474, 215),
            (465, 248), (474, 286), (466, 322), (473, 360), (465, 397),
            (472, 435), (464, 471), (472, 511), (464, 548), (450, 568),
            (418, 573), (392, 567), (365, 578), (338, 567), (309, 576),
            (282, 566), (252, 578), (226, 565), (199, 576), (170, 568),
            (142, 576), (114, 567), (87, 574), (59, 567), (34, 573),
            (22, 554), (27, 518), (22, 484), (27, 448), (22, 411),
            (27, 374), (22, 337), (27, 300), (22, 263), (27, 226),
            (22, 188), (27, 151), (22, 113),
        ),
        opening=((54, 59), (437, 59), (437, 540), (54, 540)),
        shadow_offset=(5, 9),
        shadow_blur=10.0,
        shadow_opacity=92,
        contact_blur=4.0,
        contact_opacity=66,
    ),
    PaperStyle(
        name="layered",
        crop=(1000, 180, 1520, 790),
        outer=(
            (25, 38), (118, 35), (196, 38), (276, 35), (354, 38), (438, 34),
            (489, 43), (496, 108), (494, 180), (496, 252), (494, 326),
            (498, 400), (495, 474), (500, 548), (484, 577), (448, 588),
            (396, 582), (340, 587), (284, 580), (228, 586), (170, 580),
            (112, 586), (58, 580), (25, 562), (28, 486), (25, 410),
            (28, 332), (25, 254), (28, 176), (25, 100),
        ),
        opening=(
            (45, 53), (442, 41), (444, 132), (441, 218), (438, 306),
            (432, 394), (426, 474), (414, 539), (332, 542), (254, 539),
            (176, 542), (99, 539), (45, 538),
        ),
        shadow_offset=(13, 18),
        shadow_blur=18.0,
        shadow_opacity=98,
        contact_blur=5.5,
        contact_opacity=74,
    ),
)


def antialiased_polygon(size: tuple[int, int], points: tuple[tuple[int, int], ...]) -> Image.Image:
    scale = 4
    mask = Image.new("L", (size[0] * scale, size[1] * scale), 0)
    draw = ImageDraw.Draw(mask)
    draw.polygon([(x * scale, y * scale) for x, y in points], fill=255)
    return mask.resize(size, Image.Resampling.LANCZOS)


def offset_alpha(alpha: Image.Image, offset: tuple[int, int]) -> Image.Image:
    shifted = Image.new("L", alpha.size, 0)
    shifted.paste(alpha, offset)
    return shifted


def scaled_alpha(alpha: Image.Image, opacity: int) -> Image.Image:
    return alpha.point(lambda value: value * opacity // 255)


def extract_style(source: Image.Image, style: PaperStyle) -> Image.Image:
    crop = source.crop(style.crop).convert("RGBA")
    outer = antialiased_polygon(crop.size, style.outer)
    opening = antialiased_polygon(crop.size, style.opening)
    paper_alpha = ImageChops.subtract(outer, opening)

    paper = crop.copy()
    paper.putalpha(paper_alpha)

    cast_alpha = offset_alpha(
        outer.filter(ImageFilter.GaussianBlur(style.shadow_blur)),
        style.shadow_offset,
    )
    cast_alpha = ImageChops.subtract(cast_alpha, outer)
    cast_alpha = scaled_alpha(cast_alpha, style.shadow_opacity)

    contact_alpha = paper_alpha.filter(ImageFilter.GaussianBlur(style.contact_blur))
    contact_alpha = ImageChops.subtract(contact_alpha, paper_alpha)
    contact_alpha = scaled_alpha(contact_alpha, style.contact_opacity)

    shadow_alpha = ImageChops.lighter(cast_alpha, contact_alpha)
    shadow = Image.new("RGBA", crop.size, (31, 38, 45, 0))
    shadow.putalpha(shadow_alpha)
    return Image.alpha_composite(shadow, paper)


def make_preview(frames: list[Image.Image]) -> Image.Image:
    scale = 0.86
    cards = [frame.resize((int(frame.width * scale), int(frame.height * scale)), Image.Resampling.LANCZOS) for frame in frames]
    gap = 26
    margin = 32
    width = margin * 2 + sum(card.width for card in cards) + gap * (len(cards) - 1)
    height = margin * 2 + max(card.height for card in cards)
    preview = Image.new("RGBA", (width, height), (224, 232, 240, 255))
    x = margin
    for card in cards:
        y = margin + (height - margin * 2 - card.height) // 2
        preview.alpha_composite(card, (x, y))
        x += card.width + gap
    return preview.convert("RGB")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--preview", type=Path)
    args = parser.parse_args()

    source = Image.open(args.source).convert("RGB")
    args.output.mkdir(parents=True, exist_ok=True)
    frames: list[Image.Image] = []
    for style in STYLES:
        frame = extract_style(source, style)
        frame.save(args.output / f"paper-mockup-{style.name}-frame.png", optimize=True)
        frames.append(frame)

    if args.preview:
        args.preview.parent.mkdir(parents=True, exist_ok=True)
        make_preview(frames).save(args.preview, optimize=True)


if __name__ == "__main__":
    main()
