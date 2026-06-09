#!/usr/bin/env bash
# Run Gowin gw_sh (synthesis / place-and-route / bitstream) without the IDE GUI.
# Adapted from tang_nano_9K_ov7670/scripts/gw_run.sh.
#
# Env vars:
#   GOWIN_PATH - Gowin install root (the dir containing IDE/). Required.
#   GPRJ       - Absolute path to the .gprj. Defaults to the repo's .gprj.
#   STAGE      - syn | pnr | all. Defaults to all.
#   TOP        - Optional top module name override.
#
# Example:
#   GOWIN_PATH=/opt/gowin/Gowin_V1.9.12.02_SP2_linux STAGE=all scripts/gw_run.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${GOWIN_PATH:-}" ]]; then
    echo "GOWIN_PATH not set; point it at the Gowin install root (the dir containing IDE/)" >&2
    exit 1
fi
export GPRJ="${GPRJ:-$REPO_DIR/mega_138K_test.gprj}"
export STAGE="${STAGE:-all}"

TCL_SCRIPT="$SCRIPT_DIR/gw_run.tcl"

cd "$GOWIN_PATH"
export LD_LIBRARY_PATH="./IDE/lib"
export LD_PRELOAD="/lib/x86_64-linux-gnu/libstdc++.so.6 /lib/x86_64-linux-gnu/libfreetype.so"
exec ./IDE/bin/gw_sh "$TCL_SCRIPT"
