`default_nettype none
//============================================================================
// sensor_core.v -- on-die temperature / supply-voltage monitor.
//
// AHB-lite slave on EXTS (CPU base 0xE8004000, zero-wait, same scheme as
// audio_csr.v) in front of the FPGA's two hard ADC cores (sensor_adc.v):
// ADCLRC in temperature mode, ADCULC in voltage mode.  A free-running
// sequencer measures slot 0 (temperature) and slots 1..8 (voltage buses
// VSENCTL 0..7) in turn and keeps the latest value of each in a register, so
// a Linux read never waits for a conversion.  Conversions are started with
// ADCREQI, the sequencer waits for ADCRDY (synchronised: the ADC runs on its
// own oscillator) and latches ADCVALUE; a conversion that does not finish
// within 2^23 bus clocks (~170 ms) is flagged and the scan moves on.
//
// Register map (byte offset, 32-bit accesses):
//   0x00 CTRL     rw  [0] run (scan continuously; reset 1)
//                     [1] ADC enable (ADCEN of both cores; reset 1)
//   0x04 STATUS   ro  [3:0] slot being measured  [8] busy (a conversion is
//                     in flight)  [31:16] bus clock / 1e6 (for the driver)
//   0x08 SCANS    ro  completed scans of all 9 slots
//   0x0C TIMEOUTS ro  conversions that timed out
//   0x10 TEMP     ro  slot 0: [13:0] signed raw (/4 = deg C)  [30] valid
//                     (measured at least once)  [31] last conversion timed out
//   0x14 TCAL     rw  [9:0] FSCAL (730)  [27:16] OFFSET, signed (-1180)  -- temp
//   0x18 VCAL     rw  same for the voltage core (653 / 0)
//   0x1C ID       ro  0x53454E53 ("SENS")
//   0x20+4*n VOLT[n] ro  slot n+1 = voltage bus n (n = 0..7), format as TEMP;
//                     [13:0] raw, /2048 = volts at the bus (x divider = rail)
//============================================================================
module sensor_core #(
    parameter integer BUS_MHZ  = 50,
    parameter [23:0] SETTLE_CYC = 24'd4096,      // request low between conversions (82 us)
    parameter [23:0] CONV_CYC   = 24'h7FFFFF     // conversion timeout (~170 ms)
) (
    input  wire        hclk,
    input  wire        hresetn,
    // AHB-lite slave
    input  wire [31:0] s_haddr,
    input  wire [1:0]  s_htrans,
    input  wire        s_hwrite,
    input  wire        s_hsel,
    input  wire        s_hready_in,
    input  wire [31:0] s_hwdata,
    output wire [31:0] s_hrdata,
    output wire        s_hready,
    output wire        s_hresp,
    // ADC clock (25 MHz; unused by the cores while they run on their OSC)
    input  wire        adc_clk
);
    // ---- registers ----
    assign s_hready = 1'b1;
    assign s_hresp  = 1'b0;

    reg  [5:0]  a_off;
    reg         a_wr, a_sel;
    wire        a_active = s_hsel && s_hready_in && s_htrans[1];

    reg         run, adc_en;
    reg  [9:0]  t_fscal, v_fscal;
    reg  [11:0] t_offset, v_offset;
    reg  [31:0] scans, timeouts;
    reg  [31:0] result [0:8];
    reg  [3:0]  slot;
    reg         busy;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            a_off <= 0; a_wr <= 0; a_sel <= 0;
            run <= 1'b1; adc_en <= 1'b1;
            t_fscal <= 10'd730; t_offset <= -12'd1180;
            v_fscal <= 10'd653; v_offset <= 12'd0;
        end else begin
            a_off <= s_haddr[7:2]; a_wr <= s_hwrite; a_sel <= a_active;
            if (a_sel && a_wr) begin
                case (a_off)
                    6'h00: begin run <= s_hwdata[0]; adc_en <= s_hwdata[1]; end
                    6'h05: begin t_fscal <= s_hwdata[9:0]; t_offset <= s_hwdata[27:16]; end
                    6'h06: begin v_fscal <= s_hwdata[9:0]; v_offset <= s_hwdata[27:16]; end
                    default: ;
                endcase
            end
        end
    end

    reg [31:0] rd;
    always @(*) begin
        case (a_off)
            6'h00: rd = {30'b0, adc_en, run};
            6'h01: rd = {BUS_MHZ[15:0], 7'b0, busy, 4'b0, slot};
            6'h02: rd = scans;
            6'h03: rd = timeouts;
            6'h04: rd = result[0];
            6'h05: rd = {4'b0, t_offset, 6'b0, t_fscal};
            6'h06: rd = {4'b0, v_offset, 6'b0, v_fscal};
            6'h07: rd = 32'h5345_4E53;
            6'h08, 6'h09, 6'h0A, 6'h0B, 6'h0C, 6'h0D, 6'h0E, 6'h0F:
                   rd = result[{1'b0, a_off[2:0]} + 4'd1];
            default: rd = 32'h0;
        endcase
    end
    assign s_hrdata = rd;

    // ---- ADC cores ----
    reg         t_req, v_req;
    wire        t_rdy, v_rdy;
    wire [13:0] t_val, v_val;
    wire [2:0]  v_chan = slot[2:0] - 3'd1;     // slot 1..8 -> bus 0..7

    sensor_adc_temp u_temp (
        .clk(adc_clk), .rstn(hresetn), .en(adc_en), .req(t_req),
        .fscal(t_fscal), .offset(t_offset), .rdy(t_rdy), .value(t_val)
    );
    sensor_adc_volt u_volt (
        .clk(adc_clk), .rstn(hresetn), .en(adc_en), .req(v_req), .chan(v_chan),
        .fscal(v_fscal), .offset(v_offset), .rdy(v_rdy), .value(v_val)
    );

    // ADCRDY comes from the ADC's clock domain: synchronise; ADCVALUE is
    // stable while ADCRDY is high, so it is sampled a few cycles after the
    // synchronised edge.
    reg  [2:0]  t_rdy_s, v_rdy_s;
    always @(posedge hclk or negedge hresetn)
        if (!hresetn) begin t_rdy_s <= 0; v_rdy_s <= 0; end
        else begin t_rdy_s <= {t_rdy_s[1:0], t_rdy}; v_rdy_s <= {v_rdy_s[1:0], v_rdy}; end
    wire        rdy_s = (slot == 4'd0) ? t_rdy_s[2] : v_rdy_s[2];
    wire [13:0] val   = (slot == 4'd0) ? t_val : v_val;

    // ---- sequencer ----
    localparam [2:0] S_SETTLE = 3'd0,   // request low, input mux settling
                     S_REQ    = 3'd1,   // request high, wait for RDY to drop
                     S_CONV   = 3'd2,   // wait for RDY to rise
                     S_LATCH  = 3'd3,   // let ADCVALUE settle through, store
                     S_IDLE   = 3'd4;   // run = 0
    localparam [23:0] ACK_CYC    = 24'd4096,       // RDY must drop within this
                      LATCH_CYC  = 24'd8;
    reg  [2:0]  st;
    reg  [23:0] cnt;
    reg         tmo;
    integer     i;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            st <= S_IDLE; cnt <= 0; slot <= 0; busy <= 0; tmo <= 0;
            t_req <= 0; v_req <= 0; scans <= 0; timeouts <= 0;
            for (i = 0; i < 9; i = i + 1) result[i] <= 32'h0;
        end else begin
            case (st)
            S_IDLE: begin
                t_req <= 0; v_req <= 0; busy <= 0;
                if (run) begin st <= S_SETTLE; cnt <= 0; end
            end
            S_SETTLE: begin
                t_req <= 0; v_req <= 0; busy <= 0;
                if (!run) st <= S_IDLE;
                else if (cnt == SETTLE_CYC) begin
                    cnt <= 0; st <= S_REQ; tmo <= 0; busy <= 1;
                    if (slot == 4'd0) t_req <= 1'b1; else v_req <= 1'b1;
                end else cnt <= cnt + 24'd1;
            end
            S_REQ:                              // RDY falls after the request
                if (!rdy_s) begin cnt <= 0; st <= S_CONV; end
                else if (cnt == ACK_CYC) begin tmo <= 1; cnt <= 0; st <= S_LATCH; end
                else cnt <= cnt + 24'd1;
            S_CONV:
                if (rdy_s) begin cnt <= 0; st <= S_LATCH; end
                else if (cnt == CONV_CYC) begin tmo <= 1; cnt <= 0; st <= S_LATCH; end
                else cnt <= cnt + 24'd1;
            default: begin                      // S_LATCH
                if (cnt == LATCH_CYC) begin
                    result[slot] <= {tmo, 1'b1, 16'b0, tmo ? result[slot][13:0] : val};
                    if (tmo) timeouts <= timeouts + 1;
                    t_req <= 0; v_req <= 0; busy <= 0;
                    cnt <= 0; st <= S_SETTLE;
                    if (slot == 4'd8) begin slot <= 0; scans <= scans + 1; end
                    else slot <= slot + 4'd1;
                end else cnt <= cnt + 24'd1;
            end
            endcase
        end
    end
endmodule
`default_nettype wire
