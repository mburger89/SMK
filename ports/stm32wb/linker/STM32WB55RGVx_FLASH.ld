/* Linker script for STM32WB55RGVx (NUCLEO-WB55RG): hand-written, same gap
 * as STM32F4's cmsis-device-f4 — cmsis-device-wb ships startup assembly and
 * CMSIS device headers but no GCC linker script tailored to this project's
 * dual-core memory split.
 *
 * Memory map from cmsis-device-wb's Include/stm32wb55xx.h (verified during
 * this plan's research): flash base 0x08000000 (up to 1MB total, but CPU1's
 * usable region is smaller than the full 1MB since CPU2's wireless-
 * coprocessor firmware occupies the top portion of flash, at an offset
 * controlled by the SFSA/SBRSA option bytes which this build-only pass
 * does not program; 448K is a conservative placeholder for CPU1's flash
 * region, matching STM32CubeWB's own BLE example projects' typical linker
 * scripts for this firmware combination — confirm against the real SFSA
 * value once hardware is available), SRAM1 base 0x20000000 (192K for CPU1's
 * stack/heap/.data/.bss), and a separate MAILBOX_RAM region at SRAM2A
 * (0x20030000, 32K) reserved for Task 6's mailbox tables — CPU2 can only
 * see SRAM2A/SRAM2B, so these buffers cannot live in ordinary .bss.
 *
 * Symbol names below (_estack, _sidata, _sdata, _edata, _sbss, _ebss) must
 * match exactly what startup_stm32wb55xx_cm4.s's Reset_Handler references.
 */

MEMORY
{
  FLASH (rx)      : ORIGIN = 0x08000000, LENGTH = 448K
  RAM (xrw)       : ORIGIN = 0x20000000, LENGTH = 192K
  MAILBOX_RAM (xrw) : ORIGIN = 0x20030000, LENGTH = 32K
}

_estack = ORIGIN(RAM) + LENGTH(RAM);
_Min_Heap_Size = 0x400;
_Min_Stack_Size = 0x400;

ENTRY(Reset_Handler)

