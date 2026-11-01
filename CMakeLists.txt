# CMake front-end for the Gowin AE350 project (Tang Mega 138K Pro).
#
# This is not a C/C++ build - it drives the Gowin toolchain and the bare-metal
# firmware build through custom targets, giving one entry point for the whole
# flow. project(... NONE) so CMake does not look for a host compiler.
#
# Configure once, then run targets:
#   cmake -B build [-D GOWIN_PATH=/path/to/Gowin]
#   cmake --build build --target bitstream       # synthesis + PnR -> .fs
#   cmake --build build --target firmware        # build test firmware
#   cmake --build build --target upload          # flash firmware + (re)load gateware
#
# List every target with:  cmake --build build --target help-targets
cmake_minimum_required(VERSION 3.16)
project(mega_138K_test NONE)

# ---------------------------------------------------------------------------
# Configuration (override on the cmake command line with -D<NAME>=<value>)
# ---------------------------------------------------------------------------
set(GOWIN_PATH  "/mnt/data/Gowin_V1.9.12.02_SP2_linux" CACHE PATH   "Gowin EDA install root (dir containing IDE/)")
set(DEVICE      "GW5AST-138B"          CACHE STRING "programmer_cli --device string")
set(TOP_MODULE  "ae350_demo_top"       CACHE STRING "Top module for synthesis")
set(FW_SPIADDR  "0x600000"             CACHE STRING "SPI-flash offset for the firmware (maps to CPU 0x80000000)")
set(FW_GCC_DIR  ""                     CACHE PATH   "Override RISC-V toolchain bin dir for the firmware (else firmware/Makefile default)")
set(UBOOT_DIR   "$ENV{HOME}/projects/u-boot" CACHE PATH "U-Boot tree (configured for AE350 XIP hard-float)")

set(REPO        "${CMAKE_CURRENT_SOURCE_DIR}")
set(SCRIPTS     "${REPO}/scripts")
set(FW_DIR      "${REPO}/firmware")
set(BITSTREAM   "${REPO}/impl/pnr/mega_138K_test.fs")
set(FIRMWARE_BIN "${FW_DIR}/build/ae350_fw.bin")
set(UBOOT_IMAGE "${UBOOT_DIR}/u-boot-ae350-xip.bin")
set(PAYLOAD_DIR  "${REPO}/payload")
set(PAYLOAD_IMG  "${PAYLOAD_DIR}/payload.img")
set(PAYLOAD_SPIADDR "0x800000" CACHE STRING "SPI-flash offset for the bootm payload (maps to CPU 0x80200000)")
set(APP_IMAGE    "${CMAKE_BINARY_DIR}/ae350-app.bin")  # combined u-boot+dtb+payload @ 0x600000

# Helper: run a repo script with the common Gowin env set.
set(GW_ENV ${CMAKE_COMMAND} -E env GOWIN_PATH=${GOWIN_PATH} DEVICE=${DEVICE})

# ===========================================================================
# 1. Gateware: synthesis & place-and-route  (scripts/gw_run.sh -> .fs)
# ===========================================================================
add_custom_target(hw_synth
    COMMAND ${GW_ENV} STAGE=syn TOP=${TOP_MODULE} bash ${SCRIPTS}/gw_run.sh
    WORKING_DIRECTORY ${REPO} USES_TERMINAL
    COMMENT "Gowin synthesis only (GowinSynthesis)")

add_custom_target(hw_pnr
    COMMAND ${GW_ENV} STAGE=pnr TOP=${TOP_MODULE} bash ${SCRIPTS}/gw_run.sh
    WORKING_DIRECTORY ${REPO} USES_TERMINAL
    COMMENT "Gowin place-and-route + bitstream (uses existing synthesis netlist)")

add_custom_target(hw_all
    COMMAND ${GW_ENV} STAGE=all TOP=${TOP_MODULE} bash ${SCRIPTS}/gw_run.sh
    WORKING_DIRECTORY ${REPO} USES_TERMINAL
    COMMENT "Synthesis + PnR + bitstream -> impl/pnr/mega_138K_test.fs")

