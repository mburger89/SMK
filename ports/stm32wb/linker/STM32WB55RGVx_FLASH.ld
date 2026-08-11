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

  ._user_heap_stack :
  {
    . = ALIGN(8);
    PROVIDE ( end = . );
    PROVIDE ( _end = . );
    . = . + _Min_Heap_Size;
    . = . + _Min_Stack_Size;
    . = ALIGN(8);
  } >RAM

  /* cmsis-device-wb's startup_stm32wb55xx_cm4.s unconditionally references
     _sMB_MEM2/_eMB_MEM2/_siMB_MEM2 (real finding from this task's build —
     not anticipated by the plan draft): its Reset_Handler always runs an
     INIT_DATA copy (flash -> RAM, same mechanism as .data) into a
     ".MB_MEM2" region before falling through to __libc_init_array/main, so
     the symbols must exist even though nothing places data into this
     section yet. Kept as its own tiny AT>FLASH output section (currently
     empty: _sMB_MEM2 == _eMB_MEM2, so Reset_Handler's copy loop is a no-op)
     rather than merged into .mailbox_ram below, since the two have
     different loading semantics (INIT_DATA copy-from-flash vs. NOLOAD
     hardware-reset-zeroed) and different owners (ST's vendored startup
     code vs. Task 6's own IPCC mailbox tables). Both share the
     MAILBOX_RAM memory region since SRAM2A is exactly where dual-core
     WB55 designs put CPU2-visible state. */
  .MB_MEM2 :
  {
    . = ALIGN(4);
    _sMB_MEM2 = .;
    *(.MB_MEM2)
    . = ALIGN(4);
    _eMB_MEM2 = .;
  } >MAILBOX_RAM AT> FLASH
  _siMB_MEM2 = LOADADDR(.MB_MEM2);

  /* Task 6 places the IPCC mailbox tables here via
     __attribute__((section(".mailbox_ram"))) — CPU2 can only access
     SRAM2A/SRAM2B, so these buffers must not land in ordinary .bss (RAM,
     above). NOLOAD: zero-initialized by hardware reset state, not the C
     runtime's .bss zero-fill loop (this region is outside RAM above, so
     Reset_Handler's zero-fill loop never touches it). */
  .mailbox_ram (NOLOAD) :
  {
    . = ALIGN(4);
    *(.mailbox_ram)
    . = ALIGN(4);
  } >MAILBOX_RAM

  /DISCARD/ :
  {
    libc.a ( * )
    libm.a ( * )
    libgcc.a ( * )
  }
}
