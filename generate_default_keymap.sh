#!/usr/bin/env bash
# Compiles every board's keymap (boards/*.json) to the binary payload format
# `decodeKeymapPayload` (Sources/SMKCore/KeymapBinary.swift) decodes, and
# emits them as Swift byte-array literals -- so no board parses JSON at boot.
# Run after changing any boards/*.json or keymap.json, and commit the
# regenerated Sources/SMKCore/DefaultKeymapGenerated.swift and
# Tests/SMKCoreTests/BoardPayloadsGenerated.swift.
#
# See docs/superpowers/specs/2026-08-21-binary-keymap-format-design.md for
# the payload layout this produces, and
# docs/superpowers/specs/2026-08-21-retire-cjson-design.md for why every
# board (not just the three sharing keymap.json) is compiled this way.
#
#   ./generate_default_keymap.sh
set -euo pipefail
cd "$(dirname "$0")"

python3 - <<'PY'
import json, pathlib

manifest = json.load(open("keycodes.json"))
usage_by_token = {e["token"]: e["usage"] for e in manifest["keyboard"]}

# Fixed USB HID modifier bitmask -- Modifier.rawValue in
# Sources/SMKCore/Modifier.swift, bits 0-7 LSB first. This is a stable USB
# HID/report convention, not part of the generated key vocabulary, so
# (unlike `key:` usages) it is not derived from keycodes.json.
modifier_bits = {
    "leftCtrl": 0x01, "leftShift": 0x02, "leftAlt": 0x04, "leftGUI": 0x08,
    "rightCtrl": 0x10, "rightShift": 0x20, "rightAlt": 0x40, "rightGUI": 0x80,
}

# KeymapCellTag's raw values (KeymapBinary.swift) -- the wire format's tag
# byte. Renumbering these here without also updating that enum breaks every
# firmware build silently (Package.swift globs SMKCore; only the six
# CMakeLists and this generator would still agree with each other, not with
# the decoder).
TAG_NONE, TAG_KEY, TAG_MOD, TAG_MO, TAG_TG, TAG_TRANS, TAG_TOGGLE_CONN, TAG_MACRO = range(8)


def encode_cell(token):
    if token == "none":
        return (TAG_NONE, 0)
    if token in ("trans", "transparent"):
        return (TAG_TRANS, 0)
    if token == "toggle_conn":
        return (TAG_TOGGLE_CONN, 0)
    if token.startswith("key:"):
        name = token[4:]
        if name not in usage_by_token:
            raise SystemExit("unknown key token: %r" % token)
        return (TAG_KEY, usage_by_token[name])
    if token.startswith("mod:"):
        name = token[4:]
        if name not in modifier_bits:
            raise SystemExit("unknown modifier token: %r" % token)
        return (TAG_MOD, modifier_bits[name])
    if token.startswith("mo:"):
        return (TAG_MO, int(token[3:]))
    if token.startswith("tg:"):
        return (TAG_TG, int(token[3:]))
    if token.startswith("macro:"):
        return (TAG_MACRO, int(token[6:]))
    raise SystemExit("unrecognized keymap cell token: %r" % token)


# Ordered deliberately: the generated #if/#elseif chain follows this order,
# and smk_kbd MUST be last because it is the #else fallback -- both for the
# ESP32-C6 reference board (whose CMake defines no SMK_BOARD_* flag unless
# Kconfig selects the test board) and for the host `swift test` build, which
# defines none either. Adding a board means adding boards/<name>.json and an
# entry here.
BOARDS = [
    "nrf52840dk",
    "feather_nrf52840",
    "stm32f4_blackpill",
    "xiao_m0",
    "stm32wb_nucleo",
    "kbd_rp2040",
    "test_board",
    "smk_kbd",
]


