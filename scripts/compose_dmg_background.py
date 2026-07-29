"""Compose the Voqora DMG installer background from its brand artwork.

The Finder controls the actual app and Applications icons. This layer only adds
the high-contrast instruction and label surfaces needed to make the installer
obvious on a dark background.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


W, H = 1320, 830
ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "dmg_background_voqora_v2.png"
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


if not SOURCE.exists():
    raise SystemExit(f"Missing source artwork: {SOURCE}")

base = Image.open(SOURCE).convert("RGBA").resize((W, H), Image.Resampling.LANCZOS)

# Slightly deepen the lower installation area. It gives the app icon breathing
# room without suppressing the source waveform.
shade = Image.new("RGBA", (W, H), (1, 5, 18, 0))
shade_draw = ImageDraw.Draw(shade)
for y in range(H):
    alpha = int(20 + max(0, y - 250) / (H - 250) * 65)
    shade_draw.line((0, y, W, y), fill=(1, 5, 18, alpha))
base = Image.alpha_composite(base, shade)

# Header: one short, literal instruction. It is intentionally separate from
# Finder's labels so the user knows exactly what to do before noticing icons.
header = Image.new("RGBA", (W, H), (0, 0, 0, 0))
header_draw = ImageDraw.Draw(header)
centered(header_draw, "VOQORA", 42, font("SemiBold", 42), (244, 249, 255, 255))
centered(
    header_draw,
    "Drag Voqora to Applications to install",
    98,
    font("Regular", 24),
    (207, 222, 245, 255),
)

# A softly luminous route provides a usable drag affordance in the exact gap
# between Finder's two icon positions (x=330 and x=990, y=400 at 2x).
route = Image.new("RGBA", (W, H), (0, 0, 0, 0))
route_draw = ImageDraw.Draw(route)
route_draw.line((500, 402, 820, 402), fill=(84, 204, 255, 65), width=18)
route = route.filter(ImageFilter.GaussianBlur(12))
base = Image.alpha_composite(base, header)
base = Image.alpha_composite(base, route)

overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
draw = ImageDraw.Draw(overlay)
draw.line((500, 402, 815, 402), fill=(220, 247, 255, 235), width=5)
draw.polygon(((840, 402), (802, 380), (802, 424)), fill=(100, 210, 255, 255))
centered(draw, "DRAG TO INSTALL", 346, font("SemiBold", 17), (182, 226, 255, 235))

# Finder paints icon labels in black. These quiet frosted surfaces make both
# labels readable without fighting the dark visual language.
for left, right in ((135, 525), (795, 1185)):
    draw.rounded_rectangle((left, 538, right, 596), radius=29, fill=(224, 240, 255, 186))
    draw.rounded_rectangle((left, 538, right, 596), radius=29, outline=(255, 255, 255, 120), width=2)

base = Image.alpha_composite(base, overlay)
base.convert("RGB").save(OUTPUT, "PNG", dpi=(144, 144))
print(f"Background saved to {OUTPUT}")
