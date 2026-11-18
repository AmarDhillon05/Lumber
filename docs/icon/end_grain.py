"""The "End grain" mark: a log's end grain, which also reads as a drumhead
from above. Hand-wobbled rings, a drying crack, a purple pith dot, and a
slight printed roughness (SVG turbulence displacement).

    python3 docs/icon/end_grain.py docs/icon

writes lumber-end-grain.svg (app icon, full-bleed background) and
lumber-end-grain-mark.svg (transparent, for in-app use). Render to PNG with
any SVG renderer that supports filters (headless Chromium was used).
Deterministic: same seed, same rings.
"""
import math
import random
import sys

CREAM, NIGHT, INK, PURPLE = "#E8E1D2", "#16141B", "#2A2433", "#8B5CF6"


def ring_path(cx, cy, r, wob, phase, n=240):
    pts = []
    for i in range(n):
        a = 2 * math.pi * i / n
        rr = r * (1 + wob * (0.6 * math.sin(3 * a + phase) + 0.3 * math.sin(5 * a + phase * 1.7)
                             + 0.15 * math.sin(9 * a + phase * 0.4)))
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    return "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in pts) + " Z"


def mark(size, background, scale=0.36):
    rnd = random.Random(4)
    c = size / 2
    R = size * scale
    parts = [f'<rect width="{size}" height="{size}" fill="{NIGHT}"/>'] if background else []
    parts.append(f'<path d="{ring_path(c, c, R * 1.06, 0.025, 0.3)}" fill="{CREAM}" filter="url(#rough)"/>')
    k, r = 0, R * 0.95
    while r > R * 0.08:
        w = (2.2 if k % 3 else 3.6) * size / 512
        off = 1 - r / R
        parts.append(
            f'<path d="{ring_path(c + R * 0.04 * off, c - R * 0.03 * off, r, 0.03 + 0.02 * rnd.random(), rnd.random() * 6)}" '
            f'fill="none" stroke="{INK}" stroke-width="{w:.2f}" filter="url(#rough)"/>')
        r -= R * (0.085 + 0.04 * rnd.random())
        k += 1
    parts.append(
        f'<path d="M {c + R * 1.02:.1f} {c - R * 0.18:.1f} L {c + R * 0.62:.1f} {c - R * 0.10:.1f} '
        f'L {c + R * 0.40:.1f} {c - R * 0.06:.1f} L {c + R * 0.18:.1f} {c - R * 0.02:.1f}" stroke="{INK}" '
        f'stroke-width="{6 * size / 512:.1f}" fill="none" stroke-linecap="round" filter="url(#rough)"/>')
    parts.append(f'<circle cx="{c + R * 0.06:.1f}" cy="{c - R * 0.05:.1f}" r="{R * 0.07:.1f}" fill="{PURPLE}"/>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {size} {size}">'
            '<defs><filter id="rough" x="-5%" y="-5%" width="110%" height="110%">'
            '<feTurbulence type="fractalNoise" baseFrequency="0.035" numOctaves="2" seed="7" result="n"/>'
            f'<feDisplacementMap in="SourceGraphic" in2="n" scale="{size * 0.008:.1f}" xChannelSelector="R" '
            'yChannelSelector="G"/></filter></defs>' + "".join(parts) + "</svg>")


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    open(f"{out}/lumber-end-grain.svg", "w").write(mark(1024, background=True))
    # Bigger disk for the in-app mark: it has no tile around it.
    open(f"{out}/lumber-end-grain-mark.svg", "w").write(mark(1024, background=False, scale=0.46))
