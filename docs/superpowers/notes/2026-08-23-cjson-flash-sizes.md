# Flash cost of cJSON, measured

Companion to `docs/superpowers/specs/2026-08-21-retire-cjson-design.md` and
`docs/superpowers/plans/2026-08-23-retire-cjson.md`.

The spec's "Why bother" section leads with an *estimated* 15-25 KB of flash,
explicitly flagged as unmeasured ("the whole first argument for doing this is
a number nobody has measured yet"). This file is that measurement.

## Headline

**The estimate was wrong, and wrong in the generous direction: the real
saving is 16-93 KB of `.text` per target.** Every one of the eleven builds
was measured before and after, clean, on the same machine.

## Method

Clean build of every target, then `arm-none-eabi-size` on the linked ELF
(the extensionless `smk_<target>` file in each build directory -- the `.hex`,
`.bin` and `.uf2` next to it are derived) and `idf.py size` for ESP32-C6,
which is RISC-V and has no ARM ELF.

Before: commit `55298f4`, ahead of any code change. After: commit `de737dd`,
with cJSON deleted.

## Results

| Target | text before | text after | delta | % |
|---|---|---|---|---|
| rp2040 pico | 94,056 | 76,016 | -18,040 | -19.2% |
| rp2040 pico_w | 203,460 | 185,604 | -17,856 | -8.8% |
| rp2350 pico2 | 87,456 | 69,056 | -18,400 | -21.0% |
| rp2350 pico2_w | 192,412 | 174,020 | -18,392 | -9.6% |
| smk_kbd_rp2040 | 225,496 | 207,480 | -18,016 | -8.0% |
| nrf52840dk | 379,564 | 316,168 | -63,396 | -16.7% |
| feather_nrf52840 | 340,580 | 276,360 | -64,220 | -18.9% |
| stm32f4 blackpill | 157,308 | 63,868 | -93,440 | -59.4% |
| stm32wb nucleo | 315,488 | 250,620 | -64,868 | -20.6% |
| samd21 xiao_m0 | 108,512 | 65,380 | -43,132 | -39.7% |
| esp32c6 flash `.text` | 550,928 | 535,152 | -15,776 | -2.9% |
| esp32c6 flash `.rodata` | 85,480 | 84,224 | -1,256 | -1.5% |

`data` and `bss` moved by at most a few hundred bytes anywhere and are
omitted; this change is almost entirely a `.text` story.

## Why it is so much more than cJSON's own size

Summing every cJSON symbol in one linked image gives only **7,992 bytes**
(82 symbols, STM32F4, measured on the before-build):

```
arm-none-eabi-nm --print-size --size-sort build_stm32f4/smk_stm32f4 | grep -i cjson
```

`cJSON.c` is 3,206 lines, but `--gc-sections` had already dropped the
printer, minifier, comparison and duplication helpers -- only the parser
half was ever linked. So 7.8 KB is the honest figure for cJSON itself.

The rest -- the other 85 KB on STM32F4 -- is **newlib's floating-point
conversion machinery, which cJSON was dragging in transitively**. cJSON
parses every number through `strtod` and prints through `sprintf("%g")`, and
those pull `_dtoa_r`, `_vfprintf_r` and their tables into the image. After
the deletion those symbols are simply absent:

```
arm-none-eabi-nm --print-size --size-sort build_stm32f4/smk_stm32f4 \
  | grep -Ei "dtoa|vfprintf|strtod|sprintf"     # no output
```

That also explains the spread across targets. The ports that saved 60-93 KB
(STM32F4, STM32WB, nRF52840, SAMD21) are the hand-rolled CMake ones that link
plain newlib; the RP2040 family saved a consistent ~18 KB because pico-sdk
already links newlib-nano with float printf disabled by default, so only
cJSON itself plus each board's `configJson` string literal was there to
remove. ESP32-C6 saved least (~16 KB of `.text`) because ESP-IDF's own
components pull in formatted-output support regardless of what SMK does, so
nothing transitive was freed there -- just cJSON and the literal.

Nobody had identified the transitive dependency before this was measured,
which is a fair argument for measuring rather than estimating in the first
place.

## Note on SAMD21

The spec argues the saving matters most on SAMD21 (256 KB part), and that is
where it lands hardest in proportional terms: **108,512 -> 65,380 bytes,
a 39.7% cut**, taking the part from 41% full to 25% full. That is the
difference between a port with a looming ceiling and one with room.
