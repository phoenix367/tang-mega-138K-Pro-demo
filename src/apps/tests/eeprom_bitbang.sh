#!/bin/sh
# Read the Dock's ZD24C08A EEPROM by bit-banging I2C through the gpio_core
# registers with busybox devmem.  Runs ON THE BOARD, as root (/dev/mem); needs
# a bitstream with src/rtl/gpio/ (Build 66+), not the kernel's i2c-gpio/at24
# stack -- it is the hardware check for a new bitstream under an old kernel.
#
#   eeprom_bitbang.sh [ADDR [COUNT]]      dump COUNT (16) bytes from ADDR (0)
#   eeprom_bitbang.sh -w ADDR BYTE        write one byte (WP dropped for it)
#
# Register map: 0xE8010000 DAT (write = output latch, read = pin levels),
# 0xE8010004 DIROUT (1 = drive).  Bits: 0 SCL, 1 SDA, 2..4 mux SEL, 5 WP.
# The I2C lines are open drain: "1" = release (input), "0" = drive low.
# About 1.5 ms per bit through devmem, so keep COUNT small.
# no set -e: NAKs are reported explicitly
DAT=0xE8010000; DIR=0xE8010004
SEL=0x08          # mux channel 2 (SEL1=1): the EEPROM
dat=$SEL          # output latch: SEL=010, SCL/SDA/WP low when driven
dir=0x3C          # SEL + WP driven, SCL/SDA released

id=$(devmem 0xE8010008)
[ "$id" = "0x4750494F" ] || { echo "no gpio_core at 0xE8010000 (ID $id): wrong bitstream?" >&2; exit 1; }

out() { devmem $DAT 32 $dat; devmem $DIR 32 $dir; }
scl() { if [ "$1" = 1 ]; then dir=$((dir & ~1)); else dir=$((dir | 1)); fi; out; }
sda() { if [ "$1" = 1 ]; then dir=$((dir & ~2)); else dir=$((dir | 2)); fi; out; }
rd_sda() { v=$(devmem $DAT); echo $(( (v >> 1) & 1 )); }
wp()  { if [ "$1" = 1 ]; then dat=$((dat | 0x20)); else dat=$((dat & ~0x20)); fi; out; }

start() { sda 1; scl 1; sda 0; scl 0; }
stop()  { sda 0; scl 1; sda 1; }
# write a byte, return the ACK (0 = acked)
wbyte() {
	b=$1; i=7
	while [ $i -ge 0 ]; do sda $(( (b >> i) & 1 )); scl 1; scl 0; i=$((i - 1)); done
	sda 1; scl 1; ack=$(rd_sda); scl 0
	return $ack
}
# read a byte; $1 = 1 to ACK (more to come), 0 to NAK
rbyte() {
	b=0; i=0
	while [ $i -lt 8 ]; do scl 1; b=$(( (b << 1) | $(rd_sda) )); scl 0; i=$((i + 1)); done
	if [ "$1" = 1 ]; then sda 0; else sda 1; fi
	scl 1; scl 0; sda 1
	echo $b
}
# 24C08: block (addr[9:8]) rides in the device address, addr[7:0] is the word
devaddr() { echo $(( 0xA0 | ((($1 >> 8) & 3) << 1) )); }

wp 1; out
if [ "${1:-}" = -w ]; then
	addr=$(( $2 )); byte=$(( $3 ))
	wp 0
	start; wbyte $(devaddr $addr) || { stop; echo "no ACK from EEPROM" >&2; exit 1; }
	wbyte $((addr & 0xFF)); wbyte $byte; stop
	wp 1
	# poll until the internal write cycle (<= 5 ms) is over
	n=0; while ! { start; wbyte $(devaddr $addr); }; do stop; n=$((n + 1)); [ $n -lt 50 ] || { echo "write did not complete" >&2; exit 1; }; done
	stop
	printf 'wrote 0x%02X at 0x%03X\n' $byte $addr
	exit 0
fi

addr=$(( ${1:-0} )); count=$(( ${2:-16} ))
start
wbyte $(devaddr $addr) || { stop; echo "no ACK from EEPROM at 0x$(printf %02X $(( $(devaddr $addr) >> 1 )))" >&2; exit 1; }
wbyte $((addr & 0xFF))
start; wbyte $(( $(devaddr $addr) | 1 ))
printf '%03X:' $addr
i=1
while [ $i -le $count ]; do
	if [ $i -lt $count ]; then b=$(rbyte 1); else b=$(rbyte 0); fi
	printf ' %02X' $b
	i=$((i + 1))
done
stop
echo
