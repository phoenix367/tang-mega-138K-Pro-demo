/*
 * flashtest -- check an SPI NOR through the MTD character device: the SoM's second
 * SPI NOR U7 on the AE350's SPI2 (spi-atcspi200, kernel #99 + gateware Build 73).
 *
 *   flashtest [-n] /dev/mtdN
 *
 * 1. MEMGETINFO: type, size, erase and write size.
 * 2. Reads the whole device, timed (MB/s), and counts the bytes that are not 0xFF.
 * 3. Write test on the last 64 KB, only if it is blank (all 0xFF), so data stored on
 *    the flash is never touched: erase, write a pseudo-random pattern (the first half
 *    in 4 KB writes, the second in odd-sized ones, so the driver's word and byte paths
 *    both run), read it back in 64 KB and in odd-sized reads at odd offsets, compare,
 *    erase again and check that it is blank. -n skips the write test.
 *
 * Output: FLASHTEST lines; the last one is "FLASHTEST PASSED ..." or
 * "FLASHTEST FAILED ...". Exit status 0 = passed.
 */
#include <errno.h>
#include <fcntl.h>
#include <mtd/mtd-user.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define TEST_SIZE	(64 * 1024)

static double now(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec * 1e-9;
}

static int fail(const char *what)
{
	printf("FLASHTEST FAILED %s%s%s\n", what, errno ? ": " : "", errno ? strerror(errno) : "");
	return 1;
}

static int erase(int fd, uint32_t start, uint32_t len)
{
	struct erase_info_user e = { .start = start, .length = len };

	return ioctl(fd, MEMERASE, &e);
}

static int read_at(int fd, void *buf, size_t len, off_t off)
{
	return pread(fd, buf, len, off) == (ssize_t)len ? 0 : -1;
}

static size_t count_not_ff(const uint8_t *p, size_t n)
{
	size_t c = 0;

	while (n--)
		c += *p++ != 0xff;
	return c;
}

int main(int argc, char **argv)
{
	int write_test = 1, fd, i;
	const char *dev;
	struct mtd_info_user mi;
	uint8_t *buf, *pat, *back;
	size_t notff = 0, bad, pos, len;
	uint32_t off, x;
	double t0, t1, t_erase, t_write, t_read;

	if (argc > 1 && !strcmp(argv[1], "-n")) {
		write_test = 0;
		argv++, argc--;
	}
	if (argc != 2) {
		fprintf(stderr, "usage: flashtest [-n] /dev/mtdN\n");
		return 2;
	}
	dev = argv[1];
	fd = open(dev, write_test ? O_RDWR : O_RDONLY);
	if (fd < 0)
		return fail(dev);
	if (ioctl(fd, MEMGETINFO, &mi))
		return fail("MEMGETINFO");
	printf("FLASHTEST %s type %u size %u erasesize %u writesize %u\n",
	       dev, mi.type, mi.size, mi.erasesize, mi.writesize);
	if (mi.type != MTD_NORFLASH || mi.size < TEST_SIZE || TEST_SIZE % mi.erasesize)
		return errno = 0, fail("not a NOR flash with 64 KB of whole erase blocks");

	buf = malloc(TEST_SIZE);
	pat = malloc(TEST_SIZE);
	back = malloc(TEST_SIZE);
	if (!buf || !pat || !back)
		return fail("malloc");

	/* the whole device */
	t0 = now();
	for (off = 0; off < mi.size; off += TEST_SIZE) {
		if (read_at(fd, buf, TEST_SIZE, off))
			return fail("read");
		notff += count_not_ff(buf, TEST_SIZE);
	}
	t_read = now() - t0;
	printf("FLASHTEST read %u bytes in %.2f s = %.2f MB/s, %zu bytes not 0xFF\n",
	       mi.size, t_read, mi.size / t_read / 1e6, notff);

	off = mi.size - TEST_SIZE;
	if (!write_test) {
		printf("FLASHTEST PASSED read only\n");
		return 0;
	}
	if (read_at(fd, buf, TEST_SIZE, off))
		return fail("read of the test area");
	if (count_not_ff(buf, TEST_SIZE)) {
		printf("FLASHTEST PASSED read only: the last 64 KB (0x%x) is in use, no write test\n", off);
		return 0;
	}

	/* pseudo-random pattern, a new one every run */
	x = (uint32_t)(now() * 1e6) | 1;
	for (i = 0; i < TEST_SIZE; i++) {
		x ^= x << 13, x ^= x >> 17, x ^= x << 5;
		pat[i] = x;
	}

	t0 = now();
	if (erase(fd, off, TEST_SIZE))
		return fail("erase");
	t1 = now();
	t_erase = t1 - t0;
	/* first half in 4 KB writes, second half in odd-sized ones (1, 3, 7, ... bytes) */
	for (pos = 0; pos < TEST_SIZE / 2; pos += 4096)
		if (pwrite(fd, pat + pos, 4096, off + pos) != 4096)
			return fail("write");
	for (len = 1; pos < TEST_SIZE; pos += len, len = len * 2 + 1 > 4093 ? 1 : len * 2 + 1) {
		if (len > TEST_SIZE - pos)
			len = TEST_SIZE - pos;
		if (pwrite(fd, pat + pos, len, off + pos) != (ssize_t)len)
			return fail("write (odd size)");
	}
	t_write = now() - t1;

	memset(back, 0, TEST_SIZE);
	if (read_at(fd, back, TEST_SIZE, off))
		return fail("read back");
	for (bad = 0, i = 0; i < TEST_SIZE; i++)
		bad += back[i] != pat[i];
	if (bad) {
		errno = 0;
		for (i = 0; i < TEST_SIZE && back[i] == pat[i]; i++)
			;
		printf("FLASHTEST %zu of %d bytes differ, the first at 0x%x: wrote %02x, read %02x\n",
		       bad, TEST_SIZE, off + i, pat[i], back[i]);
		erase(fd, off, TEST_SIZE);
		return fail("read-back mismatch");
	}
	/* odd-sized reads at odd offsets: the driver's byte path */
	memset(back, 0, TEST_SIZE);
	for (pos = 0, len = 3; pos < TEST_SIZE; pos += len, len = len * 2 + 1 > 4093 ? 3 : len * 2 + 1) {
		if (len > TEST_SIZE - pos)
			len = TEST_SIZE - pos;
		if (read_at(fd, back + pos, len, off + pos))
			return fail("read back (odd size)");
	}
	if (memcmp(back, pat, TEST_SIZE)) {
		errno = 0;
		erase(fd, off, TEST_SIZE);
		return fail("odd-sized read-back mismatch");
	}

	if (erase(fd, off, TEST_SIZE))
		return fail("erase after the test");
	if (read_at(fd, buf, TEST_SIZE, off))
		return fail("read after the erase");
	if ((bad = count_not_ff(buf, TEST_SIZE))) {
		errno = 0;
		printf("FLASHTEST %zu bytes not 0xFF after the erase\n", bad);
		return fail("erase did not blank the test area");
	}
	printf("FLASHTEST write test at 0x%x: erase %.3f s, write %.3f s (%.0f KB/s), "
	       "read back ok (64 KB and odd-sized), erased again\n",
	       off, t_erase, t_write, TEST_SIZE / t_write / 1024);
	printf("FLASHTEST PASSED read %.2f MB/s, write %.0f KB/s, erase 64 KB %.3f s\n",
	       mi.size / t_read / 1e6, TEST_SIZE / t_write / 1024, t_erase);
	return 0;
}
