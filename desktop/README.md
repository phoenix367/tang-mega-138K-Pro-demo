# desktop/ — LVGL desktop on the LCD + network keyboard/mouse

A small desktop for the board's 800×480 LCD, written with **LVGL 9.6** on the
Linux framebuffer (`/dev/fb0`, `PATCHES/0006` gowin-lcdfb), driven by the PC's
mouse and keyboard over Ethernet, because the board has no USB host, PS/2 or
touch input. Everything is static rv32 musl (soft-atomic libc, no `amo`/`lr`/`sc`).

```
PC: host/netinput.py  --tcp 5555-->  board: inputd  --/dev/uinput-->  /dev/input/event0 (mouse)
   (Tk window, 800x480)                                                /dev/input/event1 (keyboard)
                                                                            |
                                                 lvdesk  <--evdev-----------+
                                                   |--> /dev/fb0 (LVGL fbdev driver, partial render)
```

## Pieces

- **`inputd.c`** — board daemon (`/etc/init.d/S60inputd`, port 5555). Creates two
  uinput devices ("netinput mouse": `ABS_X/Y` 0..799/0..479, `REL_X/Y/WHEEL`,
  `BTN_LEFT/RIGHT/MIDDLE`; "netinput keyboard": every `KEY_*`) and copies the
  8-byte records it receives (`u16 type, u16 code, i32 value`, big-endian, after a
  `NETINPUT1` handshake) into them. Keys still pressed when a client disconnects
  are released.
  A record with type `0xFFFF` code 1 is a **frame request**, answered with an
  8-byte header `u16 w, h, bpp, fmt`:
  - value 0: fmt 0, the raw framebuffer follows (768 000 bytes);
  - value 1: fmt 1, **changed rows + RLE**: `u32 length`, then for every row that
    differs from the last frame sent to this client `u16 row, u16 len` and the row
    run-length encoded (`n < 0x80`: n+1 copies of the following RGB565 pixel;
    `n >= 0x80`: n-127 literal pixels). The board compares rows straight in its
    `/dev/fb0` mmap against a per-client copy, so an unchanged screen costs one
    memory pass (~20 ms) and 12 bytes; the clock tick is 13 rows / 8 KB; a full
    desktop screen is 60–100 KB instead of 768 KB;
  - value 2: like 1 but every row (keyframe, used for the first frame / resync).
- **`host/netinput.py`** — PC side, Tk only (no root, no python-evdev): a window the
  size of the LCD. Pointer position inside it is sent as an absolute position, so
  the board's cursor sits under yours; clicks, wheel and keys typed into the window
  go to the board (Tk's X11 keycodes are Linux key codes + 8, so no key map is
  needed). `--view [fps]` shows the board's framebuffer in the window (default
  10 fps; changed rows + RLE decoded with one numpy `repeat` per frame, `--raw`
  for full frames, no numpy = raw); `--snapshot out.ppm` saves one frame;
  `--scale 2` doubles the window.
- **`lvdesk/`** — the desktop (`/etc/init.d/S70desktop`, supervised restart loop,
  log in `/run/desktop.log`):
  - `main.c` — fbdev display, VT 1 to `KD_GRAPHICS` + keyboard `K_OFF` (restored on
    exit), status bar (clock, IP, CPU %, die temperature, fan rpm — red "FAN
    STOPPED" when the tacho gives no pulses, free memory), home tile
    grid, panel container with Back. `-p <panel>` opens a panel at start (for
    screenshots), `-T` leaves the VT alone.
  - `input.c` — own evdev drivers (LVGL's built-in one drops printable keys):
    pointer with ABS/REL and wheel-to-scroll, keyboard with US layout, Shift/Caps,
    LVGL navigation keys, autorepeat; devices are grabbed (`EVIOCGRAB`) and
    re-scanned every second if missing. Ctrl+Alt+H = home, Ctrl+Alt+Q = restart.
  - `sysinfo.c` — `/proc/stat`, `/proc/meminfo`, loadavg, uptime, hwmon
    `gowin-adc` (temperature + 8 rails), eth0 state/counters/IP.
  - `panels.c` — **System** (CPU chart, memory, sensors, fan), **Files** (LVGL file
    explorer over `lv_fs_posix`; click = text preview or, for `.wav`, play; a
    status row shows the microSD card as a mountable resource with a
    Mount/Unmount button and an "SD card" quick-access entry),
    **Audio** (WAV list from `/home/ae350`, `/tmp`; plays via a `wavplay` child
    process; "Test tone" writes and plays a 440/880 Hz stereo file), **Network**
    (RX/TX kbit/s chart, IP/MAC/link), **Console** (runs a shell command as root,
    shows the output; quick buttons for dmesg/ps/free/df/…), **Settings** (dark/light
    theme, FPS overlay, restart desktop, reboot/poweroff with confirmation),
    **Widgets** / **Benchmark** (LVGL's demos on their own screen, "Exit demo"
    button on the top layer).
- **`lv_conf.h`** — LVGL configuration: RGB565, CLIB malloc/string, fbdev driver
  in partial mode with a 120-line draw buffer, POSIX fs on drive `A:`, file
  explorer, sysmon/perf monitor (hidden by default), Montserrat 12–32 + UNSCII,
  widgets + benchmark demos, log level WARN to stdout.

## Build

```
cd desktop && make            # inputd + build/lvdesk  (LVGL from ~/projects/ae350_linux_user_level/lvgl/lvgl-9.6.0)
make install                  # -> linux/rootfs/usr/bin/{inputd,lvdesk,wavplay}, /etc/init.d/S60inputd,S70desktop
```

Then rebuild the kernel (the initramfs is regenerated from `linux/rootfs/`) and
flash the payload, see `doc/02-build.md`. The kernel needs `CONFIG_INPUT_EVDEV`,
`CONFIG_INPUT_MISC`, `CONFIG_INPUT_UINPUT` (kernel #59 and later). The link step
prints the count of hardware atomic instructions in `lvdesk`; it must be 0.

## Use

```
desktop/host/netinput.py                 # board at 192.168.200.2, input only
desktop/host/netinput.py --view          # + live view of the LCD in the window
desktop/host/netinput.py --snapshot lcd.ppm
```

On the board: `S70desktop stop` / `start` to get the LCD back as a text console
(`getty -L 38400 tty1 linux` then works with the network keyboard), `S60inputd`
likewise for the bridge. `lvdesk -p system` etc. from a root shell opens a panel
directly.

## Notes

- Rendering is pure software on the A25 (no DMA, no GPU): partial redraws of a
  widget screen run at the 30 ms LVGL refresh period; full-screen transitions take
  a few frames. The benchmark demo gives numbers.
- The LCD framebuffer is cached memory written back by the fbdev driver's deferred
  I/O (20 ms), so LVGL's mmap writes appear on the panel one tick later.
- LVGL 9.6 marks `lv_file_explorer` and `lv_list` deprecated; they still work and
  are used here for brevity (`-Wno-deprecated-declarations` in the Makefile).
- Measured over the link: idle frame 12 B / 20 ms round trip, clock tick 8 KB / 25 ms,
  keyframe of the home screen 90 KB / 120 ms, widgets demo animating ~8 KB per
  frame at 18 fps. The 20 ms floor is the A25 comparing 768 KB of framebuffer.
- `inputd` accepts any client on the LAN: it is a bench tool, not a service to
  expose on an untrusted network.
