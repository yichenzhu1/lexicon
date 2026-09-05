#!/usr/bin/env python3
"""Generates the MDX/MDD test fixtures in Tests/Fixtures.

Uses the vendored writemdict library (https://github.com/zhansliu/writemdict)
so that MdxKit is validated against the reference MDict writer.

Run from the repo root:  python3 tools/make_fixtures.py
"""

import os
import struct
import sys
import datetime

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "writemdict"))

import writemdict as writemdict_module  # noqa: E402
from writemdict import MDictWriter  # noqa: E402


# MDict stores the creation date in every header. A fixed date keeps fixture
# regeneration byte-for-byte reproducible.
class FixtureDate(datetime.date):
    fixture_day = 4

    @classmethod
    def today(cls):
        return cls(2026, 8, cls.fixture_day)


writemdict_module.datetime.date = FixtureDate

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

    # Headwords whose distinguishing character lives outside the Basic
    # Multilingual Plane. Prefix search bounds the key range byte-wise, so
    # these catch an upper bound that sorts below astral UTF-8 sequences.
    FixtureDate.fixture_day = 6
    write("astral.mdx", MDictWriter(
        {
            "test": "<div>plain ASCII headword</div>",
            "test\U0001F600": "<div>headword with an astral emoji</div>",
            "test\U00020000": "<div>headword with CJK Extension B</div>",
            "testing": "<div>longer ASCII headword</div>",
        },
        title="Astral Plane Dictionary",
        description="Headwords above U+FFFF",
        block_size=256,
    ))
    FixtureDate.fixture_day = 4

    write("nested.mdx", MDictWriter(
        {"apple": '<img src="assets/picture.svg"><p>Nested asset example</p>'},
        title="Nested Asset Dictionary",
        description="Entry-only reference to a nested loose asset",
    ))

    write("multipart.mdx", MDictWriter(
        {
            "reverse": '<link rel="stylesheet" href="reverse.css"><div class="reverse">reverse</div>',
        },
        title="Multipart Resource Dictionary",
        description="MDD ordering fixture",
        block_size=256,
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

    # Base-volume resources must precede multipart.1.mdd resources. Keeping
    # the stylesheet in the base volume catches lexical/open-order mismatches.
    write("multipart.mdd", MDictWriter(
        {
            "\\reverse.css": b'.reverse { color: rgb(12, 34, 56); }\n',
            "\\duplicate.txt": b"base volume wins",
        },
        title="multipart base resources", description="MDD base fixture", is_mdd=True,
    ))
    write("multipart.1.mdd", MDictWriter(
        {
            "\\part-one.txt": b"numbered volume",
            "\\duplicate.txt": b"numbered duplicate",
        },
        title="multipart numbered resources", description="MDD part fixture", is_mdd=True,
    ))


if __name__ == "__main__":
    main()
