#!/usr/bin/env python3
"""Generates the MDX/MDD test fixtures in Tests/Fixtures.

Uses the vendored writemdict library (https://github.com/zhansliu/writemdict)
so that MdxKit is validated against the reference MDict writer.

Run from the repo root:  python3 tools/make_fixtures.py
"""

import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "writemdict"))

from writemdict import MDictWriter  # noqa: E402

OUT = os.path.join(os.path.dirname(__file__), "..", "Tests", "Fixtures")

# 1x1 transparent PNG.
TINY_PNG = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
    "0000000d4944415478da63fcffffff3f0005fe02fea72d5e6c0000000049454e44ae426082"
)

# Minimal valid WAV: 8 samples of silence, 8kHz mono 8-bit.
TINY_WAV = (
    b"RIFF" + struct.pack("<I", 36 + 8) + b"WAVE"
    + b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, 8000, 8000, 1, 8)
    + b"data" + struct.pack("<I", 8) + b"\x80" * 8
)

CSS = b".entry { color: rgb(20, 40, 160); font-family: Georgia, serif; }\n"


def word_entries():
    d = {
        "apple": (
            '<link rel="stylesheet" href="style.css">'
            '<div class="entry"><img src="apple.png">'
            '<a href="sound://pron/apple.wav">listen</a>'
            "<b>apple</b>: a round fruit with firm flesh</div>"
        ),
        "banana": '<div class="entry"><b>banana</b>: a long curved fruit</div>',
        "color": '<div class="entry"><b>color</b>: the American spelling</div>',
        "colour": "@@@LINK=color",
        "naïve": '<div class="entry"><b>naïve</b>: unicode key test</div>',
        "Case Sensitive": '<div class="entry">mixed-case key</div>',
    }
    # Filler entries to force several key/record blocks with a small block size.
    for i in range(1, 51):
        d[f"w{i:03d}"] = f"<div>filler entry number {i}</div>"
    return d


def write(name, writer):
    path = os.path.join(OUT, name)
    with open(path, "wb") as f:
        writer.write(f)
    print(f"wrote {name} ({os.path.getsize(path)} bytes)")


def main():
    os.makedirs(OUT, exist_ok=True)
    entries = word_entries()

    write("basic.mdx", MDictWriter(
        entries, title="Basic Test Dictionary",
        description="Fixture for MdxKit tests",
        block_size=256,
    ))

    write("encrypted.mdx", MDictWriter(
        entries, title="Encrypted Index Dictionary",
        description="Encrypted=2 fixture",
        block_size=256, encrypt_index=True,
    ))

    write("utf16.mdx", MDictWriter(
        entries, title="UTF-16 Dictionary",
        description="UTF-16 encoded fixture",
        block_size=256, encoding="utf16",
    ))

    write("v1.mdx", MDictWriter(
        entries, title="V1 Dictionary",
        description="Version 1.2 format fixture",
        block_size=256, version="1.2",
    ))

    write("nocomp.mdx", MDictWriter(
        entries, title="Uncompressed Dictionary",
        description="compression_type=0 fixture",
        block_size=256, compression_type=0,
    ))

    resources = {
        "\\style.css": CSS,
        "\\apple.png": TINY_PNG,
        "\\pron\\apple.wav": TINY_WAV,
    }
    # Each MDX variant gets a same-name MDD so imports pick up resources.
    for base in ["basic", "encrypted", "utf16", "v1", "nocomp"]:
        write(f"{base}.mdd", MDictWriter(
            resources, title=f"{base} resources",
            description="MDD fixture", is_mdd=True,
        ))


if __name__ == "__main__":
    main()