# ===========================================================================
# 2. Test firmware  (firmware/Makefile -> ae350_fw.bin)
# ===========================================================================
if(FW_GCC_DIR)
    set(FW_MAKE_ARGS "GCC_DIR=${FW_GCC_DIR}")
endif()

add_custom_target(firmware
    COMMAND make -C ${FW_DIR} ${FW_MAKE_ARGS}
    USES_TERMINAL
    COMMENT "Build the AE350 test firmware -> firmware/build/ae350_fw.bin")

add_custom_target(firmware-clean
    COMMAND make -C ${FW_DIR} clean
    COMMENT "Clean the firmware build")

# ===========================================================================
# 3. Upload: bitstream and firmware
# ===========================================================================
# Gateware to SRAM (volatile - fast, reverts on power cycle).
add_custom_target(upload-bitstream
    COMMAND ${GW_ENV} FS=${BITSTREAM} MODE=sram bash ${SCRIPTS}/gw_program.sh
    USES_TERMINAL
    COMMENT "Load bitstream into FPGA SRAM (volatile)")

# Gateware to external SPI flash @ 0x0 (persistent - FPGA self-configures on power-up).
add_custom_target(flash-bitstream
    COMMAND ${GW_ENV} FS=${BITSTREAM} MODE=flash bash ${SCRIPTS}/gw_program.sh
    USES_TERMINAL
    COMMENT "Program bitstream to external SPI flash @ 0x0 (persistent autoboot)")

# Firmware to SPI flash @ FW_SPIADDR. Build it first.
add_custom_target(upload-firmware
    COMMAND ${GW_ENV} FW=${FIRMWARE_BIN} SPIADDR=${FW_SPIADDR} bash ${FW_DIR}/flash_fw.sh
    DEPENDS firmware
    USES_TERMINAL
    COMMENT "Flash test firmware to SPI flash @ ${FW_SPIADDR}")

# Convenience: flash firmware then (re)load the gateware so it runs immediately.
# (programmer_cli leaves its SPI bridge on the FPGA after the flash write, so the
# gateware must be reloaded to actually run.)
add_custom_target(upload
    COMMAND ${GW_ENV} FW=${FIRMWARE_BIN} SPIADDR=${FW_SPIADDR} bash ${FW_DIR}/flash_fw.sh
    COMMAND ${GW_ENV} FS=${BITSTREAM} MODE=sram bash ${SCRIPTS}/gw_program.sh
    DEPENDS firmware
    USES_TERMINAL
    COMMENT "Flash firmware @ ${FW_SPIADDR} then reload gateware to SRAM (run it now)")

# ===========================================================================
# 4. U-Boot  (mainline U-Boot tree -> hard-float XIP + combined DTB image)
# ===========================================================================
# One-time (or post-distclean) configuration of the U-Boot tree: applies
# ae350_rv32_xip_defconfig + the board Kconfig tweaks (hard-float, single-core,
# env-nowhere, no SPI). NOT a dependency of `uboot` (it re-runs defconfig and
# would wipe manual config). The DT file edits are separate - see the script.
add_custom_target(uboot-config
    COMMAND ${CMAKE_COMMAND} -E env UBOOT_DIR=${UBOOT_DIR} bash ${SCRIPTS}/config_uboot.sh
    USES_TERMINAL
    COMMENT "Configure the U-Boot tree for AE350 (defconfig + tweaks)")

# Builds U-Boot and assembles the combined "u-boot + DTB" flash image. The
# U-Boot tree must already be configured/DT-adapted for this board (see
# scripts/build_uboot.sh and project memory). Output: ${UBOOT_IMAGE}.
add_custom_target(uboot
    COMMAND ${CMAKE_COMMAND} -E env UBOOT_DIR=${UBOOT_DIR} UBOOT_IMAGE=${UBOOT_IMAGE}
            bash ${SCRIPTS}/build_uboot.sh
    USES_TERMINAL
    COMMENT "Build hard-float XIP U-Boot + combined u-boot/DTB image")

