/*
 * cctl_probe.c -- verify that U-Boot enabled mcache_ctl.CCTL_SUEN.
 *
 * The AndeStar V5 user CCTL CSRs (ucctlbeginaddr 0x80b / ucctlcommand 0x80c)
 * are accessible from S/U mode ONLY when M-mode (U-Boot harts_early_init) sets
 * mcache_ctl.CCTL_SUEN. If it is clear, this csrr traps as an illegal
 * instruction -> SIGILL. If it is set, the read returns and we print the value.
 * (See PATCHES/0003 -- U-Boot CCTL_SUEN -- and PATCHES/0004 -- the kernel
 * cmo-andes-a25 provider that depends on it.)
 *
 * Build (static, soft-atomic musl toolchain):
 *   TC=~/projects/riscv32-ilp32d--musl--stable-2025.08-1
 *   $TC/bin/riscv32-buildroot-linux-musl-gcc -static -O2 -o cctl_probe cctl_probe.c
 *
 * Run on the board:  ./cctl_probe
 * Observed (2026-06-11): "CCTL_SUEN OK: ucctlbeginaddr=0x0 (csrr 0x80b did not trap)"
 */
#include <stdio.h>

int main(void)
{
	unsigned long v;

	__asm__ volatile ("csrr %0, 0x80b" : "=r"(v));	/* ucctlbeginaddr */
	printf("CCTL_SUEN OK: ucctlbeginaddr=0x%lx (csrr 0x80b did not trap)\n", v);
	return 0;
}
