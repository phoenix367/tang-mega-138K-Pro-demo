`default_nettype none
//============================================================================
// video_fetch.v -- DDR-clock side of the LCD video core: line fetcher.
//
// Runs in the DDR3 user clock on the read-only video port of ahb_ddr3_bridge
// (BL8 reads of 32 B = 16 RGB565 pixels, returned in issue order).  For each
// line request from video_out (req_tgl toggles; req_line = {frame parity,
// index} is stable until the next request) it reads hactive*2 bytes from
// fb_base + index*stride into line-RAM half (index & 1), then reports
// completion (done_tgl toggles with done_line = the line).  A request arriving
// while a fetch runs is kept (only the latest one: an older line it replaces
// is already late).  fb_base and stride must be 32 B aligned, hactive a
// multiple of 16 (<= 1024).
//============================================================================
module video_fetch (
    input  wire         clk,           // DDR3 user clock
    input  wire         rstn,          // synchronous to clk
    // configuration (bus clock, static while scan-out runs)
    input  wire [31:0]  fb_base,
    input  wire [15:0]  stride,
    input  wire [15:0]  hactive,
    // line requests from video_out (pixel clock)
    input  wire         req_tgl,       // asynchronous
    input  wire [15:0]  req_line,      // {frame parity, index}, stable when req_tgl toggles
    output reg          done_tgl,
    output reg  [15:0]  done_line,
    // DDR video read port
    output reg          v_req,         // held until v_ack
    output reg  [31:0]  v_addr,
    input  wire         v_ack,
    input  wire         v_rvalid,
    input  wire [255:0] v_rdata,
    // line RAM write port (256-bit words = 16 pixels)
    output reg          ram_we,
    output reg  [6:0]   ram_waddr,
    output reg  [255:0] ram_wdata
);
    localparam [1:0] S_IDLE = 2'd0, S_MUL = 2'd1, S_ADDR = 2'd2, S_RUN = 2'd3;

    reg  [2:0]  req_s;
    wire        req_edge = req_s[2] ^ req_s[1];
    reg         pending;
    reg  [1:0]  st;
    reg  [15:0] line;
    reg  [30:0] offs;                   // index * stride
    reg  [6:0]  n_iss, n_ret;           // reads left to issue / to return
    reg  [5:0]  widx;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            req_s <= 0; pending <= 0; st <= S_IDLE; line <= 0; offs <= 0;
            n_iss <= 0; n_ret <= 0; widx <= 0;
            done_tgl <= 0; done_line <= 16'hFFFF;
            v_req <= 0; v_addr <= 0;
            ram_we <= 0; ram_waddr <= 0; ram_wdata <= 0;
        end else begin
            req_s  <= {req_s[1:0], req_tgl};
            ram_we <= 1'b0;
            if (req_edge) pending <= 1'b1;

            case (st)
            S_IDLE:
                if (pending && !req_edge) begin
                    pending <= 1'b0;
                    line    <= req_line;
                    st      <= S_MUL;
                end
            S_MUL: begin                        // registered multiply (DSP)
                offs <= line[14:0] * stride;
                st   <= S_ADDR;
            end
            S_ADDR: begin
                v_addr <= fb_base + {1'b0, offs};
                v_req  <= (hactive[15:4] != 12'd0);
                n_iss  <= hactive[10:4];        // 32 B reads
                n_ret  <= hactive[10:4];
                widx   <= 6'd0;
                st     <= S_RUN;
            end
            default: begin                      // S_RUN
                if (v_ack) begin
                    v_addr <= v_addr + 32'd32;
                    n_iss  <= n_iss - 7'd1;
                    v_req  <= (n_iss != 7'd1);
                end
                if (v_rvalid) begin
                    ram_we    <= 1'b1;
                    ram_waddr <= {line[0], widx};
                    ram_wdata <= v_rdata;
                    widx      <= widx + 6'd1;
                    n_ret     <= n_ret - 7'd1;
                end
                if (n_ret == 7'd0 || (v_rvalid && n_ret == 7'd1)) begin
                    done_line <= line;
                    done_tgl  <= ~done_tgl;
                    st        <= S_IDLE;
                end
            end
            endcase
        end
    end
endmodule
`default_nettype wire
