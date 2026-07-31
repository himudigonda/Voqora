"""Compose a clean, light Voqora DMG installer background.

Finder owns the app and Applications icons. The artwork only gives the two
targets a readable, calm context.
"""

from pathlib import Path
from math import sin

from PIL import Image, ImageDraw, ImageFilter, ImageFont


W, H = 1320, 830
ROOT = Path(__file__).resolve().parent
OUTPUT = ROOT / "dmg_background_voqora.png"
FONTS = ROOT.parent / "frontend/Voqora/Voqora/Resources/Fonts"


def font(weight: str, size: int) -> ImageFont.FreeTypeFont:
    for candidate in (FONTS / f"Poppins-{weight}.ttf", Path("/System/Library/Fonts/Helvetica.ttc")):
        if candidate.exists():
            return ImageFont.truetype(candidate, size)
    return ImageFont.load_default()


def centered(draw: ImageDraw.ImageDraw, text: str, y: int, face: ImageFont.FreeTypeFont, fill: tuple[int, ...]) -> None:
    box = draw.textbbox((0, 0), text, font=face)
    draw.text(((W - (box[2] - box[0])) // 2, y), text, font=face, fill=fill)


base = Image.new("RGBA", (W, H), (255, 255, 255, 255))

# A white canvas with Voqora's cool, airy audio signature. The colour lives in
# the background light and waveform, never in separate cards around Finder UI.
light = Image.new("RGBA", (W, H), (0, 0, 0, 0))
light_draw = ImageDraw.Draw(light)
light_draw.ellipse((-170, -200, 760, 630), fill=(53, 204, 255, 52))
light_draw.ellipse((590, -100, 1490, 710), fill=(139, 92, 246, 40))
light_draw.ellipse((285, 310, 1040, 1030), fill=(16, 185, 129, 22))
light = light.filter(ImageFilter.GaussianBlur(105))
base = Image.alpha_composite(base, light)

waves = Image.new("RGBA", (W, H), (0, 0, 0, 0))
waves_draw = ImageDraw.Draw(waves)
for index in range(11):
    baseline = 365 + index * 11
    amplitude = 18 + index * 2
    phase = index * 0.42
    points = [
        (x, int(baseline + sin(x / 92 + phase) * amplitude + sin(x / 38 + phase) * 4))
        for x in range(-10, W + 10, 6)
    ]
    colour = (20, 184, 232, 40) if index % 2 == 0 else (124, 58, 237, 32)
    waves_draw.line(points, fill=colour, width=2)
waves = waves.filter(ImageFilter.GaussianBlur(0.35))
base = Image.alpha_composite(base, waves)

# One literal instruction. Finder already labels the app and Applications;
# repeating those labels in the background makes the installer harder to scan.
header = Image.new("RGBA", (W, H), (0, 0, 0, 0))
header_draw = ImageDraw.Draw(header)
centered(header_draw, "Install Voqora", 52, font("SemiBold", 42), (20, 34, 51, 255))
centered(
    header_draw,
    "Drag the app into Applications",
    112,
    font("Regular", 24),
    (83, 104, 125, 255),
)
header_draw.rounded_rectangle((510, 170, 810, 174), radius=2, fill=(20, 183, 232, 255))

# A subtle route sits precisely between Finder's two icon positions
# (x=330 and x=990, y=400 at 2x) without asking the user to read twice.
route = Image.new("RGBA", (W, H), (0, 0, 0, 0))
route_draw = ImageDraw.Draw(route)
route_draw.line((520, 420, 800, 420), fill=(70, 184, 239, 45), width=18)
route = route.filter(ImageFilter.GaussianBlur(12))
base = Image.alpha_composite(base, header)
base = Image.alpha_composite(base, route)

overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
draw = ImageDraw.Draw(overlay)
draw.line((520, 420, 790, 420), fill=(36, 159, 219, 210), width=4)
draw.polygon(((817, 420), (780, 398), (780, 442)), fill=(23, 154, 219, 255))

base = Image.alpha_composite(base, overlay)
base.convert("RGB").save(OUTPUT, "PNG", dpi=(144, 144))
print(f"Background saved to {OUTPUT}")
