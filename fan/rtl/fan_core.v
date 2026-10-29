`default_nettype none
//============================================================================
// fan_core.v -- 4-pin fan PWM control + tachometer.
//
// AHB-lite slave on EXTS (CPU base 0xE8008000, zero-wait, same scheme as
// sensor_core.v).  Drives the Dock's fan header (Fan_CPU_4pin M1): PWM on
// T17, tacho on T18 (open collector from the fan, 10k pull-up to 3.3 V on
// the Dock).  Dock rev 4071d wires T17 straight to the fan's PWM input
// (high = fast); rev 4071f instead switches the fan's 5 V through a P-MOSFET
// whose gate is T17 (low = on), hence CTRL.inv.
//
// PWM: a free-running cycle counter of PERIOD bus clocks; the output is on
// while the counter is below DUTY (DUTY >= PERIOD = always on, 0 = always
// off).  Reset: 25 kHz (the Intel 4-wire fan spec), 100 % (fan runs full
// until software sets a curve).
// Tacho: 3-FF synchroniser + 32-cycle glitch filter, falling edges counted;
// RATE = edges in the last one-second window (2 pulses per revolution for
// a standard fan: RPM = RATE * 30), CNT = free-running edge count.
//
// Register map (byte offset, 32-bit accesses):
//   0x00 CTRL    rw  [0] enable (0 = output held at the "off" level; reset 1)
//                    [1] inv: invert the pin (rev 4071f MOSFET switch; reset 0)
//   0x04 PERIOD  rw  [19:0] PWM period in bus clocks (reset BUS_MHZ*40 = 25 kHz)
//   0x08 DUTY    rw  [19:0] on-time in bus clocks (reset = PERIOD)
//   0x0C RATE    ro  [15:0] tacho edges in the last second  [31] tacho level now
//   0x10 CNT     ro  tacho edge count (free running)
//   0x14 ID      ro  0x46414E20 ("FAN ")
//   0x18 STATUS  ro  [19:0] PWM counter (debug)  [30] pin level  [31] seconds tick
//============================================================================
module fan_core #(
    parameter integer BUS_MHZ = 50
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
    // fan header
    output reg         fan_pwm,
    input  wire        fan_tach
);
    localparam [19:0] PERIOD_RST = BUS_MHZ * 40;          // 25 kHz
    localparam [31:0] SEC_CYC    = BUS_MHZ * 1000000;

    assign s_hready = 1'b1;
    assign s_hresp  = 1'b0;

    // ---- registers --------------------------------------------------------
    reg  [5:0]  a_off;
    reg         a_wr, a_sel;
    wire        a_active = s_hsel && s_hready_in && s_htrans[1];
    reg         en, inv;
    reg  [19:0] period, duty;
    reg  [15:0] rate;
    reg  [31:0] cnt;
    reg  [19:0] pwm_cnt;
    reg         sec_tick;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            a_off <= 6'd0; a_wr <= 1'b0; a_sel <= 1'b0;
            en <= 1'b1; inv <= 1'b0;
            period <= PERIOD_RST; duty <= PERIOD_RST;
        end else begin
            a_off <= s_haddr[7:2]; a_wr <= s_hwrite; a_sel <= a_active;
            if (a_sel && a_wr) begin
                case (a_off)
                    6'h00: begin en <= s_hwdata[0]; inv <= s_hwdata[1]; end
                    6'h01: period <= (s_hwdata[19:0] == 20'd0) ? 20'd1 : s_hwdata[19:0];
                    6'h02: duty   <= s_hwdata[19:0];
                    default: ;
                endcase
            end
        end
    end

    reg [31:0] rd;
    always @(*) begin
        case (s_haddr[7:2])
            6'h00: rd = {30'd0, inv, en};
            6'h01: rd = {12'd0, period};
            6'h02: rd = {12'd0, duty};
            6'h03: rd = {tach_s, 15'd0, rate};
            6'h04: rd = cnt;
            6'h05: rd = 32'h46414E20;
            6'h06: rd = {sec_tick, fan_pwm, 10'd0, pwm_cnt};
            default: rd = 32'd0;
        endcase
    end
    assign s_hrdata = rd;

    // ---- PWM --------------------------------------------------------------
    wire on_raw = en && (pwm_cnt < duty);
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            pwm_cnt <= 20'd0;
            fan_pwm <= 1'b1;
        end else begin
            pwm_cnt <= (pwm_cnt + 20'd1 >= period) ? 20'd0 : pwm_cnt + 20'd1;
            fan_pwm <= on_raw ^ inv;
        end
    end

    // ---- tacho ------------------------------------------------------------
    reg  [2:0]  tach_sync;
    reg         tach_s;          // filtered level
    reg  [4:0]  tach_flt;
    reg  [15:0] acc;
    reg  [31:0] sec_cnt;
    wire        tach_in = tach_sync[2];
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            tach_sync <= 3'b111; tach_s <= 1'b1; tach_flt <= 5'd0;
            acc <= 16'd0; rate <= 16'd0; cnt <= 32'd0; sec_cnt <= 32'd0; sec_tick <= 1'b0;
        end else begin
            tach_sync <= {tach_sync[1:0], fan_tach};
            // the level must hold for 32 cycles before it is accepted
            if (tach_in == tach_s) tach_flt <= 5'd0;
            else if (tach_flt == 5'd31) begin tach_flt <= 5'd0; tach_s <= tach_in; end
            else tach_flt <= tach_flt + 5'd1;
            // falling edge of the filtered level
            if (tach_flt == 5'd31 && tach_in != tach_s && !tach_in) begin
                cnt <= cnt + 32'd1;
                if (acc != 16'hFFFF) acc <= acc + 16'd1;
            end
            // one-second window
            sec_tick <= 1'b0;
            if (sec_cnt == SEC_CYC - 1) begin
                sec_cnt <= 32'd0;
                rate <= acc + ((tach_flt == 5'd31 && tach_in != tach_s && !tach_in) ? 16'd1 : 16'd0);
                acc <= 16'd0;
                sec_tick <= 1'b1;
            end else
                sec_cnt <= sec_cnt + 32'd1;
        end
    end
endmodule
`default_nettype wire
