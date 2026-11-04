ENTRY(_start)
__ram_size = DEFINED(__ram_bytes) ? __ram_bytes : 16384;
ASSERT(__ram_size == 8192 || __ram_size == 16384, "RAM_BYTES must be 8192 or 16384")

MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 64K
    /* The data memory is a separate array that also decodes from zero,
       so its natural range overlaps ROM completely. GNU ld cannot express
       that, which used to cap usable ROM at the old 8 KiB RAM origin. The SoC
       accepts this alias on the data port (RAM_DATA_BASE in rv32i_soc.sv), so
       the linker gets a non-overlapping view while the hardware still uses one
       array. RAM_BYTES must match the board's DMEM_WORDS * 4. */
    RAM (rwx) : ORIGIN = 0x40000000, LENGTH = __ram_size
}

SECTIONS
{
    .text :
    {
        KEEP(*(.text.init))
        *(.text*)
        . = ALIGN(4);
    } > ROM

    .data :
    {
        . = ALIGN(4);
        __data_start = .;
        *(.rodata*)
        *(.srodata*)
        *(.data*)
        *(.sdata*)
        . = ALIGN(4);
        __data_end = .;
    } > RAM AT> ROM
    __data_load_start = LOADADDR(.data) + 0x20000000;

    .bss (NOLOAD) :
    {
        __bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM

    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
    _stack_bottom = _stack_top - 1024;
    ASSERT(__bss_end <= _stack_bottom, "RAM data overlaps reserved 1 KiB stack")
    /DISCARD/ : { *(.eh_frame*) *(.comment*) }
}
