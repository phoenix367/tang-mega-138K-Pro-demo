/*
 * Bare-metal "standalone" U-Boot payload for the Gowin AE350.
 *
 * Flashed to SPI flash 0x800000 (= CPU 0x80200000 in the XIP region) and
 * launched from the U-Boot prompt with:  bootm 0x80200000
 *
 * U-Boot's bootm copies this image into DRAM at the load address (0x100000)
 * and jumps to the entry point there. We then print on UART2 (already brought
 * up by U-Boot at 115200 8N1) to prove the hand-off, and loop forever.
 */

/* UART2 16550 block: base 0xf0300000 + reg-offset 0x20, reg-shift 2. */
#define UART2          0xf0300020u
#define UART_REG(n)    (*(volatile unsigned int *)(UART2 + ((n) << 2)))
#define UART_THR       UART_REG(0)
#define UART_LSR       UART_REG(5)
#define LSR_THRE       0x20u

static void uputc(char c)
{
	while (!(UART_LSR & LSR_THRE))
		;
	UART_THR = (unsigned int)c;
}

static void uputs(const char *s)
{
	for (; *s; s++) {
		if (*s == '\n')
			uputc('\r');
		uputc(*s);
	}
}

static void uput_dec(unsigned long v)
{
	char buf[12];
	int i = 0;

	if (v == 0) {
		uputc('0');
		return;
	}
	while (v) {
		buf[i++] = (char)('0' + (v % 10));
		v /= 10;
	}
	while (i)
		uputc(buf[--i]);
}

void payload_main(void)
{
	unsigned long n = 0;

	uputs("\n");
	uputs("============================================\n");
	uputs(" Hello from the bootm payload on the AE350! \n");
	uputs("============================================\n");
	uputs(" Bare-metal in DRAM @ 0x100000, UART2 console.\n");
	uputs(" U-Boot -> bootm -> this. The boot chain works.\n\n");

	for (;;) {
		uputs("payload tick ");
		uput_dec(n++);
		uputs("\n");
		for (volatile unsigned long d = 0; d < 4000000UL; d++)
			;
	}
}

/* Entry point: set a stack, call main. Linked first (.text.start). */
__attribute__((naked, section(".text.start"))) void _start(void)
{
	__asm__ volatile(
		".option push\n"
		".option norelax\n"
		"la sp, _stack_top\n"
		".option pop\n"
		"call payload_main\n"
		"1: j 1b\n");
}
