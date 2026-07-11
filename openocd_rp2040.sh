#!/usr/bin/env zsh
# Start OpenOCD as a GDB server for RP2040 debugging via picoprobe (CMSIS-DAP).
# Requires:  brew install openocd
# Hardware:  a second Pico flashed as picoprobe, wired:
#              Picoprobe GP2 → Target SWDIO
#              Picoprobe GP3 → Target SWDCLK
#              Picoprobe GND → Target GND
# Listens on:  GDB port  3333
#              Telnet     4444
# Stop with Ctrl-C.
set -e

OPENOCD="$(brew --prefix)/bin/openocd"
SCRIPTS="$(brew --prefix)/share/openocd/scripts"

if [[ ! -x "$OPENOCD" ]]; then
    echo "ERROR: openocd not found. Install with:  brew install openocd"
    exit 1
fi

"$OPENOCD" \
    -s "$SCRIPTS" \
    -f interface/cmsis-dap.cfg \
    -f target/rp2040.cfg \
    -c "adapter speed 5000"
