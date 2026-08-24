# Flash cost of cJSON, measured

Companion to `docs/superpowers/specs/2026-08-21-retire-cjson-design.md` and
`docs/superpowers/plans/2026-08-23-retire-cjson.md`.

The spec's "Why bother" section leads with an *estimated* 15–25 KB of flash,
explicitly flagged as unmeasured ("the whole first argument for doing this is
a number nobody has measured yet"). This file is that measurement.

## Method

Clean build of every target, then `arm-none-eabi-size` on the linked ELF
(the extensionless `smk_<target>` file in each build directory — the `.hex`,
`.bin` and `.uf2` next to it are derived) and `idf.py size` for ESP32-C6,
which is RISC-V and has no ARM ELF.

Baseline taken on commit `55298f4`, before any code change.

## cJSON's own contribution

Summed sizes of every cJSON symbol left in one linked image:

```
arm-none-eabi-nm --print-size --size-sort build_stm32f4/smk_stm32f4 | grep -i cjson
```

**82 symbols, 7,992 bytes (7.8 KB)** on STM32F4.

That is well under the spec's 15–25 KB estimate, and the reason is worth
recording: `cJSON.c` is 3,206 lines, but `--gc-sections` already drops
everything the firmware never calls — the printer, the minifier, the
comparison and duplication helpers. Only the parser half survives to be
removed. The realised saving should be a little larger than 7.8 KB, since
the board's `configJson` string literal goes too and its binary payload
replacement is several times smaller, but 7.8 KB is the honest order of
magnitude for the dependency itself.

## Per-target sizes

`text` is what lands in flash; `data` is initialised RAM (also stored in
flash); `bss` is zero-initialised RAM.

| Target | text before | data before | bss before | text after | delta |
|---|---|---|---|---|---|
| rp2040 pico | 94,056 | 76 | 3,612 | TBM | TBM |
| rp2040 pico_w | 203,460 | 76 | 7,976 | TBM | TBM |
| rp2350 pico2 | 87,456 | 16 | 3,240 | TBM | TBM |
| rp2350 pico2_w | 192,412 | 16 | 7,608 | TBM | TBM |
| smk_kbd_rp2040 | 225,496 | 76 | 6,588 | TBM | TBM |
| nrf52840dk | 379,564 | 3,652 | 9,688 | TBM | TBM |
| feather_nrf52840 | 340,580 | 3,312 | 8,808 | TBM | TBM |
| stm32f4 blackpill | 157,308 | 2,828 | 3,344 | TBM | TBM |
| stm32wb nucleo | 315,488 | 3,164 | 11,428 | TBM | TBM |
| samd21 xiao_m0 | 108,512 | 2,828 | 9,608 | TBM | TBM |
| esp32c6 (flash .text) | 550,928 | — | 5,392 | TBM | TBM |
| esp32c6 (flash .rodata) | 85,480 | — | — | TBM | TBM |

`TBM` = to be measured, filled in by the plan's Task 9 once cJSON is gone.

## Note on SAMD21

The spec argues the flash saving matters most on SAMD21 (256 KB part), and
that holds up: 108,512 bytes of 262,144 is 41% used, so 7.8 KB is about 3%
of the part and roughly 5% of what is currently free. Meaningful, not
decisive.
