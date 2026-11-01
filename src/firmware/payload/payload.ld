/* Link the bootm payload to run from DRAM 0x100000 (U-Boot's load/entry addr).
   Low DRAM, well clear of U-Boot which relocates to the top of the 256 MB. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
	. = 0x00100000;

	/* _start MUST be the very first byte (it's the entry point 0x100000).
	   KEEP it and discard orphan note/attr sections that would otherwise be
	   placed ahead of .text and get executed as garbage. */
	.text : {
		KEEP(*(.text.start))
		*(.text*)
	}
	.rodata : { *(.rodata*) }
	.data   : { *(.data*) }
	.bss    : { *(.bss*) *(COMMON) }

	. = ALIGN(16);
	. += 0x1000;          /* 4 KB stack */
	_stack_top = .;

	/DISCARD/ : {
		*(.note*)
		*(.comment)
		*(.eh_frame*)
		*(.riscv.attributes)
	}
}
