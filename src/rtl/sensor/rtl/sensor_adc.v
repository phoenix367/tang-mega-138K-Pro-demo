`default_nettype none
//============================================================================
// sensor_adc.v -- thin wrappers around the GW5AST-138B's two hard ADC cores
// (Arora V delta-sigma ADC, UG299 ch. 4; primitive ports/parameters from
// $GOWIN_PATH/IDE/simlib/gw5a/prim_sim.v, which only declares them).
//
//   sensor_adc_temp : ADCLRC (bottom-right die corner) in TEMPERATURE mode.
//                     ADCVALUE is signed, /4 = degrees C (+/-2 C).
//   sensor_adc_volt : ADCULC (top-left) in VOLTAGE mode with the input bus
//                     chosen at run time through VSENCTL (VSEN_CTL_SEL = 1):
//                       0 vtest   = VCC    /2    (BUF_VCC_EN)
//                       1 vdd09_0 = VCCM   /2    (BUF_VCCM_EN)
//                       2 vdd09_1 = VDDA_Q0 (SerDes 0.9 V) /2 (BUF_SERDES_Q0_EN[0])
//                       3 vdd09_2 = bank 6/7 IO pair or VCC (not enabled)
//                       4 vdd18_0 = VDDX_MIPI /4 (BUF_MIPI_M0_EN[2])
//                       5 vdd18_1 = VCCX   /4    (BUF_BK6_EN[4])
//                       6 reserved
//                       7 vdd33   = VCCIO7 /8 (BUF_BK7_EN[5]; the enables of 2/4/5/7 were found by probing)
//                     ADCVALUE unsigned-ish 14-bit, /2048 = volts at the bus,
//                     times the divider = rail volts.
//
// Both: clock = internal 2.5 MHz oscillator (CLK_SEL = 0, PIOCLK_SEL = 0);
// CLK is still fed with 25 MHz so that, should the clock mux read the other
// way, DIV_CTL = 2 (/4) keeps either source inside the 0.5..8 MHz window
// (OSC 625 kHz, CLK 6.25 MHz).  The result is ready 128..2048 ADC clocks
// after the ADCREQI rising edge (ADCRDY high while the value is stable).
// FSCAL / OFFSET are the calibration constants from the user guide
// (temperature 730 / -1180, voltage 653 / 0 as the IP generator defaults).
//============================================================================
module sensor_adc_temp (
    input  wire        clk,          // 25 MHz (unused with the internal OSC)
    input  wire        rstn,
    input  wire        en,
    input  wire        req,          // rising edge starts a conversion
    input  wire [9:0]  fscal,
    input  wire [11:0] offset,
    output wire        rdy,
    output wire [13:0] value
);
    ADCLRC #(
        .DYN_BKEN("FALSE"),
        .BUF_SERDES_Q1_EN(3'b000),
        .BUF_BK2_EN(6'b000000), .BUF_BK3_EN(6'b000000),
        .BUF_BK4_EN(6'b000000), .BUF_BK5_EN(6'b000000),
        .BUF_BK10_EN(5'b00000), .BUF_BK11_EN(5'b00000),
        .CLK_SEL(1'b0), .PIOCLK_SEL(1'b0),
        .VSEN_CTL(3'b001), .VSEN_CTL_SEL(1'b0),   // adct = embedded sensor bus
        .ADC_MODE(1'b0),                          // 0 = temperature
        .DIV_CTL(2'd2),
        .SAMPLE_CNT_SEL(3'd4), .RATE_CHANGE_CTRL(3'd4)
    ) u_adc (
        .ADCINBK2A(1'b0), .ADCINBK2B(1'b0), .ADCINBK3A(1'b0), .ADCINBK3B(1'b0),
        .ADCINBK4A(1'b0), .ADCINBK4B(1'b0), .ADCINBK5A(1'b0), .ADCINBK5B(1'b0),
        .VSENCTL(3'b001),
        .FSCAL_VALUE(fscal), .OFFSET_VALUE(offset),
        .ADCEN(en), .CLK(clk), .DRSTN(rstn), .ADCREQI(req),
        .ADCRDY(rdy), .ADCVALUE(value)
    );
endmodule

module sensor_adc_volt (
    input  wire        clk,
    input  wire        rstn,
    input  wire        en,
    input  wire        req,
    input  wire [2:0]  chan,         // VSENCTL bus select, see above
    input  wire [9:0]  fscal,
    input  wire [11:0] offset,
    output wire        rdy,
    output wire [13:0] value
);
    ADCULC #(
        .DYN_BKEN("FALSE"),
        .BUF_VCC_EN(1'b1), .BUF_VCCM_EN(1'b1),
        // Undocumented buffer bits, probed on hardware (Builds 55b/55c):
        //   SERDES_Q0[0] = VDDA_Q0 (0.9 V)  -> bus 2   MIPI_M0[2] = VDDX_MIPI (1.8 V) -> bus 4
        //   BK6[4]       = VCCX (1.8 V)     -> bus 5   BK7[5]     = VCCIO7 (1.5 V DDR3 bank) -> bus 7
        .BUF_MIPI_M0_EN(3'b100), .BUF_MIPI_M1_EN(3'b000), .BUF_SERDES_Q0_EN(3'b001),
        .BUF_BK6_EN(6'b010000), .BUF_BK7_EN(6'b100000),
        .CLK_SEL(1'b0), .PIOCLK_SEL(1'b0),
        .VSEN_CTL(3'b000), .VSEN_CTL_SEL(1'b1),   // VSENCTL port drives the mux
        .ADC_MODE(1'b1),                          // 1 = voltage
        .DIV_CTL(2'd2),
        .SAMPLE_CNT_SEL(3'd4), .RATE_CHANGE_CTRL(3'd4)
    ) u_adc (
        .ADCINBK6A(1'b0), .ADCINBK6B(1'b0), .ADCINBK7A(1'b0), .ADCINBK7B(1'b0),
        .VSENCTL(chan),
        .FSCAL_VALUE(fscal), .OFFSET_VALUE(offset),
        .ADCEN(en), .CLK(clk), .DRSTN(rstn), .ADCREQI(req),
        .ADCRDY(rdy), .ADCVALUE(value)
    );
endmodule
`default_nettype wire
