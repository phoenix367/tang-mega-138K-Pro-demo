/*
 * ucsr_test.c -- are the Andes user CSRs kept per process across context switches?
 *
 *   ucode (0x801): the DSP's overflow / saturation flag (P extension, mmsc_cfg.EDSP)
 *   uitb  (0x800): the CoDense exec.it table base (xandescodense, mmsc_cfg.ECD)
 *
 * N processes each write their own value to both CSRs, then yield the CPU over and
 * over and read them back.  A kernel that does not switch these CSRs lets one
 * process see another's value.  Exit 0 = every read back was the process's own.
 *
 *   ucsr_test [procs=4] [rounds=20000]
 */
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

static unsigned long rd_ucode(void) { unsigned long v; __asm__ volatile ("csrr %0, 0x801" : "=r"(v)); return v; }
static void wr_ucode(unsigned long v) { __asm__ volatile ("csrw 0x801, %0" :: "r"(v)); }
static unsigned long rd_uitb(void) { unsigned long v; __asm__ volatile ("csrr %0, 0x800" : "=r"(v)); return v; }
static void wr_uitb(unsigned long v) { __asm__ volatile ("csrw 0x800, %0" :: "r"(v)); }

int main(int argc, char **argv)
{
    int procs = argc > 1 ? atoi(argv[1]) : 4, rounds = argc > 2 ? atoi(argv[2]) : 20000;

    /* which bits stick: ucode has the OV flag (bit 0), uitb a 4-byte aligned base */
    wr_ucode(1); unsigned long ov = rd_ucode() & 1; wr_ucode(0);
    wr_uitb(0x12345670); unsigned long base_ok = rd_uitb() == 0x12345670; wr_uitb(0);
    printf("ucode OV bit writable: %s, uitb holds a written base: %s\n", ov ? "yes" : "no", base_ok ? "yes" : "no");

    for (int p = 0; p < procs; p++) {
        if (fork() == 0) {
            unsigned long my_ucode = p & 1, my_uitb = 0x10000000 + 0x100 * (p + 1);
            int bad_ucode = 0, bad_uitb = 0;
            for (int r = 0; r < rounds; r++) {
                wr_ucode(my_ucode);
                wr_uitb(my_uitb);
                sched_yield();
                if (ov && (rd_ucode() & 1) != my_ucode) bad_ucode++;
                if (base_ok && rd_uitb() != my_uitb) bad_uitb++;
            }
            printf("  proc %d: ucode %d / uitb %d of %d reads were someone else's\n", p, bad_ucode, bad_uitb, rounds);
            fflush(stdout);
            _exit(bad_ucode || bad_uitb);
        }
    }
    int fails = 0, st;
    while (wait(&st) > 0)
        if (!WIFEXITED(st) || WEXITSTATUS(st)) fails++;
    printf("UCSRTEST %s (%d of %d processes saw foreign values)\n", fails ? "FAILED" : "PASSED", fails, procs);
    return fails ? 1 : 0;
}
