# /// script
# dependencies = ["pillow"]
# ///
"""Generate the abra app icon (1024px master PNG).

Design: macOS-style squircle, deep violet gradient, white mic, gold
four-point sparkle — "I create as I speak."

Run:  uv run shells/mac/icon/gen_icon.py
Then: shells/mac/icon/make_icns.sh packages it into AppIcon.icns
"""

from pathlib import Path

from PIL import Image, ImageDraw

S = 1024
# macOS icon grid: content squircle ~824px centered, transparent margin.
MARGIN = 100
CONTENT = S - 2 * MARGIN
RADIUS = int(CONTENT * 0.2237)  # Apple squircle-ish corner


def vertical_gradient(size, top, bottom):
    img = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        img.putpixel((0, y), tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
    return img.resize((size, size))


def sparkle(draw, cx, cy, r, color):
    """Four-point star: long vertical/horizontal spikes, pinched waist."""
    w = r * 0.22
    pts = []
    for dx, dy in [(0, -1), (1, 0), (0, 1), (-1, 0)]:
        pts.append((cx + dx * r, cy + dy * r))                     # spike tip
        nx, ny = -dy, dx                                           # next waist
        pts.append((cx + (dx + nx) * w, cy + (dy + ny) * w))
    draw.polygon(pts, fill=color)


img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# squircle with gradient fill — polished graphite, macOS-native feel
grad = vertical_gradient(CONTENT, (58, 58, 64), (22, 22, 26))
mask = Image.new("L", (CONTENT, CONTENT), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, CONTENT - 1, CONTENT - 1],
                                       radius=RADIUS, fill=255)
img.paste(grad, (MARGIN, MARGIN), mask)

d = ImageDraw.Draw(img)
WHITE = (255, 255, 255, 255)
cx = S // 2

# mic capsule
cap_w, cap_top, cap_bot = 170, 306, 566
d.rounded_rectangle([cx - cap_w // 2, cap_top, cx + cap_w // 2, cap_bot],
                    radius=cap_w // 2, fill=WHITE)

# cradle arc (opens upward)
arc_r, arc_cy, stroke = 165, 460, 30
d.arc([cx - arc_r, arc_cy - arc_r, cx + arc_r, arc_cy + arc_r],
      start=15, end=165, fill=WHITE, width=stroke)

# stem + base
d.rectangle([cx - 15, arc_cy + arc_r - 6, cx + 15, 700], fill=WHITE)
d.rounded_rectangle([cx - 110, 700, cx + 110, 730], radius=15, fill=WHITE)

# gold sparkle, top-right — the abracadabra
GOLD = (251, 191, 36, 255)
sparkle(d, 700, 268, 92, GOLD)
sparkle(d, 762, 372, 40, GOLD)

out = Path(__file__).parent / "abra-1024.png"
img.save(out)
print(f"wrote {out}")
