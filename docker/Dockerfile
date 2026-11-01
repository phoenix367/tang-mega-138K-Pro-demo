# Build environment for the Tang Mega 138K Pro / Gowin AE350 project.
#
# Contains every cross toolchain the repo needs, built or fetched by checksum:
#   /opt/toolchains/nds32le-elf-newlib-v5     Andes bare-metal GCC  (src/firmware)
#   /opt/toolchains/nds32le-linux-glibc-v5d   Andes Linux GCC       (U-Boot, OpenSBI, kernel)
#   /opt/toolchains/riscv32-ilp32d--musl-*    Bootlin musl GCC with the soft-atomic libc.a
#                                             (rootfs: scripts/rootfs/, src/apps/)
# plus the host tools (dtc, iverilog, bison/flex/bc, python3 + pyserial, ...).
#
# The Gowin EDA tools are NOT in the image (licensed, 4 GB): docker/run.sh bind-mounts the
# host install at /opt/gowin and sets GOWIN_PATH; the licence server address comes with it
# (IDE/bin/gwlicense.ini). The runtime libraries gw_sh / programmer_cli need are installed.
#
# Build with docker/bootstrap.sh (it supplies the build args and writes run.sh's settings).
FROM debian:bookworm-slim

ARG ANDES_RELEASE=ast-v5_4_1-release-linux
ARG ANDES_ELF_SHA256=5567ce1f5ce6a9a9c006485bbaa4e36912ecbadc44ef93ce0a86718615318edb
ARG ANDES_LINUX_SHA256=0d9ee91376785835a10b1631cfc9e4d6d61326c0512da774c012fdac53c2bc3a
ARG BUILD_UID=1000
ARG BUILD_GID=1000

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        # build hosts tools for the kernel / U-Boot / OpenSBI / rootfs packages
        build-essential bison flex bc libssl-dev libelf-dev pkg-config patch \
        cpio rsync kmod file gzip bzip2 xz-utils curl ca-certificates git \
        device-tree-compiler iverilog ncurses-bin \
        python3 python3-serial python3-tk \
        # runtime libraries of the (bind-mounted) Gowin gw_sh and programmer_cli
        libtcl8.6 libglib2.0-0 libgl1 libglx0 libfontconfig1 libfreetype6 libdbus-1-3 \
        libasound2 libnss3 libnspr4 libcap2 libusb-1.0-0 \
        libx11-6 libx11-xcb1 libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 \
        libxkbcommon0 libxrandr2 libxrender1 libxtst6 \
        libqt5core5a libqt5gui5 libqt5widgets5 libqt5network5 libqt5xml5 libqt5sql5 \
        libqt5concurrent5 libqt5printsupport5 libqt5qml5 libqt5quick5 libqt5quickwidgets5 \
        libqt5webchannel5 libqt5positioning5 libqt5qmlmodels5 \
        libqt5webengine5 libqt5webenginecore5 libqt5webenginewidgets5 \
    && rm -rf /var/lib/apt/lists/*

# Andes toolchains (github.com/andestech/Andes-Development-Kit releases)
RUN set -eux; mkdir -p /opt/toolchains; cd /tmp; \
    base="https://github.com/andestech/Andes-Development-Kit/releases/download/${ANDES_RELEASE}"; \
    curl -fsSL --retry 3 -o elf.txz   "${base}/nds32le-elf-newlib-v5.txz"; \
    curl -fsSL --retry 3 -o linux.txz "${base}/nds32le-linux-glibc-v5d.txz"; \
    echo "${ANDES_ELF_SHA256}  elf.txz"     | sha256sum -c -; \
    echo "${ANDES_LINUX_SHA256}  linux.txz" | sha256sum -c -; \
    tar xJf elf.txz   -C /opt/toolchains; \
    tar xJf linux.txz -C /opt/toolchains; \
    rm -f elf.txz linux.txz; \
    rm -rf /opt/toolchains/python; \
    /opt/toolchains/nds32le-elf-newlib-v5/bin/riscv32-elf-gcc --version | head -1; \
    /opt/toolchains/nds32le-linux-glibc-v5d/bin/riscv32-linux-gcc --version | head -1

# Bootlin musl toolchain + soft-atomic libc.a, exactly as on a developer machine
COPY scripts/build_musl_toolchain.sh /tmp/scripts/
COPY PATCHES/0012-musl-riscv32-soft-atomics.patch /tmp/PATCHES/
RUN set -eux; /tmp/scripts/build_musl_toolchain.sh /opt/toolchains/riscv32-ilp32d--musl--stable-2025.08-1; \
    rm -rf /tmp/scripts /tmp/PATCHES

# Debian's mkimage (u-boot-tools) for src/firmware/payload when the submodule's host-built
# tools/mkimage was linked on another machine. Late layer: keeps the toolchain layers cached.
RUN apt-get update && apt-get install -y --no-install-recommends u-boot-tools \
    && rm -rf /var/lib/apt/lists/*

# Unprivileged user matching the host's uid/gid so files written into the mounted repo
# belong to the host user. dialout for the UART, plugdev for the programmer.
RUN groupadd -g "${BUILD_GID}" builder 2>/dev/null || true; \
    useradd -m -u "${BUILD_UID}" -g "${BUILD_GID}" -G dialout,plugdev -s /bin/bash builder; \
    mkdir -p /work /userspace /opt/gowin && chown builder:"${BUILD_GID}" /work /userspace

# What the repo's Makefiles and scripts read (all overridable at run time)
ENV ANDES_ROOT=/opt/toolchains \
    TOOLCHAIN=/opt/toolchains/riscv32-ilp32d--musl--stable-2025.08-1 \
    AE350_USERSPACE=/userspace \
    GOWIN_PATH=/opt/gowin \
    PATH=/opt/toolchains/nds32le-linux-glibc-v5d/bin:/opt/toolchains/nds32le-elf-newlib-v5/bin:/usr/local/bin:/usr/bin:/bin

USER builder
WORKDIR /work
CMD ["/bin/bash"]
