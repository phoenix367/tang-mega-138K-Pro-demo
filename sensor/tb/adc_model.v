`default_nettype none
//============================================================================
// adc_model.v -- behavioural stand-ins for the GW5A ADCULC / ADCLRC hard
// cores (the Gowin simlib only declares their ports).  Same ports and
// parameters as prim_sim.v.  Each runs its own ~2.5 MHz oscillator, divided
// by DIV_CTL; a rising edge on ADCREQI drops ADCRDY within a few ADC clocks,
// and CONV_CLKS ADC clocks later ADCVALUE is updated and ADCRDY rises.
// Temperature mode returns `tb_temp_q` (quarter degrees); voltage mode
// returns `tb_volt_q[VSENCTL]` (1/2048 V), both set by the testbench.
//============================================================================
module adc_model_common #(
    parameter ADC_MODE = 1'b0,
    parameter DIV_CTL  = 2'd0,
    parameter integer CONV_CLKS = 300
) (
    input  wire [2:0]  VSENCTL,
    input  wire        ADCEN, DRSTN, ADCREQI,
    output reg         ADCRDY,
    output reg  [13:0] ADCVALUE
);
    reg osc = 0;
    always #200 osc = ~osc;                       // 2.5 MHz
    reg [2:0] div = 0;
    always @(posedge osc) div <= div + 1;
    wire aclk = (DIV_CTL == 0) ? osc : (DIV_CTL == 1) ? div[0] : (DIV_CTL == 2) ? div[1] : div[2];

    reg  [1:0] req_s = 0;
    integer    n = -1;
    initial begin ADCRDY = 0; ADCVALUE = 0; end
    always @(posedge aclk or negedge DRSTN) begin
        if (!DRSTN) begin req_s <= 0; n <= -1; ADCRDY <= 0; ADCVALUE <= 0; end
        else begin
            req_s <= {req_s[0], ADCREQI};
            if (req_s == 2'b01 && ADCEN) begin n <= CONV_CLKS; ADCRDY <= 0; end
            else if (n > 0) n <= n - 1;
            else if (n == 0) begin
                n <= -1; ADCRDY <= 1;
                ADCVALUE <= ADC_MODE ? tb_sensor.volt_q[VSENCTL] : tb_sensor.temp_q;
            end
        end
    end
endmodule

module ADCULC (
    input  wire ADCINBK6A, ADCINBK6B, ADCINBK7A, ADCINBK7B,
    input  wire [2:0]  VSENCTL,
    input  wire [9:0]  FSCAL_VALUE,
    input  wire [11:0] OFFSET_VALUE,
    input  wire        ADCEN, CLK, DRSTN, ADCREQI,
    output wire        ADCRDY,
    output wire [13:0] ADCVALUE
);
    parameter DYN_BKEN = "FALSE";
    parameter BUF_VCC_EN = 1'b0, BUF_VCCM_EN = 1'b0;
    parameter BUF_MIPI_M0_EN = 3'b000, BUF_MIPI_M1_EN = 3'b000, BUF_SERDES_Q0_EN = 3'b000;
    parameter BUF_BK6_EN = 6'b000000, BUF_BK7_EN = 6'b000000;
    parameter CLK_SEL = 1'b0, PIOCLK_SEL = 1'b0, VSEN_CTL = 3'b000, VSEN_CTL_SEL = 1'b0;
    parameter ADC_MODE = 1'b0, DIV_CTL = 2'd0;
    parameter SAMPLE_CNT_SEL = 3'd4, RATE_CHANGE_CTRL = 3'd4;
    wire [2:0] sel = VSEN_CTL_SEL ? VSENCTL : VSEN_CTL;
    adc_model_common #(.ADC_MODE(ADC_MODE), .DIV_CTL(DIV_CTL), .CONV_CLKS(300)) m (
        .VSENCTL(sel), .ADCEN(ADCEN), .DRSTN(DRSTN), .ADCREQI(ADCREQI),
        .ADCRDY(ADCRDY), .ADCVALUE(ADCVALUE));
endmodule

module ADCLRC (
    input  wire ADCINBK2A, ADCINBK2B, ADCINBK3A, ADCINBK3B,
    input  wire ADCINBK4A, ADCINBK4B, ADCINBK5A, ADCINBK5B,
    input  wire [2:0]  VSENCTL,
    input  wire [9:0]  FSCAL_VALUE,
    input  wire [11:0] OFFSET_VALUE,
    input  wire        ADCEN, CLK, DRSTN, ADCREQI,
    output wire        ADCRDY,
    output wire [13:0] ADCVALUE
);
    parameter DYN_BKEN = "FALSE";
    parameter BUF_SERDES_Q1_EN = 3'b000;
    parameter BUF_BK2_EN = 6'b000000, BUF_BK3_EN = 6'b000000, BUF_BK4_EN = 6'b000000, BUF_BK5_EN = 6'b000000;
    parameter BUF_BK10_EN = 5'b00000, BUF_BK11_EN = 5'b00000;
    parameter CLK_SEL = 1'b0, PIOCLK_SEL = 1'b0, VSEN_CTL = 3'b000, VSEN_CTL_SEL = 1'b0;
    parameter ADC_MODE = 1'b0, DIV_CTL = 2'd0;
    parameter SAMPLE_CNT_SEL = 3'd4, RATE_CHANGE_CTRL = 3'd4;
    wire [2:0] sel = VSEN_CTL_SEL ? VSENCTL : VSEN_CTL;
    adc_model_common #(.ADC_MODE(ADC_MODE), .DIV_CTL(DIV_CTL), .CONV_CLKS(500)) m (
        .VSENCTL(sel), .ADCEN(ADCEN), .DRSTN(DRSTN), .ADCREQI(ADCREQI),
        .ADCRDY(ADCRDY), .ADCVALUE(ADCVALUE));
endmodule
`default_nettype wire
