"""Generate an original network icon with uncompressed 32-bit ICO DIB entries."""
from pathlib import Path
from PIL import Image, ImageDraw
import struct

icons = []
for size in (16, 32, 48, 256):
    scale = 4
    canvas = Image.new("RGBA", (size * scale, size * scale), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    def point(x, y):
        return (int(x * size * scale / 64), int(y * size * scale / 64))
    def box(x0, y0, x1, y1):
        return point(x0, y0) + point(x1, y1)
    draw.rounded_rectangle(box(2, 2, 62, 62), radius=int(size * scale * .19), fill="#197575")
    line = max(2, int(size * scale / 20))
    draw.line([point(32, 30), point(32, 46)], fill="white", width=line)
    draw.line([point(15, 46), point(49, 46)], fill="white", width=line)
    draw.rounded_rectangle(box(20, 12, 44, 31), radius=max(1, int(size * scale / 30)), fill="white")
    draw.rounded_rectangle(box(25, 17, 39, 25), radius=1, fill="#92e0c6")
    for x in (8, 25, 42):
        draw.rounded_rectangle(box(x, 41, x + 14, 53), radius=max(1, int(size * scale / 40)), fill="white")
    image = canvas.resize((size, size), Image.Resampling.LANCZOS)
    pixels = image.transpose(Image.Transpose.FLIP_TOP_BOTTOM).tobytes("raw", "BGRA")
    mask = bytes(((size + 31) // 32) * 4 * size)
    header = struct.pack("<IIIHHIIIIII", 40, size, size * 2, 1, 32, 0, len(pixels), 0, 0, 0, 0)
    icons.append((size, header + pixels + mask))
offset = 6 + 16 * len(icons)
entries = []
for size, data in icons:
    entries.append(struct.pack("<BBBBHHII", size if size < 256 else 0, size if size < 256 else 0, 0, 0, 1, 32, len(data), offset))
    offset += len(data)
(Path(__file__).resolve().parent.parent / "src" / "network.ico").write_bytes(struct.pack("<HHH", 0, 1, len(icons)) + b"".join(entries) + b"".join(data for _, data in icons))
