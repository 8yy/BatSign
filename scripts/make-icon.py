#!/usr/bin/env python3
"""Draw the BatSign app icon.

There are two places an iOS 26 app's icon can come from, and this project ships
both, so both are written here:

  * `AppIcon.icon/` — an Icon Composer bundle, which is what iOS 26 uses. Its
    `icon.json` supplies the ground as a gradient fill and composites image
    *layers* on top, so the mark goes in as a white shape on transparency and
    the background is left to the bundle.
  * `AppIcon.appiconset/` — the classic asset, still the fallback on older
    systems, where the whole icon (ground and mark together) is one image, in
    normal, dark and tinted appearances.

Everything is drawn at 4x and downsampled, so the edges are properly
antialiased rather than stair-stepped.
"""

import json
import os
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SS = 4  # supersample factor
RESOURCES = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "..", "Feather", "Resources")
OUT = os.path.join(RESOURCES, "Assets.xcassets", "AppIcon.appiconset")
ICON_COMPOSER = os.path.join(RESOURCES, "AppIcon.icon")

# The document/URL/UTType icon. `Info.plist` points at this file five times —
# `CFBundleTypeIconFile`, `CFBundleURLIconFile` and `UTTypeIconFile` — so it is
# what iOS draws for an IPA in Files, in a share sheet and in AirDrop. It used
# to be a stale copy of the old blue "S", which is exactly where old artwork
# kept reappearing after the app icon itself had been replaced.
EXTENSION_ICON = os.path.join(RESOURCES, "feather_extension.png")
EXTENSION_ICON_SIZE = 512

# The same accent ramp the app uses.
ACCENT = (10, 132, 255)
ACCENT_DEEP = (0, 88, 216)
DARK_TOP = (14, 22, 38)
DARK_BOTTOM = (4, 7, 13)

# The mark, in a unit square with y pointing down and the left half authored
# only; the right half is mirrored, which is what keeps a bat symmetrical.
#
# Built from primitives rather than one hand-tuned polygon. A wing is a smooth
# leading-edge arc over a scalloped trailing edge; the body is an ellipse; the
# ears are triangles. One polygon with a dozen vertices cannot be both smooth on
# top and scalloped underneath without turning into a saw blade.

WING_TIP = (0.050, 0.430)
WING_SHOULDER = (0.448, 0.300)
WING_CONTROL = (0.165, 0.185)      # pulls the leading edge into an arc

# Trailing edge, from the body out to the tip: three fingers, each dipping to a
# point and rising to a valley between them.
WING_TRAILING = [
    (0.452, 0.580),
    (0.402, 0.668), (0.360, 0.574),
    (0.294, 0.702), (0.242, 0.588),
    (0.172, 0.646), (0.118, 0.520),
    WING_TIP,
]

BODY_CENTRE = (0.500, 0.410)
BODY_RADIUS = (0.082, 0.205)

EAR = [(0.432, 0.300), (0.452, 0.124), (0.482, 0.288)]


def bezier(p0, p1, p2, steps=28):
    """Quadratic Bézier, so the leading edge can be a curve and not a chamfer."""
    out = []
    for i in range(steps + 1):
        t = i / steps
        u = 1 - t
        out.append((
            u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0],
            u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1],
        ))
    return out


def bat_mask(size):
    """The mark drawn at `size` in unit coordinates, before any fitting."""
    layer = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(layer)

    def px(points):
        return [(x * size, y * size) for x, y in points]

    def mirror(points):
        return [(1 - x, y) for x, y in points]

    leading = bezier(WING_TIP, WING_CONTROL, WING_SHOULDER)
    wing = leading + WING_TRAILING

    d.polygon(px(wing), fill=255)
    d.polygon(px(mirror(wing)), fill=255)

    cx, cy = BODY_CENTRE
    rx, ry = BODY_RADIUS
    d.ellipse(px([(cx - rx, cy - ry), (cx + rx, cy + ry)]), fill=255)

    d.polygon(px(EAR), fill=255)
    d.polygon(px(mirror(EAR)), fill=255)

    return layer


def fit(layer, size, width=0.80):
    """Scale and centre a mask on a `size` canvas, by its own bounds."""
    box = layer.getbbox()
    if box is None:
        return Image.new("L", (size, size), 0)

    cropped = layer.crop(box)
    span_x = cropped.width
    span_y = cropped.height

    target = size * width
    scale = min(target / span_x, (size * 0.56) / span_y)

    resized = cropped.resize(
        (max(int(span_x * scale), 1), max(int(span_y * scale), 1)),
        Image.LANCZOS,
    )

    canvas = Image.new("L", (size, size), 0)
    canvas.paste(
        resized,
        ((size - resized.width) // 2, (size - resized.height) // 2),
    )
    return canvas


def vertical_gradient(size, top, bottom):
    grad = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(size - 1, 1)
        grad.putpixel((0, y), tuple(
            int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)
        ))
    return grad.resize((size, size), Image.BILINEAR).convert("RGBA")


