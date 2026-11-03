# src/splash/ — the U-Boot boot splash

`splash.bmp` is what the Dock's 5" LCD shows from about a second after power-on until the
kernel's `gowin-lcdfb` driver takes the panel over (U-Boot's LZMA decompression of the
payload plus the kernel start take ~12 s, which used to be a black screen).

- `make_splash.py` renders it (800×480, 8-bit palette BMP, DejaVu fonts from the host);
  replace the file with any 800×480 BMP (8-bit palette or 16/24-bit) to change the picture.
- `scripts/build_uboot.sh` appends it to `u-boot-ae350-xip.bin` at offset `0x100000`
  (flash `0x700000`, XIP `0x80100000`), so `scripts/flash.sh uboot` writes it along with
  U-Boot. The exFlash bridge only writes images based at `0x0`, `0x600000` and `0x800000`,
  which is why the splash rides inside the U-Boot image.
- U-Boot side (fork `tang-mega-138k-u-boot`): `drivers/video/gowin_lcd.c` drives the
  gateware's scan-out core (`src/rtl/video/`, same DT timings as Linux) with a fixed
  framebuffer at DRAM `0x0e000000`; `CONFIG_PREBOOT="bmp display ${splashimage} m m"` draws
  the BMP right before the autoboot countdown (the `SPLASH_SCREEN` hook is not used: with the
  console pinned to serial by `stdout=serial`, stdio init does not probe video devices). The
  U-Boot console stays on the serial port.
- Linux side: `linux/ae350-linux.dts` reserves the framebuffer (`reserved-memory`,
  `no-map`) so the kernel does not reuse those pages while the core is still scanning
  them; the picture stays up until `gowin-lcdfb` probes and switches to its own buffer.

Check without looking at the panel: stop U-Boot (`uboot` during the countdown) and read the
core's frame CRC, `md.l 0xe8001028 1`; `make_splash.py`'s RGB565 rendering of the BMP must
give the same CRC-32; the script prints it (`0x08cff76e` for the shipped image, which uses the kernel's own Tux from `drivers/video/logo/logo_linux_clut224.ppm`).
