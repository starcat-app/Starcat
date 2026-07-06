#!/usr/bin/env python3
"""Generate the fixed Finder background used by Starcat Direct DMG.

The image is intentionally generated from a small set of coordinates because
Finder applies toolbar and status-bar chrome around the background. Keeping the
layout numbers here makes repeated visual tuning cheaper than editing pixels by
hand.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


# Canvas must stay in sync with scripts/package-direct.sh --window-size.
CANVAS_WIDTH = 820
CANVAS_HEIGHT = 520

# Tune these values when the mounted DMG looks vertically unbalanced.
TITLE_Y = 48
PANEL_TOP = 176
PANEL_HEIGHT = 174
PANEL_WIDTH = 186
LEFT_PANEL_X = 142
RIGHT_PANEL_X = 492
ARROW_CENTER_Y = 265

OUTPUT_PATH = Path(__file__).resolve().parent / "assets" / "dmg-background.png"


def load_title_font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    """Use the system font when available so the DMG looks native on macOS."""

    for font_path in (
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/Library/Fonts/Arial Bold.ttf",
    ):
        try:
            return ImageFont.truetype(font_path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def draw_gradient(draw: ImageDraw.ImageDraw) -> None:
    """Paint a light vertical gradient to avoid a flat white installer window."""

    for y in range(CANVAS_HEIGHT):
        t = y / (CANVAS_HEIGHT - 1)
        red = int(252 * (1 - t) + 235 * t)
        green = int(253 * (1 - t) + 239 * t)
        blue = int(254 * (1 - t) + 245 * t)
        draw.line([(0, y), (CANVAS_WIDTH, y)], fill=(red, green, blue))


def draw_isometric_floor(image: Image.Image) -> Image.Image:
    """Add a quiet geometric floor similar to common polished macOS DMGs."""

    floor = Image.new("RGBA", (CANVAS_WIDTH, CANVAS_HEIGHT), (0, 0, 0, 0))
    draw = ImageDraw.Draw(floor)
    origin_y = 150
    cell_width = 132
    cell_height = 70
    for row in range(-2, 8):
        for col in range(-3, 9):
            center_x = col * cell_width + (row % 2) * cell_width // 2 + 42
            center_y = origin_y + row * cell_height // 2
            polygon = [
                (center_x, center_y),
                (center_x + cell_width // 2, center_y + cell_height // 2),
                (center_x, center_y + cell_height),
                (center_x - cell_width // 2, center_y + cell_height // 2),
            ]
            shade = 255 if (row + col) % 2 == 0 else 239
            alpha = 42 if center_y > 210 else 20
            draw.polygon(polygon, fill=(shade, shade, shade, alpha))
            draw.line(polygon + [polygon[0]], fill=(220, 224, 230, 24), width=1)
    return Image.alpha_composite(image.convert("RGBA"), floor)


def draw_top_highlight(image: Image.Image) -> Image.Image:
    """Keep the title area airy without increasing the overall brightness."""

    highlight = Image.new("RGBA", (CANVAS_WIDTH, CANVAS_HEIGHT), (255, 255, 255, 0))
    draw = ImageDraw.Draw(highlight)
    draw.ellipse((-120, -220, CANVAS_WIDTH + 120, 225), fill=(255, 255, 255, 76))
    return Image.alpha_composite(image, highlight)


def draw_title(image: Image.Image) -> None:
    """Draw the product name above the drag targets."""

    draw = ImageDraw.Draw(image)
    font = load_title_font(48)
    text = "Starcat"
    bbox = draw.textbbox((0, 0), text, font=font)
    text_width = bbox[2] - bbox[0]
    draw.text(((CANVAS_WIDTH - text_width) / 2, TITLE_Y), text, font=font, fill=(106, 111, 119))


def draw_panel(image: Image.Image, left: int) -> Image.Image:
    """Draw one icon backing panel with a soft shadow."""

    top = PANEL_TOP
    right = left + PANEL_WIDTH
    bottom = top + PANEL_HEIGHT

    shadow = Image.new("RGBA", (CANVAS_WIDTH, CANVAS_HEIGHT), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(
        (left + 8, top + 10, right + 8, bottom + 10),
        radius=28,
        fill=(98, 103, 110, 38),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(16))
    image = Image.alpha_composite(image, shadow)

    panel_draw = ImageDraw.Draw(image)
    panel_draw.rounded_rectangle(
        (left, top, right, bottom),
        radius=28,
        fill=(222, 225, 230, 112),
        outline=(255, 255, 255, 220),
        width=2,
    )
    return image


def draw_arrow(image: Image.Image) -> None:
    """Draw the directional cue between Starcat.app and Applications."""

    draw = ImageDraw.Draw(image)
    draw.polygon(
        [(386, ARROW_CENTER_Y - 30), (430, ARROW_CENTER_Y), (386, ARROW_CENTER_Y + 30)],
        fill=(103, 107, 113, 220),
    )


def main() -> None:
    image = Image.new("RGB", (CANVAS_WIDTH, CANVAS_HEIGHT), (248, 249, 251))
    draw_gradient(ImageDraw.Draw(image))
    image = draw_isometric_floor(image)
    image = draw_top_highlight(image)
    draw_title(image)
    image = draw_panel(image, LEFT_PANEL_X)
    image = draw_panel(image, RIGHT_PANEL_X)
    draw_arrow(image)

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGB").save(OUTPUT_PATH, optimize=True)
    print(f"Generated {OUTPUT_PATH} ({CANVAS_WIDTH}x{CANVAS_HEIGHT})")


if __name__ == "__main__":
    main()
