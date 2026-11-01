# src/rtl/sensor/ — on-die temperature and supply-voltage monitor

The AE350 SoC has no thermal or analog block, but the GW5AST-138B silicon has two
hard delta-sigma ADC cores (Arora V ADC, UG299 ch. 4, "ADC (75K/138K)"): `ADCULC`
(top-left die corner) and `ADCLRC` (bottom-right), each with an embedded temperature
sensor (±2 °C) and a mux of internal supply rails (±5 mV). Each core's mode
(temperature / voltage) is a static parameter, so this design uses **ADCLRC for the
die temperature** and **ADCULC for voltages**. No pins, no external reference: the
cores run on their internal 2.5 MHz oscillator.

The board has no current-sense parts (only SY8105 regulators), so **power cannot be
measured**; only rail voltages.

## Blocks

- `rtl/sensor_adc.v` — wrappers instantiating the primitives directly (the IP
  generator is GUI-only; ports and parameters are declared in
  `$GOWIN_PATH/IDE/simlib/gw5a/prim_sim.v`). `sensor_adc_temp` = ADCLRC,
  `ADC_MODE = 0`; `sensor_adc_volt` = ADCULC, `ADC_MODE = 1`, `VSEN_CTL_SEL = 1` so
  `VSENCTL` picks the input bus at run time; `BUF_VCC_EN` / `BUF_VCCM_EN` connect VCC
  and VCCM to buses 0 and 1 (other buses left at their defaults).
- `rtl/sensor_core.v` — AHB-lite slave (EXTS @ `0xE8004000`, `HADDR[14]`) + scan
  sequencer: slot 0 = temperature, slots 1..8 = voltage buses 0..7, repeated forever
  (CTRL.run). Per slot: request low for 82 µs (mux settle), `ADCREQI` high, wait for
  the synchronised `ADCRDY` to drop then rise, latch `ADCVALUE`. A conversion not
  done within ~170 ms is flagged (`TIMEOUTS`, bit 31 of the slot) and the scan goes
  on. Register map in the file header; `ID` = "SENS".
- `tb/` — `run_tb.sh`: iverilog bench with behavioural `ADCULC`/`ADCLRC` models
  (`adc_model.v`; the Gowin simlib bodies are empty): scan order, values, run/stop,
  timeout flagging and recovery, calibration registers.

## Values

- Temperature: `TEMP[13:0]` signed, **/4 = °C**.
- Voltage: `VOLT[n][13:0]`, **/2048 = volts at the ADC bus**; multiply by the bus
  divider for the rail (UG299 table 4-2, ADCULC). What each bus carries depends on
  the primitive's `BUF_*` enable parameters, only two of which are documented; the
  rest were found by probing on the board (a bus with nothing enabled reads 0):

  | bus | name | rail | divider | enable | measured |
  |---|---|---|---|---|---|
  | 0 | vtest | VCC core 0.9 V | /2 | `BUF_VCC_EN` | 0.915 V |
  | 1 | vdd09_0 | VCCM | /2 | `BUF_VCCM_EN` | 1.02 V |
  | 2 | vdd09_1 | VDDA_Q0 (SerDes 0.9 V) | /2 | `BUF_SERDES_Q0_EN[0]` | 0.94 V |
  | 3 | vdd09_2 | bank 6/7 IO pair / VCC | /1 | not enabled | 0 |
  | 4 | vdd18_0 | VDDX_MIPI 1.8 V | /4 | `BUF_MIPI_M0_EN[2]` | 1.86 V |
  | 5 | vdd18_1 | VCCX 1.8 V | /4 | `BUF_BK6_EN[4]` | 1.86 V |
  | 6 | reserved | | | | 0 |
  | 7 | vdd33 | VCCIO7 (DDR3 bank, 1.5 V) | /8 | `BUF_BK7_EN[5]` | 1.55 V |

- Die temperature read 31.5–32 °C on the bench (idle and under a CPU burn alike:
  the soft SoC dissipates little; a scan takes ~60 ms, 9 slots).
- Build note: adding this core moved the placer enough that the DDR bridge's 100 MHz
  AHB clock failed by 0.65 ns (Build 55) — the worst net was `ddr_perf`'s counter
  clear with ~700 loads. It is now a registered, synthesis-duplicated signal
  (`syn_maxfan`), after which the clock closes with both placement options.
- Calibration constants `TCAL` (730 / −1180) and `VCAL` (653 / 0) are the user
  guide's typical values (the IP generator defaults); they are writable.

## Linux

hwmon driver `PATCHES/0008` (`drivers/hwmon/gowin-adc.c`, `SENSORS_GOWIN_ADC`,
DT `"gowin,ae350-adc"`): `temp1_input` (m°C), `in0..in7_input` (mV, divider applied)
with `_label`, `_fault` = last conversion timed out. Reads are plain register reads.

```
cat /sys/class/hwmon/hwmon0/temp1_input          # e.g. 41250 = 41.25 C
grep . /sys/class/hwmon/hwmon0/in*_label /sys/class/hwmon/hwmon0/in*_input
```

Raw registers from a shell: `devmem 0xE8004010` (TEMP), `0xE8004020 + 4n` (VOLT[n]).
