/* Linker script for the Adafruit Feather nRF52840 Express, whose factory
 * UF2 bootloader + SoftDevice occupy flash this project doesn't control —
 * unlike ports/nrf52840/CMakeLists.txt's default nrf52840dk build, which
 * links against the stock ${NRF5_MDK}/nrf52840_xxaa.ld starting at flash
 * address 0x0 (no bootloader present on that board).
 *
 * Flash layout on this board (Adafruit's published memory map — see
 * docs/superpowers/specs, "Feather nRF52840 support" design note):
 *   0x000000 - 0x001000   MBR
 *   0x001000 - APP_START  factory SoftDevice (S140) — unused by this app
 *                         (BLE here is Nordic's SoftDevice Controller
 *                         library, statically linked into this binary, not
 *                         a call into the flashed SoftDevice blob), but
 *                         still occupies real flash the app must not
 *                         overlap
 *   APP_START - 0x0ED000  application region (this build lives here)
 *   0x0ED000 - 0x0F4000   user data (bootloader settings/bonding storage)
 *   0x0F4000 - 0x100000   UF2 bootloader itself
 *
 * APP_START depends on which SoftDevice version shipped on the actual
 * board: 0x26000 for S140 v6, 0x27000 for v7. This file hardcodes the
 * higher (v7) address, 0x27000, because it's safe either way — a v6 board
 * just wastes 4KB of unused flash below the app, whereas hardcoding the
 * lower v6 address on a v7 board would place code inside flash the
 * SoftDevice still considers reserved. CONFIRM the real value by reading
 * INFO_UF2.TXT off the board's mounted bootloader drive before flashing
 * (see CLAUDE.md's Feather nRF52840 Express section) — if it doesn't match
 * 0x27000, update ORIGIN/LENGTH below AND the --base value passed to
 * uf2conv.py in ports/nrf52840/CMakeLists.txt (kept as a separate literal
 * there, not derived from this file, since CMake has no visibility into a
 * linker script's contents).
 *
 * RAM is left at the chip's full range (unlike flash, nothing reserves RAM
 * ahead of time here — SoftDevice-style RAM carve-outs only apply once
 * something calls sd_softdevice_enable()/an SDC equivalent at runtime, and
 * this board's bring-up scope is USB HID only, no BLE init at runtime).
 */

SEARCH_DIR(.)
GROUP(-lgcc -lc -lnosys)

MEMORY
{
  FLASH (rx) : ORIGIN = 0x00027000, LENGTH = 0x000CD000
  RAM (rwx) : ORIGIN = 0x20000000, LENGTH = 0x40000
}

INCLUDE "nrf_common.ld"
