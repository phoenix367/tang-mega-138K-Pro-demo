/* osd_fake.h -- forced into osd.c for the host preview (osd_preview.c) */
#include <stddef.h>
#include <sys/types.h>
int fake_ioctl(int fd, unsigned long req, ...);
void *fake_mmap(void *a, size_t l, int p, int f, int fd, off_t o);
int fake_munmap(void *a, size_t l);
#define ioctl fake_ioctl
#define mmap fake_mmap
#define munmap fake_munmap
