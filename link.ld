OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 128K }
SECTIONS {
  . = 0x00000000;
  .text : { *(.text.init) *(.text*) } > RAM
  .rodata : { *(.rodata*) *(.srodata*) } > RAM
  . = ALIGN(4);
  .data : { *(.data*) *(.sdata*) } > RAM
  . = ALIGN(4);
  .bss : {
    _bss_start = .;
    *(.bss*) *(.sbss*) *(COMMON)
    . = ALIGN(4);
    _bss_end = .;
  } > RAM
  . = ALIGN(16);
  _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
