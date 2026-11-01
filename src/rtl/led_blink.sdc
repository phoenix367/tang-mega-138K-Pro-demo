// Timing constraints for led_blink.
// Set the period to match your board oscillator and the CLK_FREQ_HZ
// parameter in src/led_blink.v. 20 ns = 50 MHz.
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
