`default_nettype none
//============================================================================
// video_fetch.v -- DDR-clock side of the LCD video core: line fetcher.
//
// Runs in the DDR3 user clock on the read-only video port of ahb_ddr3_bridge
// (BL8 reads of 32 B, returned in issue order).  For each line request from
// video_out (req_tgl toggles; req_line = {frame parity, index} is stable until
// the next request) it fills line-RAM half (index & 1), then reports
// completion (done_tgl toggles with done_line = the line).  A request arriving
// while a fetch runs is kept (only the latest one: an older line it replaces
// is already late).
//
// RGB565 mode: hactive*2 bytes from fb_base + index*stride into words 0..
// (16 pixels per 32 B word; hactive a multiple of 16, <= 1024).
// YUV 4:2:0 mode (yuv = 1): three planes of the same line, each in its own
// region of the half -- Y: hactive bytes from fb_base + index*stride into
// words 0..31; U: hactive/2 bytes from fb_base_u + (index/2)*stride_c into
// words 32..47; V: likewise from fb_base_v into words 48..63.  hactive a
// multiple of 32; the chroma read rounds up to whole 32 B words.  Same bytes
// per line as RGB565 (1.5 + ~0.5 of padding), so the port load is unchanged.
// All bases and strides must be 32 B aligned.
//============================================================================
module video_fetch (
    input  wire         clk,           // DDR3 user clock
    input  wire         rstn,          // synchronous to clk
    // configuration (bus clock, static while scan-out runs)
    input  wire         yuv,
    input  wire [31:0]  fb_base,
    input  wire [31:0]  fb_base_u,
    input  wire [31:0]  fb_base_v,
    input  wire [15:0]  stride,
    input  wire [15:0]  stride_c,
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
    // line RAM write port (256-bit words)
    output reg          ram_we,
    output reg  [6:0]   ram_waddr,
    output reg  [255:0] ram_wdata
);
    localparam [1:0] S_IDLE = 2'd0, S_MUL = 2'd1, S_ADDR = 2'd2, S_RUN = 2'd3;

    reg  [2:0]  req_s;
    wire        req_edge = req_s[2] ^ req_s[1];
    reg         pending;
    reg  [1:0]  st;
    reg  [1:0]  plane;                  // 0 = RGB or Y, 1 = U, 2 = V
    reg  [15:0] line;
    reg  [30:0] offs, offs_c;           // index * stride, (index / 2) * stride_c
    reg  [6:0]  n_iss, n_ret;           // reads left to issue / to return
    reg  [5:0]  widx;                   // word within the region
    reg  [1:0]  region;                 // {0: 0.., 2: 32.., 3: 48..} as waddr[5:4] base

    // words per plane line: RGB hactive*2/32, Y hactive/32, chroma ceil(hactive/64)
    wire [6:0] n_rgb = hactive[10:4];
    wire [6:0] n_y   = {1'b0, hactive[10:5]};
    wire [6:0] n_c   = {1'b0, hactive[10:6]} + {6'd0, (hactive[5:0] != 6'd0)};

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            req_s <= 0; pending <= 0; st <= S_IDLE; plane <= 0; line <= 0; offs <= 0; offs_c <= 0;
            n_iss <= 0; n_ret <= 0; widx <= 0; region <= 0;
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
                    plane   <= 2'd0;
                    st      <= S_MUL;
                end
            S_MUL: begin                        // registered multiplies (DSP)
                offs   <= line[14:0] * stride;
                offs_c <= {1'b0, line[14:1]} * stride_c;
                st     <= S_ADDR;
            end
            S_ADDR: begin
                case (plane)
                2'd1: begin v_addr <= fb_base_u + {1'b0, offs_c}; n_iss <= n_c;   n_ret <= n_c;   region <= 2'b10; end
                2'd2: begin v_addr <= fb_base_v + {1'b0, offs_c}; n_iss <= n_c;   n_ret <= n_c;   region <= 2'b11; end
                default: begin
                    v_addr <= fb_base + {1'b0, offs};
                    n_iss  <= yuv ? n_y : n_rgb;
                    n_ret  <= yuv ? n_y : n_rgb;
                    region <= 2'b00;
                end
                endcase
                v_req <= (plane == 2'd0) ? (yuv ? (n_y != 7'd0) : (n_rgb != 7'd0)) : (n_c != 7'd0);
                widx  <= 6'd0;
                st    <= S_RUN;
            end
            default: begin                      // S_RUN
                if (v_ack) begin
                    v_addr <= v_addr + 32'd32;
                    n_iss  <= n_iss - 7'd1;
                    v_req  <= (n_iss != 7'd1);
                end
                if (v_rvalid) begin
                    ram_we    <= 1'b1;
                    // RGB: words 0..63; YUV: Y 0..31, U 32..47, V 48..63
                    ram_waddr <= {line[0], (region == 2'b00) ? widx : {region, widx[3:0]}};
                    ram_wdata <= v_rdata;
                    widx      <= widx + 6'd1;
                    n_ret     <= n_ret - 7'd1;
                end
                if (n_ret == 7'd0 || (v_rvalid && n_ret == 7'd1)) begin
                    if (yuv && plane != 2'd2) begin
                        plane <= plane + 2'd1;
                        st    <= S_ADDR;
                    end else begin
                        done_line <= line;
                        done_tgl  <= ~done_tgl;
                        st        <= S_IDLE;
                    end
                end
            end
            endcase
        end
    end
endmodule
`default_nettype wire
