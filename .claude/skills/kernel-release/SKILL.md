---
name: kernel-release
description: Build, flash and verify a Linux kernel + initramfs image for the Tang Mega 138K AE350 board (scripts/build_kernel.sh, scripts/flash.sh kernel + load, boot check, scripts/boardtest), then record the release in BOOT.md. Use this whenever the user wants a kernel, driver, device-tree, defconfig, rootfs, rcS or userspace-binary change on the board, asks to rebuild/reflash/test the kernel, bump linux/RELEASE, or make a new numbered kernel release — even if they only name one step like "build the kernel", "flash it" or "test it on the board".
---

# Kernel release: build → flash → verify → record

One image holds OpenSBI, the Linux `Image` with its initramfs, and the DTB:
- the initramfs comes from `linux/rootfs/` plus `linux/initramfs_nodes.list`;
- the image is LZMA-compressed into SPI flash at `0x800000`.

So a change to anything in `linux/rootfs/` (a rebuilt binary, `rcS`, `/etc`) is a
kernel release too. "Kernel #N" in BOOT.md is `linux/RELEASE`, and the board shows it as
`#N` in `uname -v`.

Set this once per shell:
```
export GOWIN_PATH=/mnt/data/Gowin_V1.9.12.02_SP2_linux
```

## 1. Release number and name

- Bump `linux/RELEASE` when this build is a new release, one that will be recorded in
  BOOT.md and committed. Test builds while iterating on one release keep the number;
  the build date in `uname -v` tells them apart.
- `uname -r` reads `6.12.0-tangmega138k-g<fork commit>[-dirty]`. `-dirty` means
  `external/linux` has uncommitted changes. That is fine for testing. A recorded release
  should come from a committed fork, so commit (when the user asks) and rebuild.

## 2. Build

```
scripts/build_kernel.sh                 # Image + fw_payload (OpenSBI, FW_PAYLOAD_OFFSET 0x400000)
NO_PAYLOAD=1 scripts/build_kernel.sh    # Image only
```

Run it with `run_in_background`: a clean build takes 6–7 min, an incremental one 1–2 min.
Success prints `>> kernel 6.12.0-tangmega138k-g… #N`.

- **Toolchain.** The Andes `nds32le-linux-glibc-v5d` under `ANDES_ROOT` (default
  `/mnt/data/toolchains`); `LINUX_CROSS` overrides it. Pass toolchains by absolute
  path: the user's PATH has a crippled `riscv64-unknown-elf-` first.
- **No atomics.** The A25 has no coherence manager: an AMO or LR/SC that misses the
  cache on DDR hangs the hart. The kernel and everything in `linux/rootfs` must be free
  of them. Check the kernel with
  `"$ANDES_ROOT"/nds32le-linux-glibc-v5d/bin/riscv32-linux-objdump -d external/linux/vmlinux | grep -cE '\b(amo[a-z]+|lr\.[wd]|sc\.[wd])\b'`:
  at most 1 (a harmless reservation-clear `sc.w`). boardtest's
  `kernel.rootfs_atomics` checks the rootfs.
- **Config.** `arch/riscv/configs/tang_mega_138k_defconfig` in the fork. The build makes
  `.config` from it only when `.config` is missing. After changing one, bring the other
  in line (`make olddefconfig`, `make savedefconfig`).
- **Rootfs binaries** come from `src/apps/*` (`make install`) and
  `scripts/rootfs/build_<pkg>.sh` (`INSTALL=1`). They are static musl, built with the
  soft-atomic toolchain.

## 3. Flash and boot

Run these one at a time; there is one USB programmer cable:
```
scripts/flash.sh kernel    # LZMA, refuses > 8 MB, writes flash 0x800000 (~1–2 min)
scripts/flash.sh load      # reload the bitstream into SRAM: the SoC resets and boots the new image
scripts/board.py wait 180  # ssh answers ~25–40 s after the load
```

- **Size.** The payload region ends at `0x1000000`, so the LZMA image must stay under
  8 MB. It is ~7.36 MB now; mention it when a change adds a lot.
- **`flash.sh load` needs a bitstream.** It reloads `impl/pnr/mega_138K_test.fs`, which
  only a gateware build creates (it is not in git). A flash write leaves the
  programmer's SPI bridge in the FPGA, so `load` or a power cycle is always needed
  afterwards.

**If the board does not come back** (no answer after ~2 min), read the console:
- Start `scripts/uart_console.py listen 90` in the background before `flash.sh load`,
  to catch the whole boot (U-Boot, OpenSBI, Linux).
- Common causes:
  - U-Boot's `lzmadec` fails: the payload is too big or corrupt.
  - A kernel Oops: read the first one.
  - "unable to open an initial console": the initramfs lacks `/dev`; see
    `linux/initramfs_nodes.list`.
  - A hang in `rcS`.
- Recovery: flash the previous release's payload. A kernel flash does not touch the
  bitstream or U-Boot.

## 4. Verify

```
scripts/board.py run 'uname -r; uname -v; cat /etc/issue'
python3 scripts/boardtest/boardtest.py -g kernel       # ~40 s; -g takes a comma list: kernel,net
python3 scripts/boardtest/boardtest.py                 # all groups, ~5–6 min
```

- Close `netinput.py` before the `ui` group: inputd serves one client.
- Two WARNs are expected on this bench:
  - `kernel.time`: no internet, the clock says 1970;
  - `net.errors`: the known residual RGMII RX errors.

  Look into anything else that is not PASS. The report directory, printed at the end
  (`/mnt/data/build/boardtest/<time>/`), has a log per test.
- Run at least the groups the change touches, and all groups before recording a
  release. A new driver or core gets a test in `scripts/boardtest/bt/t_<group>.py`.
- **Root on the board:** use `scripts/board.py root 'SCRIPT'`. It runs `doas` on a
  script file; quotes do not survive `doas sh -c` through ssh.
- **Background jobs** started over ssh die at logout: use `setsid`.
- **Nothing on the live board persists.** The rootfs is in RAM, so fixes go into
  `linux/rootfs/` and a new image.

## 5. Record (for a release, not for test builds)

- **BOOT.md**, flash table, the `0x800000` row: put **kernel #N** in front with:
  - the date and the payload size;
  - "#N-1 + what changed".

  Un-bold the previous one.
- **README.md** "Current state in flash": kernel #N.
- **PATCHES/** holds the boot-stack changes as `git diff`s against upstream.
  - If the release changes code that has a patch file, regenerate that patch for its
    files. The base is the fork's v6.12 import:
    `git -C external/linux log --reverse --format=%h | head -1`.
  - A new driver gets a new numbered patch and a section in `PATCHES/README.md`.
- **CLAUDE.md and `doc/`** when the change is architectural: a new driver, sysfs
  interface or device node (`doc/07-cores.md` for a core's driver).
- **Commits only when the user asks.** Commit and push the fork (`external/linux`,
  branch `master`) first, then the main repo with the submodule pointer. A plain
  `git push` works; the host's ssh config selects the key.