def glow(size, centre, radius, colour, strength):
    """A soft radial highlight, drawn small and blown up so it has no banding."""
    r = max(size // 8, 8)
    layer = Image.new("L", (r, r), 0)
    d = ImageDraw.Draw(layer)
    cx, cy = r / 2, r / 2
    steps = 40
    for i in range(steps, 0, -1):
        t = i / steps
        d.ellipse(
            [cx - cx * t, cy - cy * t, cx + cx * t, cy + cy * t],
            fill=int(255 * (1 - t) ** 1.6),
        )
    layer = layer.resize((radius * 2, radius * 2), Image.BICUBIC)
    tinted = Image.new("RGBA", layer.size, colour + (0,))
    tinted.putalpha(layer.point(lambda v: int(v * strength)))
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(tinted, (int(centre[0] - radius), int(centre[1] - radius)), tinted)
    return canvas


def bat_layer(size, colour=(255, 255, 255, 255), width=0.80):
    mask = fit(bat_mask(size), size, width)
    layer = Image.new("RGBA", (size, size), colour)
    layer.putalpha(mask)
    return layer


def write_icon_composer(mark_width=0.78):
    """Replace the Icon Composer bundle's mark layer with the bat.

    The bundle's own gradient fill stays: that is the ground, and duplicating it
    inside the layer would double-darken the icon. The second layer the bundle
    shipped (a faint ghost of the old glyph) is dropped, because two marks
    composited at once is exactly the muddle this is replacing.
    """
    assets = os.path.join(ICON_COMPOSER, "Assets")
    os.makedirs(assets, exist_ok=True)

    size = SIZE
    mask = fit(bat_mask(size * 2), size * 2, mark_width).resize(
        (size, size), Image.LANCZOS
    )
    layer = Image.new("RGBA", (size, size), (255, 255, 255, 255))
    layer.putalpha(mask)
    layer.save(os.path.join(assets, "feather.png"))

    path = os.path.join(ICON_COMPOSER, "icon.json")
    with open(path) as fh:
        spec = json.load(fh)

    for group in spec.get("groups", []):
        group["layers"] = [
            layer for layer in group.get("layers", [])
            if layer.get("image-name") == "feather.png"
        ]

    with open(path, "w") as fh:
        json.dump(spec, fh, indent=2)
        fh.write("\n")

    print(f"AppIcon.icon/Assets/feather.png: mark layer rewritten")


def build(size, background, mark_colour, glow_colour):
    s = size * SS
    canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    canvas.alpha_composite(background(s))

    # The mark, with a soft shadow so it reads as sitting on the ground rather
    # than printed flat on it.
    mark = bat_layer(s, mark_colour)
    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    shadow.alpha_composite(mark)
    shadow = shadow.filter(ImageFilter.GaussianBlur(s * 0.018))
    shadow.putalpha(shadow.getchannel("A").point(lambda v: int(v * 0.30)))
    canvas.alpha_composite(shadow, (0, int(s * 0.012)))

    canvas.alpha_composite(mark)

    if glow_colour is not None:
        canvas.alpha_composite(
            glow(s, (s * 0.30, s * 0.18), int(s * 0.62), glow_colour, 0.28)
        )
    return canvas.resize((size, size), Image.LANCZOS).convert("RGB")


def main():
    os.makedirs(OUT, exist_ok=True)

    normal = lambda s: (
        lambda g: (lambda c: (c.alpha_composite(g), c)[1])(
            Image.new("RGBA", (s, s), (0, 0, 0, 0))
        )
    )(vertical_gradient(s, ACCENT, ACCENT_DEEP).convert("RGBA"))

    dark = lambda s: vertical_gradient(s, DARK_TOP, DARK_BOTTOM).convert("RGBA")

    tinted = lambda s: vertical_gradient(s, (168, 168, 168), (74, 74, 74)).convert("RGBA")

    build(SIZE, normal, (255, 255, 255, 255), (255, 255, 255)).save(
        os.path.join(OUT, "feather.png")
    )
    build(SIZE, dark, (255, 255, 255, 255), (120, 200, 255)).save(
        os.path.join(OUT, "feather_dark.png")
    )
    build(SIZE, tinted, (255, 255, 255, 255), None).save(
        os.path.join(OUT, "feather_tint.png")
    )

    # The type/URL icon, redrawn from the same mark so no surface in the system
    # can still be showing the previous brand.
    build(
        EXTENSION_ICON_SIZE, normal, (255, 255, 255, 255), (255, 255, 255)
    ).save(EXTENSION_ICON)

    write_icon_composer()

    for name in ("feather.png", "feather_dark.png", "feather_tint.png"):
        im = Image.open(os.path.join(OUT, name))
        print(f"{name}: {im.size[0]}x{im.size[1]} {im.mode}")

    im = Image.open(EXTENSION_ICON)
    print(f"feather_extension.png: {im.size[0]}x{im.size[1]} {im.mode}")


if __name__ == "__main__":
    main()
