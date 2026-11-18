# RISC-V RV32I Linker Script for i2ca tests_rv32i environment
# Memory Map:
#   ROM (Flash/BRAM): 0x00000000 - 0x00003FFF (16 KB)
#   RAM (Data BRAM):  0x00008000 - 0x0000BFFF (16 KB)
#   TOHOST (MMIO):    0x0000C000
#   Stack Top:        0x0000BFFC (grows downward)

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
    RAM (rwx) : ORIGIN = 0x00008000, LENGTH = 16K
}

SECTIONS
{
    .text : {
        . = ALIGN(4);
        *(.text.init)
        *(.text .text.*)
        . = ALIGN(4);
        _etext = .;
    } > ROM

    .rodata : {
        . = ALIGN(4);
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(4);
        _erodata = .;
    } > ROM

    .data : {
        . = ALIGN(4);
        _sdata = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(4);
        _edata = .;
    } > RAM AT > ROM

    _sidata = LOADADDR(.data);

    .bss : {
        . = ALIGN(4);
        _sbss = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > RAM

    _stack_top = ORIGIN(RAM) + LENGTH(RAM) - 4;
}
