`default_nettype none
//============================================================================
// video_fetch.v -- DDR-clock side of the LCD video core: line fetcher.
//
// Runs in the DDR3 user clock on the read-only video port of ahb_ddr3_bridge
// (BL8 reads of 32 B, returned in issue order).  For each line request from
// video_out (req_tgl toggles; req_line = {frame parity, panel line} and
// req_info = {video, osd, source line, OSD line} are stable until the next
// request) it fills the line-RAM half (panel line & 1) of each RAM it needs,
// then reports completion (done_tgl toggles with done_line = the request).
// A request arriving while a fetch runs is kept (only the latest one: an
// older line it replaces is already late).
//
// Video (req_info video bit), from the source line s:
//   RGB565:   src_w*2 bytes from fb_base + s*stride            -> Y/RGB RAM
//   YUV 4:2:0: Y src_w bytes from fb_base + s*stride            -> Y/RGB RAM
//             U ceil(src_w/2) bytes from fb_base_u + (s/2)*stride_c -> U RAM
//             V likewise from fb_base_v                         -> V RAM
// OSD (req_info osd bit), OSD line o: osd_w*4 bytes from osd_base +
// o*osd_stride -> OSD RAM.  Reads round up to whole 32 B words; all bases and
// strides must be 32 B aligned.  RAM words per half: Y/RGB 64 (2048 Y samples,
// 1024 RGB pixels), U and V 32 (1024 samples), OSD 128 (1024 pixels).
//============================================================================
module video_fetch (
    input  wire         clk,           // DDR3 user clock
    input  wire         rstn,          // synchronous to clk
    // configuration (bus clock, static while a frame is fetched)
    input  wire         yuv,
    input  wire [31:0]  fb_base,
    input  wire [31:0]  fb_base_u,
    input  wire [31:0]  fb_base_v,
    input  wire [15:0]  stride,
    input  wire [15:0]  stride_c,
    input  wire [15:0]  src_w,         // source pixels per line
    input  wire [31:0]  osd_base,
    input  wire [15:0]  osd_stride,
    input  wire [15:0]  osd_w,
    // line requests from video_out (pixel clock)
    input  wire         req_tgl,       // asynchronous
    input  wire [15:0]  req_line,      // {frame parity, panel line}, stable when req_tgl toggles
    input  wire [25:0]  req_info,      // {video, osd, source line[11:0], OSD line[11:0]}
    output reg          done_tgl,
    output reg  [15:0]  done_line,
    // DDR video read port
    output reg          v_req,         // held until v_ack
    output reg  [31:0]  v_addr,
    input  wire         v_ack,
    input  wire         v_rvalid,
    input  wire [255:0] v_rdata,
    // line RAM write ports (256-bit words): one address/data bus, a write enable per RAM
    output reg          we_y,
    output reg          we_u,
    output reg          we_v,
    output reg          we_o,
    output reg  [7:0]   ram_waddr,     // [7] half, [6:0] word (Y uses 6 bits, U/V 5, OSD 7)
    output reg  [255:0] ram_wdata
);
    localparam [1:0] S_IDLE = 2'd0, S_MUL = 2'd1, S_ADDR = 2'd2, S_RUN = 2'd3;
    localparam [1:0] P_Y = 2'd0, P_U = 2'd1, P_V = 2'd2, P_O = 2'd3;

    reg  [2:0]  req_s;
    wire        req_edge = req_s[2] ^ req_s[1];
    reg         pending;
    reg  [1:0]  st;
    reg  [1:0]  plane;
    reg  [15:0] line;
    reg         f_vid, f_osd;
    reg  [11:0] f_src, f_ol;
    reg  [30:0] offs, offs_c, offs_o;   // source line * stride, (line / 2) * stride_c, OSD line * stride
    reg  [7:0]  n_iss, n_ret;           // reads left to issue / to return
    reg  [6:0]  widx;                   // word within the plane's half
    reg  [7:0]  n_rgb, n_y, n_c, n_o;   // words per line of each plane (registered from the config)

    // after a plane: the next one, or the end of the line
    wire        last_plane = (plane == P_O) || (plane == P_V && !f_osd) || (plane == P_Y && !yuv && !f_osd);
    wire [1:0]  next_plane = (plane == P_Y && yuv) ? P_U : (plane == P_U) ? P_V : P_O;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            req_s <= 0; pending <= 0; st <= S_IDLE; plane <= 0; line <= 0;
            f_vid <= 0; f_osd <= 0; f_src <= 0; f_ol <= 0; offs <= 0; offs_c <= 0; offs_o <= 0;
            n_iss <= 0; n_ret <= 0; widx <= 0; n_rgb <= 0; n_y <= 0; n_c <= 0; n_o <= 0;
            done_tgl <= 0; done_line <= 16'hFFFF;
            v_req <= 0; v_addr <= 0;
            we_y <= 0; we_u <= 0; we_v <= 0; we_o <= 0; ram_waddr <= 0; ram_wdata <= 0;
        end else begin
            req_s <= {req_s[1:0], req_tgl};
            we_y <= 1'b0; we_u <= 1'b0; we_v <= 1'b0; we_o <= 1'b0;
            if (req_edge) pending <= 1'b1;
            // words per line: RGB ceil(w/16), Y ceil(w/32), chroma ceil(w/64), OSD ceil(w/8)
            n_rgb <= src_w[11:4]  + {7'd0, src_w[3:0] != 4'd0};
            n_y   <= src_w[12:5]  + {7'd0, src_w[4:0] != 5'd0};
            n_c   <= {1'b0, src_w[12:6]} + {7'd0, src_w[5:0] != 6'd0};
            n_o   <= osd_w[10:3]  + {7'd0, osd_w[2:0] != 3'd0};

            case (st)
            S_IDLE:
                if (pending && !req_edge) begin
                    pending <= 1'b0;
                    line    <= req_line;
                    f_vid   <= req_info[25];
                    f_osd   <= req_info[24];
                    f_src   <= req_info[23:12];
                    f_ol    <= req_info[11:0];
                    plane   <= req_info[25] ? P_Y : P_O;
                    st      <= S_MUL;
                end
            S_MUL: begin                        // registered multiplies (DSP)
                offs   <= f_src * stride;
                offs_c <= {1'b0, f_src[11:1]} * stride_c;
                offs_o <= f_ol * osd_stride;
                st     <= S_ADDR;
            end
            S_ADDR: begin
                case (plane)
                P_U: begin v_addr <= fb_base_u + {1'b0, offs_c}; n_iss <= n_c; n_ret <= n_c; end
                P_V: begin v_addr <= fb_base_v + {1'b0, offs_c}; n_iss <= n_c; n_ret <= n_c; end
                P_O: begin v_addr <= osd_base  + {1'b0, offs_o}; n_iss <= n_o; n_ret <= n_o; end
                default: begin
                    v_addr <= fb_base + {1'b0, offs};
                    n_iss  <= yuv ? n_y : n_rgb;
                    n_ret  <= yuv ? n_y : n_rgb;
                end
                endcase
                v_req <= (plane == P_U || plane == P_V) ? (n_c != 8'd0) : (plane == P_O) ? (n_o != 8'd0) :
                         yuv ? (n_y != 8'd0) : (n_rgb != 8'd0);
                widx  <= 7'd0;
                st    <= S_RUN;
            end
            default: begin                      // S_RUN
                if (v_ack) begin
                    v_addr <= v_addr + 32'd32;
                    n_iss  <= n_iss - 8'd1;
                    v_req  <= (n_iss != 8'd1);
                end
                if (v_rvalid) begin
                    we_y      <= (plane == P_Y);
                    we_u      <= (plane == P_U);
                    we_v      <= (plane == P_V);
                    we_o      <= (plane == P_O);
                    ram_waddr <= {line[0], widx};
                    ram_wdata <= v_rdata;
                    widx      <= widx + 7'd1;
                    n_ret     <= n_ret - 8'd1;
                end
                if (n_ret == 8'd0 || (v_rvalid && n_ret == 8'd1)) begin
                    if (!last_plane) begin
                        plane <= next_plane;
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
