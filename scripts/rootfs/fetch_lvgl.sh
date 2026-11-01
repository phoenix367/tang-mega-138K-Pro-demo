#!/usr/bin/env bash
# LVGL 9.6.0 sources for the desktop (src/apps/desktop/Makefile, LVGL_DIR). Nothing is built
# here: the desktop Makefile compiles LVGL straight from this tree. Unmodified upstream.
. "$(dirname "$0")/common.sh"

pkg_source lvgl lvgl-9.6.0 \
	https://github.com/lvgl/lvgl/archive/refs/tags/v9.6.0.tar.gz \
	b20ee3acc1bba13c62d854f9ebd62e4c51e0b443b1e0225892e86442defa84df lvgl-9.6.0.tar.gz
echo ">> LVGL sources at $SRC (LVGL_DIR for src/apps/desktop/Makefile)"
