/*
 * amo_probe.c -- characterize hardware atomics on the no-coherence-manager A25,
 * SAFELY. On this core an AMO that can't gain exclusive ownership wedges the
 * issuing task uninterruptibly (see atomic_test). To probe without needing a
 * reboot, each atomic runs in a FORKED CHILD with a timeout: if the child wedges
 * the parent still reports, and the board stays up (the wedged child is unkillable
 * but harmless until the next reboot).
 *
 * Resolves the open question: does a HOT (owned/cached) line amo work in U-mode,
 * or does it wedge like a cold one? (Bare-metal M-mode: hot works, cold hangs.)
 *
 * Build: see tests/Makefile.  amoadd.w is base 'A' (assembles directly).
 */
#include <stdio.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/wait.h>

#define BUFSZ (256*1024)

static inline uint32_t amoadd_w(volatile uint32_t *p, uint32_t v)
{ uint32_t o; __asm__ volatile("amoadd.w %0,%2,%1":"=r"(o),"+A"(*p):"r"(v):"memory"); return o; }

/* HOT: a line we just wrote AND read back -> should be owned/modified in L1 */
static void t_hot(volatile uint32_t *out)
{
	volatile uint32_t v = 100; uint32_t t = v; (void)t;   /* own the line */
	*out = amoadd_w(&v, 1);                                /* expect old=100 */
}
/* COLD: amo on a line evicted from L1 by walking a >>32 KB buffer */
static uint32_t cold_buf[BUFSZ/4];
static void t_cold(volatile uint32_t *out)
{
	for (unsigned i=0;i<BUFSZ/4;i++) cold_buf[i]+=1;       /* evict */
	*out = amoadd_w(&cold_buf[0], 1);
}

/* run fn() in a child; return 1 if it finished within `secs`, 0 if it wedged */
static int run(const char *nm, void (*fn)(volatile uint32_t*), int secs)
{
	volatile uint32_t *sh = mmap(0, 4096, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_ANONYMOUS, -1, 0);
	*sh = 0xdeadbeef;
	int pfd[2]; if (pipe(pfd)) return -1;
	pid_t pid = fork();
	if (pid == 0) { close(pfd[0]); fn(sh); char c=1; (void)!write(pfd[1],&c,1); _exit(0); }
	close(pfd[1]);
	fd_set fs; FD_ZERO(&fs); FD_SET(pfd[0], &fs);
	struct timeval tv = { secs, 0 };
	int n = select(pfd[0]+1, &fs, 0, 0, &tv);
	if (n > 0) { printf("  %-5s COMPLETED -> amo old=%u  (WORKS)\n", nm, *sh); waitpid(pid,0,0); return 1; }
	printf("  %-5s no completion in %ds -> amo WEDGED (child stuck; board still up)\n", nm, secs);
	return 0;   /* leave the wedged child; cleared at next reboot */
}

int main(void)
{
	printf("A25 atomics probe (fork+timeout; wedge = no completion)\n");
	printf("amoadd.w on:\n");
	int hot  = run("hot",  t_hot,  3);   /* owned/cached line */
	int cold = run("cold", t_cold, 3);   /* evicted line */
	printf("=> hot=%s  cold=%s\n", hot?"WORKS":"WEDGED", cold?"WORKS":"WEDGED");
	printf("(amo*.d = RV64-only, illegal on this RV32 core; lr/sc cold livelocks too -- see atomic_test)\n");
	return 0;
}
