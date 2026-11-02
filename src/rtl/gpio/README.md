# gpio/ — board control lines and the Dock EEPROM

A six-bit data/direction register pair on the EXTS bus (CPU `0xE8010000`,
`HADDR[16]`) that gives Linux the Dock's housekeeping I2C bus without any
board-specific kernel driver. Everything above the register is mainline:

| Layer | Driver | DT node (`linux/ae350-linux.dts`) |
|---|---|---|
| register pair | `gpio-mmio` (`wd,mbl-gpio`: `dat` + `dirout`) | `gpio@e8010000`, 6 lines |
| I2C master | `i2c-gpio` (bit-bang, ~100 kHz) | `i2c-sys` on lines 0/1 |
| 8-way mux | `i2c-mux-gpio` | `i2c-mux` on lines 2..4, idle = channel 2 |
| 1 KB EEPROM | `at24` + nvmem (`wp-gpios` on line 5) | `eeprom@50` under channel 2 |

## Hardware (Tang Mega 138K Pro Dock 4071d/f)

The Dock routes one I2C bus from the FPGA, `SYS_TWI`, through two 74HC4051
analog muxes (one for SCL, one for SDA, select lines shared) to eight
targets. The only on-board slave is a **ZD24C08A** EEPROM (U24, SOT-23-5,
8 Kbit = 1 KB, 24C08-compatible, four 256-byte blocks at I2C 0x50..0x53).

| Line | Pin | Net | Notes |
|---|---|---|---|
| 0 | K25 | `SYS_TWI.SCL` | 2.2 kΩ pull-up R229 |
| 1 | K26 | `SYS_TWI.SDA` | 2.2 kΩ pull-up R230 |
| 2 | N19 | `TWI_MUX.S0` | |
| 3 | P19 | `TWI_MUX.S1` | |
| 4 | P26 | `TWI_MUX.S2` | |
| 5 | V14 | `EEPROM_WP` | high = write protected |

Mux channels (SEL2 SEL1 SEL0): 0 SFP0, 1 SFP1, **2 EEPROM**, 3 DVI-A DDC,
4 DVI-B DDC, 5 DVP camera, 6 MIPI RX0, 7 MIPI RX1. The SDA mux has its
select pins wired in the opposite order to the SCL mux, which the Dock
compensates by swapping its Y1/Y4 and Y3/Y6 connections; the table above is
what software sees. Channels 3 and 4 also carry the Dock's two MS5351 clock
generators (`PLL0_TWI`/`PLL1_TWI` through 100 Ω series resistors, 4071f), so
the DT declares those two channels as empty buses for later use.

## Register map (byte offset, 32-bit accesses, zero wait states)

| Offset | Name | Access | Bits |
|---|---|---|---|
| 0x00 | DAT | rw | write: output latch; read: pin levels through a 2-FF synchroniser |
| 0x04 | DIROUT | rw | 1 = drive the pin from DAT, 0 = high-Z. Reset 0 (all inputs) |
| 0x08 | ID | ro | `0x4750494F` ("GPIO") |
| 0x0C | NGPIO | ro | 6 |

Open drain is done the gpiolib way: a "1" on SCL/SDA is direction = input
(the pull-ups lift the line), a "0" is direction = output with DAT = 0.
`i2c-gpio` requests the lines `GPIOD_OUT_HIGH_OPEN_DRAIN` and gpiolib
emulates that on a chip without native open-drain support by switching the
direction, so the DT uses plain flags.

## On the board

```sh
ls /sys/bus/i2c/devices/              # i2c-0 = SYS_TWI, i2c-1.. = mux channels
i2cdetect -y 1                        # EEPROM channel: 50 51 52 53 answer
hexdump -C /sys/bus/nvmem/devices/board-eeprom0/nvmem | head
echo -n "TM138K-0001" | dd of=/sys/bus/nvmem/devices/board-eeprom0/nvmem bs=1 seek=0 conv=notrunc
```

(The bus numbers depend on probe order; `ls -l /sys/bus/i2c/devices/*/of_node`
tells which is which.) Writes go through the at24 driver, which drops WP for
the duration of the write and raises it again. In normal use the EEPROM is not
touched by hand: `boardcfg` (`src/apps/boardcfg/`, daemon from `S35boardcfg`)
owns the block at 0x100..0x3FF (MAC, hostname, time zone, free keys) and the
kernel reads the MAC from its nvmem cell at 0x110 for eth0.

Without the kernel side (for example to check a new bitstream with the
previous kernel), `src/apps/tests/eeprom_bitbang.sh` run on the board reads
the EEPROM through busybox `devmem` on the registers above.

## Simulation

`src/rtl/gpio/tb/run_tb.sh` (iverilog): register access, direction and
tri-state behaviour against pulled-up pins, and a bit-banged I2C start plus
address byte acknowledged by a one-byte slave model.
