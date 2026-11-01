/* dmactest -- exercise the AE350 ATCDMAC300 from Linux via /dev/mem.
 *   dmactest m2m          : 4 KB memory-to-memory copy, compare
 *   dmactest aud [req]    : 256 frames memory -> audio DATA register (FIX dst),
 *                           no handshake (req<0) or handshake with DstReqSel=req
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#define DMAC 0xF0C00000u
#define AUD  0xE8002000u
#define SCR  0x3FF00000u      /* scratch physical RAM: 8 KB near the top of DDR */
#define WDT  0xF0500000u
static volatile uint32_t *d, *aud, *scr, *wdt;
static void arm_wdt(void){ *(volatile uint16_t *)((char *)wdt + 0x18) = 0x5AA5; wdt[0x10/4] = (7u<<4)|(1u<<2)|(1u<<3)|1u; }
static void disarm_wdt(void){ *(volatile uint16_t *)((char *)wdt + 0x18) = 0x5AA5; wdt[0x10/4] = 0; }
static volatile uint32_t *evb;
static void evict(void){ volatile uint32_t s=0; for(int i=0;i<(2<<20)/4;i+=8) s+=evb[i]; (void)s; }
static void ch_setup(int ch, uint32_t ctrl, uint32_t size, uint32_t src, uint32_t dst){
    volatile uint32_t *c = d + (0x40 + 0x20*ch)/4;
    c[0] = 0;                                   /* disable */
    d[0x30/4] = (1u<<(16+ch)) | (1u<<(8+ch)) | (1u<<ch);   /* clear status */
    c[1] = size; c[2] = src; c[3] = 0; c[4] = dst; c[5] = 0; c[6] = 0; c[7] = 0;
    c[0] = ctrl | 1;                            /* enable */
}
static int ch_wait(int ch, int ms){
    for (int i=0;i<ms*10;i++){ uint32_t st=d[0x30/4]; if (st & (1u<<(16+ch))) return 0; if (st & ((1u<<(8+ch))|(1u<<ch))) return -2; usleep(100); }
    return -1;
}
int main(int argc,char**argv){
    int fd=open("/dev/mem",O_RDWR|O_SYNC);
    d=mmap(0,4096,PROT_READ|PROT_WRITE,MAP_SHARED,fd,DMAC);
    aud=mmap(0,4096,PROT_READ|PROT_WRITE,MAP_SHARED,fd,AUD);
    scr=mmap(0,8192,PROT_READ|PROT_WRITE,MAP_SHARED,fd,SCR);
    evb=mmap(0,2<<20,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS|MAP_POPULATE,-1,0);
    wdt=mmap(0,4096,PROT_READ|PROT_WRITE,MAP_SHARED,fd,WDT);
    printf("DMAC IDREV %08x CFG %08x CHEN %08x INT %08x\n", d[0], d[0x10/4], d[0x34/4], d[0x30/4]);
    d[0x20/4] = 1; usleep(1000);                /* DMAC reset */
    const char *mode = argc>1?argv[1]:"m2m";
    for (int i=0;i<1024;i++) scr[i] = 0xA5000000u + i;   /* source pattern */
    for (int i=0;i<1024;i++) scr[1024+i] = 0;
    evict();
    if (!strcmp(mode,"m2m")) {
        /* src INC, dst INC, word width, burst 8, no handshake, TC int unmasked */
        uint32_t ctrl = (2u<<21)|(2u<<18)|(0u<<14)|(0u<<12)|(3u<<24);
        ch_setup(0, ctrl, 1024, SCR, SCR+4096);
        int r = ch_wait(0, 1000);
        evict();
        int bad=0; for(int i=0;i<1024;i++) if (scr[1024+i] != 0xA5000000u+i) bad++;
        printf("m2m: wait %d INT %08x CHEN %08x TRANSIZE-left %u bad %d (dst[0]=%08x dst[1023]=%08x)\n",
               r, d[0x30/4], d[0x34/4], d[(0x40+4)/4]&0x3FFFFF, bad, scr[1024], scr[2047]);
    } else if (!strcmp(mode,"reg")) {
        /* DMAC READ of 4 words from the audio ID/DEPTH regs into scratch (src FIX) */
        printf("reg read test, watchdog armed\n"); fflush(stdout);
        arm_wdt();
        uint32_t ctrl = (2u<<21)|(2u<<18)|(2u<<14)|(0u<<12)|(0u<<24);
        ch_setup(0, ctrl, 4, AUD+0x2C, SCR+4096);
        int r = ch_wait(0, 500);
        disarm_wdt(); evict();
        printf("reg: wait %d INT %08x dst %08x %08x\n", r, d[0x30/4], scr[1024], scr[1025]);
    } else if (!strcmp(mode,"apb") || !strcmp(mode,"uart") || !strcmp(mode,"sd") || !strcmp(mode,"xip")) {
        /* DMAC READ of 4 words from another slave into scratch: external APB
         * (ddr_perf ID 0xF8000000), the SoC UART2 (0xF0300000 ID regs), or the
         * SD host ID on EXTS (0xE8020030) */
        uint32_t src = !strcmp(mode,"apb") ? 0xF8000000u : !strcmp(mode,"uart") ? 0xF0300000u :
                       !strcmp(mode,"xip") ? 0x80000000u : 0xE8020030u;   /* xip = boot flash, AHB slave */
        int inf = argc>2 ? atoi(argv[2]) : 0;            /* source bus interface index (DMACfg has two) */
        printf("%s read test from %08x via bus interface %d, watchdog armed\n", mode, src, inf); fflush(stdout);
        arm_wdt();
        uint32_t ctrl = (2u<<21)|(2u<<18)|((!strcmp(mode,"xip") ? 0u : 2u)<<14)|(0u<<12)|(0u<<24)|((uint32_t)inf<<31)|((uint32_t)inf<<30);
        ch_setup(0, ctrl, 4, src, SCR+4096);
        int r = ch_wait(0, 500);
        disarm_wdt(); evict();
        printf("%s: wait %d INT %08x dst %08x %08x\n", mode, r, d[0x30/4], scr[1024], scr[1025]);
    } else if (!strcmp(mode,"aud1")) {
        printf("single-word write to DATA, watchdog armed\n"); fflush(stdout);
        aud[0] = (1u<<5) | (1u<<2); aud[3] = 1024;
        uint32_t lvl0 = aud[1] & 0xFFFF;
        arm_wdt();
        int inf = argc>2 ? atoi(argv[2]) : 1;
        uint32_t ctrl = (2u<<21)|(2u<<18)|(0u<<14)|(2u<<12)|(0u<<24)|((uint32_t)inf<<31)|((uint32_t)inf<<30);   /* burst 1, dst FIX */
        ch_setup(0, ctrl, 1, SCR, AUD+8);
        int r = ch_wait(0, 500);
        disarm_wdt();
        printf("aud1: wait %d INT %08x level %u -> %u\n", r, d[0x30/4], lvl0, aud[1] & 0xFFFF);
    } else {
        int req = argc>2 ? atoi(argv[2]) : -1;
        printf("aud burst test req=%d, watchdog armed\n", req); fflush(stdout);
        arm_wdt();
        /* audio: enable serialiser off so frames just accumulate; reset fifo; set thresh */
        aud[0] = (1u<<5) | (1u<<2); aud[3] = 1024;            /* FIFO reset, THRESH 1024 */
        uint32_t lvl0 = aud[1] & 0xFFFF;
        int inf = argc>3 ? atoi(argv[3]) : 1;
        uint32_t ctrl = (2u<<21)|(2u<<18)|(0u<<14)|(2u<<12)|(3u<<24)|((uint32_t)inf<<31)|((uint32_t)inf<<30);   /* dst FIX */
        if (req >= 0) { ctrl |= (1u<<16) | ((uint32_t)req<<4); aud[0] |= (1u<<6); }  /* dst handshake, DMA_REQ enable */
        ch_setup(0, ctrl, 256, SCR, AUD+8);
        int r = ch_wait(0, 500);
        disarm_wdt();
        uint32_t lvl1 = aud[1] & 0xFFFF;
        printf("aud req=%d: wait %d INT %08x CHEN %08x left %u  fifo level %u -> %u  overrun %u\n",
               req, r, d[0x30/4], d[0x34/4], d[(0x40+4)/4]&0x3FFFFF, lvl0, lvl1, aud[6]);
        d[0x24/4] = 1;                                         /* abort ch0 if still running */
        aud[0] = (1u<<5) | (1u<<2);
    }
    return 0;
}