SECTIONS
{
  .isr_vector :
  {
    . = ALIGN(4);
    KEEP(*(.isr_vector))
    . = ALIGN(4);
  } >FLASH

  .text :
  {
    . = ALIGN(4);
    *(.text)
    *(.text*)
    *(.rodata)
    *(.rodata*)
    *(.glue_7)
    *(.glue_7t)
    *(.eh_frame)
    KEEP (*(.init))
    KEEP (*(.fini))
    . = ALIGN(4);
    _etext = .;
  } >FLASH

  _sidata = LOADADDR(.data);

  .data :
  {
    . = ALIGN(4);
    _sdata = .;
    *(.data)
    *(.data*)
    . = ALIGN(4);
    _edata = .;
  } >RAM AT> FLASH

  .bss :
  {
    . = ALIGN(4);
    _sbss = .;
    *(.bss)
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    _ebss = .;
  } >RAM

  /* The vendored transport layer's two CPU1-private PLACE_IN_SECTION names —
     "BLE_DRIVER_CONTEXT" (hci_tl.c:48-51: hci_timer_id, HciAsynchEventQueue,
     pCmdBuffer, UserEventFlow) and "SYSTEM_DRIVER_CONTEXT" (shci_tl.c:45-48,
     the SHCI equivalents). Unlike MAPPING_TABLE/MB_MEM1/MB_MEM2 below, CPU2
     never reads any of these, so they belong in ordinary RAM, not SRAM2A.

     THEY MUST STAY HERE, immediately after .bss and BEFORE
     ._user_heap_stack. This project's newlib `_sbrk` has NO heap limit
     check whatsoever — disassembled from a linked image, it loads the break
     pointer, adds the increment, stores it back and returns, with no
     comparison against any bound. `._user_heap_stack` therefore only
     *reserves* _Min_Heap_Size + _Min_Stack_Size; it does not cap anything,
     and the heap really does grow unbounded past it. (SMK mallocs at boot
     regardless: decoding the compiled-in keymap payload allocates the
     layer arrays, and Embedded Swift's own allocations follow. This used
     to say cJSON parsing Main.swift's configJson exceeded the 0x800
     reserved here, which was true until cJSON was retired -- the argument
     does not depend on which allocator runs, only on _sbrk being
     unbounded.) An earlier revision of this file placed these two
     sections after ._user_heap_stack, which put them 0x800 above `end` —
     directly in the heap's growth path. That was invisible at the time only
     because Task 6 calls nothing in hci_tl.c/shci_tl.c, so both objects were
     dead-code-eliminated and both sections were size 0; the corruption would
     have appeared the moment Task 7 wired up real calls. Placing them here
     is also exactly where GNU ld's orphan-section heuristic puts them when
     the script doesn't name them at all (adjacent to .bss), which is what
     ST's own linker scripts rely on.

     NOLOAD: every one of these variables is assigned before first read, by
     hci_tl.c's / shci_tl.c's TlInit(). They sit above _ebss, so
     Reset_Handler's zero-fill loop does not cover them either way. */
  BLE_DRIVER_CONTEXT (NOLOAD) :
  {
    . = ALIGN(4);
    *(BLE_DRIVER_CONTEXT)
    . = ALIGN(4);
  } >RAM

  SYSTEM_DRIVER_CONTEXT (NOLOAD) :
  {
    . = ALIGN(4);
    *(SYSTEM_DRIVER_CONTEXT)
    . = ALIGN(4);
  } >RAM

  ._user_heap_stack :
  {
    . = ALIGN(8);
    PROVIDE ( end = . );
    PROVIDE ( _end = . );
    . = . + _Min_Heap_Size;
    . = . + _Min_Stack_Size;
    . = ALIGN(8);
  } >RAM

  /* ------------------------------------------------------------------
     IPCC mailbox regions (SRAM2A) — Task 6.
     ------------------------------------------------------------------
     Task 1 guessed that the vendored mailbox code would use a
     ".mailbox_ram" section name; the real vendored source does not. The
     vendored `tl_mbox.c` places its tables with ST's own
     `PLACE_IN_SECTION("...")` macro, whose expansion (confirmed by reading
     the vendored `stm32_wpan_common.h`, which is the file that defines it)
     is exactly:

         #define PLACE_IN_SECTION( __x__ )  __attribute__((section (__x__)))

     i.e. the section name is the string passed *verbatim*, with NO leading
     dot. `tl_mbox.c` uses three such names — "MAPPING_TABLE", "MB_MEM1"
     and "MB_MEM2" — matching ST's own linker scripts (e.g. STM32CubeWB's
     Projects/P-NUCLEO-WB55.Nucleo/Applications/BLE/BLE_HeartRate/
     STM32CubeIDE/STM32WB55RGVX_FLASH.ld, which matches `*(MAPPING_TABLE)`
     / `*(MB_MEM1)` / `*(MB_MEM2)`, all NOLOAD, all in its RAM_SHARED
     region). Task 1's reviewer flagged the dot/no-dot mismatch as a
     latent silent-misplacement bug; this is the fix — the patterns below
     match the vendor's real names.

     `*(.MB_MEM2)` (with the dot) is kept alongside `*(MB_MEM2)` only
     because cmsis-device-wb's startup_stm32wb55xx_cm4.s names the section
     that way in its own comments; no input section actually uses the
     dotted spelling today, and keeping the pattern costs nothing while
     removing any chance of a silently-orphaned input section.

     ORDER MATTERS: MAPPING_TABLE must come first, at the very start of
     SRAM2A (0x20030000). CPU2's wireless firmware is never *told* where
     `TL_RefTable` is — `TL_Init()` (tl_mbox.c) only fills the table in and
     calls HW_IPCC_Init(); CPU2 finds it at the fixed address configured by
     the IPCCDBA option byte, whose default is the SRAM2A base. Reordering
     these three output sections would silently break CPU2 hand-off.

     NOLOAD, matching ST: these are uninitialized buffers filled in at
     runtime by TL_Init()/TL_*_Init(). They sit outside the RAM region, so
     Reset_Handler's _sbss.._ebss zero-fill loop never touches them either.

     _siMB_MEM2: cmsis-device-wb's Reset_Handler unconditionally runs
     `INIT_DATA _sMB_MEM2, _eMB_MEM2, _siMB_MEM2` (a flash->RAM copy, same
     macro as .data). ST's own CubeIDE linker script never defines
     _siMB_MEM2 at all, because ST's CubeIDE startup file has no such copy
     — but the cmsis-device-wb startup file this port uses does, so the
     symbol must exist. Pointing it at _sMB_MEM2 turns that copy into a
     self-copy no-op, which is the behaviour ST's NOLOAD placement implies.
     (Task 1's version instead made this an `AT> FLASH` loaded section,
     which was harmless only while the section was empty: now that
     tl_mbox.c's CsBuffer really lands here, a loaded section would burn
     flash to copy uninitialized bytes over a buffer CPU2 also writes.) */
  MAPPING_TABLE (NOLOAD) :
  {
    . = ALIGN(4);
    *(MAPPING_TABLE)
    . = ALIGN(4);
  } >MAILBOX_RAM

  MB_MEM1 (NOLOAD) :
  {
    . = ALIGN(4);
    *(MB_MEM1)
    . = ALIGN(4);
  } >MAILBOX_RAM

  MB_MEM2 (NOLOAD) :
  {
    . = ALIGN(4);
    _sMB_MEM2 = .;
    *(MB_MEM2)
    *(.MB_MEM2)
    . = ALIGN(4);
    _eMB_MEM2 = .;
  } >MAILBOX_RAM
  _siMB_MEM2 = _sMB_MEM2;

  /* BLE_DRIVER_CONTEXT / SYSTEM_DRIVER_CONTEXT are NOT here — they are
     CPU1-private and live in RAM, placed above between .bss and
     ._user_heap_stack. See the comment there for why that position is
     load-bearing. */

  /DISCARD/ :
  {
    libc.a ( * )
    libm.a ( * )
    libgcc.a ( * )
  }
}