# Flash the U-Boot image to the same SPI-flash slot as the firmware (0x600000)
# and reload the gateware so it boots. Replaces whatever is at ${FW_SPIADDR}.
add_custom_target(uboot-flash
    COMMAND ${GW_ENV} FW=${UBOOT_IMAGE} SPIADDR=${FW_SPIADDR} bash ${FW_DIR}/flash_fw.sh
    COMMAND ${GW_ENV} FS=${BITSTREAM} MODE=sram bash ${SCRIPTS}/gw_program.sh
    DEPENDS uboot
    USES_TERMINAL
    COMMENT "Flash U-Boot to ${FW_SPIADDR} + reload gateware (boot U-Boot, console 115200)")

# ===========================================================================
# 5. Bootm payload  (bare-metal standalone uImage, booted from the U-Boot prompt)
# ===========================================================================
add_custom_target(payload
    COMMAND make -C ${PAYLOAD_DIR} MKIMAGE=${UBOOT_DIR}/tools/mkimage
    USES_TERMINAL
    COMMENT "Build the bare-metal bootm payload (standalone uImage)")

# Flash the payload. The Gowin programmer only reliably writes the 0x600000
# region, so we assemble ONE combined image (U-Boot+DTB at offset 0, payload at
# offset PAYLOAD_SPIADDR-FW_SPIADDR) and flash it to FW_SPIADDR. The payload
# still lands at CPU 0x80200000. Then at the U-Boot prompt:  bootm 0x80200000
add_custom_target(payload-flash
    COMMAND ${CMAKE_COMMAND} -E env UBOOT_IMAGE=${UBOOT_IMAGE} PAYLOAD_IMG=${PAYLOAD_IMG}
            APP_IMAGE=${APP_IMAGE} FW_SPIADDR=${FW_SPIADDR} PAYLOAD_SPIADDR=${PAYLOAD_SPIADDR}
            bash ${SCRIPTS}/build_app_image.sh
    COMMAND ${GW_ENV} FW=${APP_IMAGE} SPIADDR=${FW_SPIADDR} bash ${FW_DIR}/flash_fw.sh
    COMMAND ${GW_ENV} FS=${BITSTREAM} MODE=sram bash ${SCRIPTS}/gw_program.sh
    DEPENDS uboot payload
    USES_TERMINAL
    COMMENT "Flash combined U-Boot+payload @ ${FW_SPIADDR} + reload; then 'bootm 0x80200000'")

# ---------------------------------------------------------------------------
add_custom_target(help-targets
    COMMAND ${CMAKE_COMMAND} -E echo "Targets:"
    COMMAND ${CMAKE_COMMAND} -E echo "  hw_synth hw_pnr hw_all - Gowin synthesis / PnR / full bitstream"
    COMMAND ${CMAKE_COMMAND} -E echo "  firmware firmware-clean - build/clean the AE350 test firmware"
    COMMAND ${CMAKE_COMMAND} -E echo "  upload-bitstream      - load gateware to SRAM (volatile)"
    COMMAND ${CMAKE_COMMAND} -E echo "  flash-bitstream       - program gateware to SPI flash 0x0 (persistent)"
    COMMAND ${CMAKE_COMMAND} -E echo "  upload-firmware       - flash firmware to ${FW_SPIADDR}"
    COMMAND ${CMAKE_COMMAND} -E echo "  upload                - flash firmware + reload gateware (run now)"
    COMMAND ${CMAKE_COMMAND} -E echo "  uboot-config          - configure U-Boot tree for AE350 (defconfig + tweaks)"
    COMMAND ${CMAKE_COMMAND} -E echo "  uboot                 - build hard-float XIP U-Boot + combined image"
    COMMAND ${CMAKE_COMMAND} -E echo "  uboot-flash           - flash U-Boot @ ${FW_SPIADDR} + reload gateware (115200)"
    COMMAND ${CMAKE_COMMAND} -E echo "  payload payload-flash - build/flash bootm payload @ ${PAYLOAD_SPIADDR} (bootm 0x80200000)")