def compile_board(name):
    spec = json.load(open("boards/%s.json" % name))
    matrix = spec["matrix"]
    rows = matrix["rows"]
    cols = matrix["cols"]
    cols_are_driven = 1 if matrix["colsAreDriven"] else 0

    # `layersFrom` keeps the three boards whose layout IS keymap.json from
    # holding three copies of it that can drift apart.
    if "layersFrom" in spec:
        layers = json.load(open(spec["layersFrom"]))["layers"]
    else:
        layers = spec["layers"]

    row_count = len(rows)
    col_count = len(cols)

    # A 0x0 matrix (feather_nrf52840: no matrix is wired to that board) can
    # carry no layers at all -- decodeKeymapPayload deliberately rejects a
    # *declared* layer whose matrix is 0x0, because a six-byte payload
    # claiming 200 empty layers would otherwise blank a working keyboard
    # (see KeymapBinary.swift's guard). Encoding layerCount=0 is the correct
    # representation: LayerEngine then leaves `keymaps` empty, which for a
    # board with no matrix is behaviourally identical to the [[[]]] its JSON
    # declared -- getAction() resolves to .none either way, and scan() never
    # reports a press because there are no pins to scan.
    if row_count == 0 or col_count == 0:
        for layer in layers:
            for row in layer:
                if row:
                    raise SystemExit(
                        "%s declares a 0x0 matrix but carries layer data" % name)
        layers = []

    layer_count = len(layers)
    macro_count = 0  # No board layout carries macros; the format reserves the byte.

    for li, layer in enumerate(layers):
        if len(layer) != row_count:
            raise SystemExit("%s layer %d has %d rows, matrix declares %d"
                             % (name, li, len(layer), row_count))
        for ri, row in enumerate(layer):
            if len(row) != col_count:
                raise SystemExit("%s layer %d row %d has %d cols, matrix declares %d"
                                 % (name, li, ri, len(row), col_count))

    for field, value in (("rowCount", row_count), ("colCount", col_count),
                         ("layerCount", layer_count), ("macroCount", macro_count)):
        if not (0 <= value <= 0xFF):
            raise SystemExit("%s: %s=%d does not fit in one header byte"
                             % (name, field, value))
    for field, pins in (("row", rows), ("col", cols)):
        for pin in pins:
            if not (0 <= pin <= 0xFF):
                raise SystemExit("%s: %s pin %d does not fit in one byte"
                                 % (name, field, pin))

    payload = bytearray()
    payload += bytes([row_count, col_count, cols_are_driven,
                      layer_count, macro_count, 0])  # reserved=0
    payload += bytes(rows)
    payload += bytes(cols)
    for layer in layers:
        for row in layer:
            for token in row:
                tag, param = encode_cell(token)
                if not (0 <= param <= 0xFF):
                    raise SystemExit("%s: cell %r encodes a parameter that "
                                     "does not fit in one byte" % (name, token))
                payload += bytes([tag, param])
    return spec, payload


compiled = [(name,) + compile_board(name) for name in BOARDS]

BANNER = ["// Generated by generate_default_keymap.sh from boards/*.json.",
          "// Do not edit by hand -- edit the board file and re-run the script.",
          ""]


def byte_lines(payload, indent="    "):
    out = []
    for i in range(0, len(payload), 16):
        chunk = payload[i:i + 16]
        out.append(indent + ", ".join(str(b) for b in chunk) + ",")
    return out


lines = list(BANNER)
lines += [
    "/// This board's keymap, pre-encoded in the version-2 binary payload",
    "/// format `decodeKeymapPayload` (KeymapBinary.swift) decodes -- so the",
    "/// boot path gets both the GPIO matrix (via `Config(payload:)`) and the",
    "/// layers without parsing any JSON. Compiled from boards/<name>.json;",
    "/// see docs/superpowers/specs/2026-08-21-binary-keymap-format-design.md",
    "/// for the byte layout.",
    "///",
    "/// The `#else` board (smk_kbd) is also what the host `swift test` build",
    "/// sees, since no SMK_BOARD_* flag is defined there.",
]
for index, (name, spec, payload) in enumerate(compiled):
    define = spec.get("define")
    if define is None:
        if index != len(compiled) - 1:
            raise SystemExit("the board with no `define` must be last in BOARDS")
        lines.append("#else")
    else:
        lines.append(("#if " if index == 0 else "#elseif ") + define)
    lines.append("// %s (%d bytes)" % (name, len(payload)))
    lines.append("let defaultKeymapBytes: [UInt8] = [")
    lines += byte_lines(payload)
    lines.append("]")
lines += ["#endif", ""]

out = pathlib.Path("Sources/SMKCore/DefaultKeymapGenerated.swift")
out.write_text("\n".join(lines))

# Every board's payload, for host tests. The shipped file above exposes only
# the one this board's flags select, which on the host build is always
# smk_kbd -- so without this fixture seven of the eight boards would never be
# round-tripped against their JSON by any test.
test_lines = list(BANNER)
test_lines += [
    "// Every board's compiled payload, so host tests can round-trip all of",
    "// them. See Tests/SMKCoreTests/BoardPayloadRoundTripTests.swift.",
    "",
    "struct GeneratedBoardPayload {",
    "    let board: String",
    "    let bytes: [UInt8]",
    "}",
    "",
    "let generatedBoardPayloads: [GeneratedBoardPayload] = [",
]
for name, _spec, payload in compiled:
    test_lines.append('    GeneratedBoardPayload(board: "%s", bytes: [' % name)
    test_lines += byte_lines(payload, indent="        ")
    test_lines.append("    ]),")
test_lines += ["]", ""]

test_out = pathlib.Path("Tests/SMKCoreTests/BoardPayloadsGenerated.swift")
test_out.write_text("\n".join(test_lines))

print("wrote %s and %s" % (out, test_out))
for name, _spec, payload in compiled:
    print("  %-20s %5d bytes" % (name, len(payload)))
PY
