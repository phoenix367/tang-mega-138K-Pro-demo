# src/rtl/fan/ — fan PWM control and tachometer

Drives the Dock's 4-pin fan header **M1 "Fan_CPU_4pin"** (Dock schematic, sheet
PERIPHERALS): pin 1 GND, pin 2 +5 V, pin 3 tacho, pin 4 PWM.

| signal | FPGA pin | Dock wiring |
|---|---|---|
| `FAN_PWM` | **T17** (IOR8A, bank 2, 3.3 V) | rev **4071d**: straight to the fan's PWM input (pin 4). rev **4071f**: gate of Q9 (DP2101W P-MOSFET, R266 15 Ω) that switches the fan's +5 V; pin 4 only via R265 (not populated). |
| `FAN_TACH` | **T18** (IOR8B, bank 2) | fan's open-collector tacho (pin 3), R26 10 kΩ pull-up to +3V3 |

So on rev d the pin is a normal 25 kHz PWM, high = fast; on rev f the same pin
chops the supply, **low = on**: the core has an invert bit (`CTRL.inv`, DT
`gowin,pwm-inverted`) and a programmable period, since supply chopping suits a
lower frequency than 25 kHz. A fan with its PWM input left open (rev f) runs
at full speed whenever it has power, which is what makes the supply switch work.

## Core (`rtl/fan_core.v`)

AHB-lite slave on EXTS @ `0xE8008000` (`HADDR[15]`), zero-wait, 50 MHz bus.

| offset | name | bits |
|---|---|---|
| 0x00 | CTRL | [0] enable (0 = pin held at the "off" level), [1] inv — reset `0x1` |
| 0x04 | PERIOD | [19:0] PWM period in bus clocks — reset 2000 (25 kHz) |
| 0x08 | DUTY | [19:0] on-time in bus clocks (≥ PERIOD = always on) — reset 2000 (100 %) |
| 0x0C | RATE | [15:0] tacho falling edges in the last second, [31] tacho level |
| 0x10 | CNT | free-running tacho edge count |
| 0x14 | ID | `0x46414E20` "FAN " |
| 0x18 | STATUS | [19:0] PWM counter, [30] pin level, [31] one-second tick (debug) |

Tacho input: 3-FF synchroniser, a level must hold 32 clocks (0.64 µs) before it
counts, falling edges counted. Standard fans give 2 pulses per revolution:
RPM = RATE × 30. Reset state is full speed so the fan runs from configuration
until Linux lowers it.

`tb/run_tb.sh`: iverilog bench (register defaults, duty/period/inversion
measured on the pin, glitch rejection, edge count, one-second rate).

## Linux

`PATCHES/0009` → `drivers/hwmon/gowin-fan.c` (`SENSORS_GOWIN_FAN`, DT
`"gowin,ae350-fan"`, node `fan0` in `linux/ae350-linux.dts`): hwmon `gowin_fan`
with `pwm1` (0..255), `pwm1_enable` (1 = manual, 0 = full speed), `fan1_input`
(RPM), `fan1_fault` (no pulses while PWM > 0). DT properties: `clock-frequency`
(bus, 50 MHz), `gowin,pulses-per-rev` (2), `gowin,pwm-frequency` (Hz, default
25 kHz), `gowin,pwm-inverted` (rev 4071f).

`/etc/init.d/S80fan` runs a temperature curve from the die sensor
(`gowin-adc`): PWM 64 up to 35 °C, linear to 255 at 60 °C, every 5 s. The
desktop's Settings panel has an "Automatic" switch (starts/stops S80fan) and a
manual slider; the System panel shows RPM and PWM, and the status bar shows the
rpm permanently, turning into a red "FAN STOPPED" warning when `fan1_fault` is set
or the rpm reads 0.

```
H=/sys/class/hwmon/$(grep -l gowin_fan /sys/class/hwmon/*/name | cut -d/ -f5)
cat $H/fan1_input                      # rpm
/etc/init.d/S80fan stop; echo 128 > $H/pwm1    # 50 % by hand
```

## Board note (2026-10-29)

The fan shipped on this Dock is a **3-pin** fan (GND, +5 V, tacho): it has no PWM
input, so `pwm1` cannot change its speed on either Dock revision; only the RPM
readout works (about 5700 rpm). Options: a 4-pin fan on the header (rev 4071d
works as built; rev 4071f also needs R265 fitted with 0 Ω), or on rev 4071f supply
chopping through Q9: a pull-up from Q9's gate to +5 V and `FAN_PWM` as open-drain
(`OPEN_DRAIN=ON` in the `.cst`), with a low PWM frequency (`gowin,pwm-frequency`
of a few hundred Hz) and a tacho reading that is only valid in the on-phases. The
DP2101W cannot be switched off by the 3.3 V pin as wired (Vgs = -1.7 V, threshold
-0.4 to -1.0 V).

