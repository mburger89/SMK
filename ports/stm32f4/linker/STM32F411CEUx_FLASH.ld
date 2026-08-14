/* Linker script for STM32F411CEU6 (WeAct Black Pill): 512KB flash starting
 * at 0x08000000, 128KB SRAM starting at 0x20000000. Hand-written — ST's
 * cmsis-device-f4 repo ships startup assembly and CMSIS device headers, but
 * no GCC linker script (only ARM/IAR toolchain templates), confirmed via
 * that repo's GitHub tree during this plan's research.
 *
 * Symbol names below (_estack, _sidata, _sdata, _edata, _sbss, _ebss) must
 * match exactly what startup_stm32f411xe.s's Reset_Handler references —
 * confirmed by reading that file directly during this plan's research.
 */

MEMORY
{
  FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 512K
  RAM (xrw)   : ORIGIN = 0x20000000, LENGTH = 128K
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

  /* No /DISCARD/ block for libc.a/libm.a/libgcc.a here (a previous version
   * of this file had one) -- it never took effect. The .text section above
   * uses unrestricted wildcards (*(.text), *(.rodata), ...) with no
   * archive/file selector, and GNU ld assigns each input section to the
   * FIRST output-section rule that matches it in script order -- so those
   * archives' .text/.rodata/.data/.bss contributions were already claimed
   * by .text/.data/.bss above before a later /DISCARD/ rule could ever see
   * them (confirmed empirically: building a minimal repro with this
   * project's own arm-none-eabi-gcc/ld and an early unrestricted `.text :
   * { *(.text) }` rule followed by `/DISCARD/ { liba.a(*) }`, the archived
   * function still linked into the final .text section and symbol table).
   * Unused code from these archives is instead pruned by
   * -ffunction-sections/-fdata-sections (CMakeLists.txt's C_ASM_FLAGS) +
   * -Wl,--gc-sections (its link options) -- the real mechanism for this,
   * not a /DISCARD/ block matched against files that never reach it. */
}
