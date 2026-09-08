"""Compose the Voqora DMG installer background.

Finder owns the app and Applications icons. The artwork only gives the two
targets a readable, calm context — matching the app's own warm-ivory/clay
"Anthropic/Claude" design language (see frontend/Voqora/Voqora/DesignSystem/
Palette.swift) rather than the earlier cyan/purple ambient-glow look.
"""

from pathlib import Path
from math import sin

from PIL import Image, ImageDraw, ImageFilter, ImageFont


W, H = 1320, 830
ROOT = Path(__file__).resolve().parent
OUTPUT = ROOT / "dmg_background_voqora.png"
FONTS = ROOT.parent / "frontend/Voqora/Voqora/Resources/Fonts"

# Palette.swift's light-mode hex values, ported by hand — this script has no
# access to the app's OKLCH ramp engine, so the accent uses the same raw
# Anthropic "clay" seed (#D97757) Palette.swift itself is calibrated from.
SURFACE_BASE = (250, 249, 245, 255)  # Palette.surfaceBase, light
TEXT_PRIMARY = (24, 24, 23, 255)  # Palette.textPrimary, light
TEXT_SECONDARY = (82, 81, 78, 255)  # Palette.textSecondary, light
CLAY = (217, 119, 87, 255)  # Anthropic clay, Palette's `clay` accent seed
CLAY_FAINT = (217, 119, 87, 26)  # clay at low alpha, for the wave motif


def font(weight: str, size: int) -> ImageFont.FreeTypeFont:
    candidates = (
        FONTS / f"GoogleSans-{weight}.ttf",
        FONTS / f"Poppins-{weight}.ttf",
        Path("/System/Library/Fonts/Helvetica.ttc"),
    )
    for candidate in candidates:
        if candidate.exists():
            return ImageFont.truetype(candidate, size)
    return ImageFont.load_default()


def centered(draw: ImageDraw.ImageDraw, text: str, y: int, face: ImageFont.FreeTypeFont, fill: tuple[int, ...]) -> None:
    box = draw.textbbox((0, 0), text, font=face)
    draw.text(((W - (box[2] - box[0])) // 2, y), text, font=face, fill=fill)


base = Image.new("RGBA", (W, H), SURFACE_BASE)

# A single flat clay wave, echoing the app icon's own wave mark — no colored
# glow blobs, matching the flat, minimal language the rest of the app moved to.
waves = Image.new("RGBA", (W, H), (0, 0, 0, 0))
waves_draw = ImageDraw.Draw(waves)
for index in range(7):
    baseline = 400 + index * 6
    amplitude = 22 + index * 3
    phase = index * 0.5
    points = [
        (x, int(baseline + sin(x / 110 + phase) * amplitude))
        for x in range(-10, W + 10, 6)
    ]
    alpha = 30 - index * 3
    waves_draw.line(points, fill=(*CLAY[:3], max(alpha, 6)), width=2)
base = Image.alpha_composite(base, waves)

# One literal instruction. Finder already labels the app and Applications;
# repeating those labels in the background makes the installer harder to scan.
header = Image.new("RGBA", (W, H), (0, 0, 0, 0))
header_draw = ImageDraw.Draw(header)
# "Bold"/"Regular" match the bundled GoogleSans-*.ttf filenames — there is
# no GoogleSans-SemiBold.ttf in Resources/Fonts (only Light/Regular/Medium/
# Bold/Black, see DashboardViewModel.googleSansPostScriptName), so asking
# for "SemiBold" here would silently fall through to Poppins instead.
centered(header_draw, "Install Voqora", 52, font("Bold", 42), TEXT_PRIMARY)
centered(
    header_draw,
    "Drag the app into Applications",
    112,
    font("Regular", 24),
    TEXT_SECONDARY,
)
header_draw.rounded_rectangle((510, 170, 810, 174), radius=2, fill=CLAY)
base = Image.alpha_composite(base, header)

# A plain clay arrow sits precisely between Finder's two icon positions
# (x=330 and x=990, y=400 at 2x) without asking the user to read twice.
overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
draw = ImageDraw.Draw(overlay)
draw.line((520, 420, 790, 420), fill=CLAY, width=4)
draw.polygon(((817, 420), (780, 398), (780, 442)), fill=CLAY)
base = Image.alpha_composite(base, overlay)

base.convert("RGB").save(OUTPUT, "PNG", dpi=(144, 144))
print(f"Background saved to {OUTPUT}")
