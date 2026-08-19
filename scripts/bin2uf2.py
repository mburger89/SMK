#!/usr/bin/env python3
"""Minimal .bin -> .uf2 converter (UF2 spec: github.com/microsoft/uf2).

Used by ports/samd21 to produce a drag-and-drop image for uf2-samdx1-style
bootloaders (SAMD21 family ID 0x68ed2b88, app base 0x2000). Kept in-repo so
the build has no network / external-tool dependency. 256-byte payload per
512-byte block, familyID flag set — the standard modern UF2 layout.
"""

import argparse
import struct
import sys

UF2_MAGIC_START0 = 0x0A324655  # "UF2\n"
UF2_MAGIC_START1 = 0x9E5D5157
UF2_MAGIC_END = 0x0AB16F30
FLAG_FAMILY_ID_PRESENT = 0x00002000
PAYLOAD_SIZE = 256


def bin_to_uf2(data: bytes, base: int, family: int) -> bytes:
    num_blocks = (len(data) + PAYLOAD_SIZE - 1) // PAYLOAD_SIZE
    out = bytearray()
    for block_no in range(num_blocks):
        chunk = data[block_no * PAYLOAD_SIZE:(block_no + 1) * PAYLOAD_SIZE]
        chunk = chunk.ljust(PAYLOAD_SIZE, b"\x00")
        header = struct.pack(
            "<IIIIIIII",
            UF2_MAGIC_START0,
            UF2_MAGIC_START1,
            FLAG_FAMILY_ID_PRESENT,
            base + block_no * PAYLOAD_SIZE,
            PAYLOAD_SIZE,
            block_no,
            num_blocks,
            family,
        )
        out += header + chunk + b"\x00" * (476 - PAYLOAD_SIZE) + struct.pack("<I", UF2_MAGIC_END)
    return bytes(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=lambda v: int(v, 0), required=True,
                        help="flash address of the image start (e.g. 0x2000)")
    parser.add_argument("--family", type=lambda v: int(v, 0), required=True,
                        help="UF2 family ID (e.g. 0x68ed2b88 for SAMD21)")
    parser.add_argument("bin_in")
    parser.add_argument("uf2_out")
    args = parser.parse_args()

    with open(args.bin_in, "rb") as f:
        data = f.read()
    uf2 = bin_to_uf2(data, args.base, args.family)
    with open(args.uf2_out, "wb") as f:
        f.write(uf2)
    print(f"{args.uf2_out}: {len(uf2) // 512} blocks, {len(data)} bytes at {hex(args.base)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
