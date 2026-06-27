OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwxa) : ORIGIN = 0x80000000, LENGTH = 0x200000 }
SECTIONS {
  . = 0x80000000;
  .text   : { *(.text.init) *(.text*) } > RAM
  .rodata : { *(.rodata*) *(.srodata*) } > RAM
  .data   : { *(.data*) *(.sdata*) } > RAM
  .bss    : { __bss_start = .; *(.bss*) *(.sbss*) *(COMMON); __bss_end = .; } > RAM
  . = ALIGN(16);
  _stack_top = 0x80100000;
}
