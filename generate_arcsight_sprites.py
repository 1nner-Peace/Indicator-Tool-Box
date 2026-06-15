from PIL import Image
import math
import os

CELL = 32
SCALE = 4
WIDTH = CELL * 4
HEIGHT = CELL

out_dir = os.path.join("resources", "gfx", "arcsight")
os.makedirs(out_dir, exist_ok=True)

img = Image.new("RGBA", (WIDTH * SCALE, HEIGHT * SCALE), (255, 255, 255, 0))

def clamp01(x):
    return max(0.0, min(1.0, x))

def put_alpha(px, py, alpha):
    if alpha <= 0:
        return

    old = img.getpixel((px, py))
    new_alpha = max(old[3], int(clamp01(alpha) * 255))
    img.putpixel((px, py), (255, 255, 255, new_alpha))

def draw_cell(cell_index, alpha_func):
    x0 = cell_index * CELL * SCALE

    for py in range(CELL * SCALE):
        for px in range(CELL * SCALE):
            lx = (px + 0.5) / SCALE
            ly = (py + 0.5) / SCALE
            alpha = alpha_func(lx, ly)
            put_alpha(x0 + px, py, alpha)

def marker_alpha(x, y):
    # Soft floor ellipse/ring.
    cx, cy = 16.0, 16.0
    dx = x - cx
    dy = y - cy

    # Ellipse radii.
    ex = dx / 10.5
    ey = dy / 5.2
    d = math.sqrt(ex * ex + ey * ey)

    ring = math.exp(-((d - 1.0) / 0.16) ** 2) * 0.95
    glow = math.exp(-((d - 1.0) / 0.42) ** 2) * 0.28

    # Keep center mostly transparent.
    center_clear = clamp01((d - 0.35) / 0.25)

    return max(ring, glow) * center_clear

def center_alpha(x, y):
    # Soft precise center dot/cross.
    cx, cy = 16.0, 16.0
    dx = abs(x - cx)
    dy = abs(y - cy)

    dot_d = math.sqrt(dx * dx + dy * dy)
    dot = math.exp(-((dot_d) / 2.0) ** 2) * 1.0

    vertical = math.exp(-(dx / 0.85) ** 2) * math.exp(-(dy / 5.0) ** 2) * 0.75
    horizontal = math.exp(-(dy / 0.85) ** 2) * math.exp(-(dx / 5.0) ** 2) * 0.75

    return max(dot, vertical, horizontal)

def trail_alpha(x, y):
    # Small soft floor dot.
    cx, cy = 16.0, 16.0
    dx = (x - cx) / 4.2
    dy = (y - cy) / 2.6
    d2 = dx * dx + dy * dy

    return math.exp(-d2 * 1.35) * 0.78

def tether_alpha(x, y):
    # Small vertical bead/capsule.
    cx, cy = 16.0, 16.0
    dx = (x - cx) / 1.45
    dy = (y - cy) / 4.8
    d2 = dx * dx + dy * dy

    core = math.exp(-d2 * 1.15) * 0.9
    glow = math.exp(-d2 * 0.35) * 0.22

    return max(core, glow)

draw_cell(0, marker_alpha)
draw_cell(1, center_alpha)
draw_cell(2, trail_alpha)
draw_cell(3, tether_alpha)

img = img.resize((WIDTH, HEIGHT), Image.Resampling.LANCZOS)
img.save(os.path.join(out_dir, "arcsight_indicators.png"))

print("Wrote resources/gfx/arcsight/arcsight_indicators.png")