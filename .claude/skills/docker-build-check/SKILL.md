---
name: docker-build-check
description: Check that the pushed Tang Mega 138K repository builds from a fresh clone inside the project's Docker image (docker/run.sh) — kernel + initramfs + OpenSBI payload, firmware, U-Boot, the userspace apps, optionally the rootfs packages and the gateware — compare the outputs with the committed binaries, and optionally boot the result on the board. Use this whenever the user asks to check the build in the container or from a clean checkout, verify that what was pushed is complete, test docker/bootstrap.sh / docker/run.sh, or reproduce a build on another machine — even if they just say "check that the build works in docker".
---

# Fresh-clone build check in Docker

The working tree can hide problems that a new checkout would hit:
- generated files;
- an existing `.config`;
- directories git does not keep;
- paths that exist only in the host's home directory.

This check clones what is on GitHub and builds it through `docker/run.sh`, the way
someone else would.

## 1. Run the builds

```
.claude/skills/docker-build-check/scripts/fresh_clone_build.sh [-d DEST] [STEP...]
```

The script:
- clones `REPO_URL` (default the GitHub origin) with its submodules, shallow, into
  `DEST` (default `/mnt/data/build/ctest-<date>`; the root disk is nearly full);
- runs each step through the clone's `docker/run.sh`, with a log per step in
  `DEST.logs/`;
- prints the kernel version, the payload and U-Boot sizes, and how the app binaries
  compare with the copies committed in `linux/rootfs/`.

Run it with `run_in_background`. The default steps take about 10 minutes, mostly the
clean kernel build.

| step | runs | notes |
|---|---|---|
| `kernel` | `scripts/build_kernel.sh` | `uname -v` dates are UTC in the container |
| `firmware` | `make -C src/firmware` | |
| `uboot` | `scripts/build_uboot.sh` | runs `config_uboot.sh` first on a tree without `.config` |
| `tests`, `boardcfg`, `desktop`, `vidplay` | `make -B -C src/apps/<step>` | `desktop` and `vidplay` need `AE350_USERSPACE` (`/userspace` in the image) to hold LVGL and the FFmpeg staging libs |
| `rootfs` | `scripts/rootfs/build_all.sh` | not in the defaults: long, downloads every package's sources |
| `gateware` | `STAGE=all scripts/gw_run.sh` | not in the defaults: needs the licence server; ~15 min |

- **The image** is `tang-mega-138k-build:latest`. If it is missing, `docker/bootstrap.sh`
  builds it (~3 GB, once).
- **The check covers what is pushed,** so push first. Uncommitted local changes are not
  in the clone. To test them before pushing, apply them there with
  `git diff | git -C DEST apply`, then rerun the steps by hand
  (`DEST/docker/run.sh …`).
- **An existing DEST is refused,** not deleted. Pass another `-d`, or remove the old
  one after asking the user.

## 2. Read the results

- **Every step should say `ok`.** For a failure, read its log. Failures seen before,
  and their fixes, all now in the repo:
  - git keeps no empty directories or modes; `linux/initramfs_nodes.list` creates them;
  - U-Boot had no `.config` in a fresh tree;
  - Makefiles ignored the image's `TOOLCHAIN` / `AE350_USERSPACE`.

  A new failure of this kind is a real bug in the repo: fix it there, not in the clone.
- **Binary comparison.**
  - `vidplay`, `inputd` and `boardcfg` should be identical to the committed copies. The
    static musl builds are reproducible.
  - `lvdesk` differs only by LVGL's source path compiled into it (`/userspace/…`), which
    is expected.
  - Any other difference means the committed binary is stale or the build depends on
    the host.
- **Kernel.** The payload size should match a host build of the same commit closely.
  The kernel name should show the fork commit without `-dirty`.

## 3. Optionally boot the container-built kernel

A build that compiles can still fail to boot; this is how the empty-directory bug
showed up. With the user's agreement, since it reflashes the board:
```
export GOWIN_PATH=/mnt/data/Gowin_V1.9.12.02_SP2_linux
DEST/scripts/flash.sh kernel                # the clone's payload → flash 0x800000
scripts/flash.sh load                       # from the main repo: the clone has no bitstream
scripts/board.py wait 180
python3 scripts/boardtest/boardtest.py -g kernel,net
```

If it does not answer, capture the console. Start `scripts/uart_console.py listen 90`
before `flash.sh load`.

Afterwards, tell the user which kernel the board is running: the clone's build has the
same release number, but its `uname -v` date is in UTC.

## 4. Clean up

Leave `DEST` and `DEST.logs` in place and tell the user where they are; they are a few
GB. Delete them when the user says so.
