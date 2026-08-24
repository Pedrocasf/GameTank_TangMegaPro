//============================================================================
//  Framebuffer display: the console's raster in, a standard VGA mode out.
//
//  Bring-up established that this display will not lock to the console's
//  native 908x524 @ 60.19 Hz raster, while the identical TMDS path carrying
//  640x480@60 works (docs/PORTING_TANG.md §T2). Sending the native raster to
//  a sink is therefore not viable, and a line doubler cannot fix it: the
//  console's line and frame rates are its own, so reaching a standard mode
//  means decoupling the two rasters with a frame store. This is the small
//  version of what Pedrocasf/486tang does with ddr3_framebuffer, and what
//  MiSTer does with ascal — 16 K pixels fit in BRAM, so no external memory is
//  involved.
//
//  Write side (clk_sys): the core's video stream is sampled back into the
//  128x128 image it came from. rtl/gtvideo.sv paints each framebuffer pixel
//  as 5 dots starting at its dot 252, and each row on two consecutive lines
//  starting at its line 16; counting from the sync edges recovers (x, y)
//  without touching the core.
//
//  Read side (clk_pix): 640x480@60, with the image scaled 5x horizontally
//  (128 * 5 = 640 exactly) and 3x vertically (384 lines), centred with black
//  bars. Integer scaling in both axes, so no resampling and no filtering.
//  The 5:3 pixel shape is wider than the console's 4:3 output; correcting
//  that is a scaler question for later, not a bring-up one.
//
//  The two rasters are asynchronous, so a frame can tear if the console
//  repaints while the display is reading it. The core already snapshots its
//  display page once per frame (rtl/frame_snapshot.sv), which keeps what
//  arrives here stable for the whole frame.
//============================================================================

module fbuf_display
(
    // ---- console side -----------------------------------------------------
    input  logic        clk_sys,
    input  logic        reset,
    input  logic        ce_pix,
    input  logic        hsync_in,
    input  logic        vsync_in,
    input  logic [7:0]  r_in,
    input  logic [7:0]  g_in,
    input  logic [7:0]  b_in,

    // ---- display side -----------------------------------------------------
    input  logic        clk_pix,
    input  logic        pix_reset,
    output logic        hsync_out,
    output logic        vsync_out,
    output logic        de_out,
    output logic [7:0]  r_out,
    output logic [7:0]  g_out,
    output logic [7:0]  b_out
);

// ---------------------------------------------------------------------------
// Where the picture sits in the console's raster (rtl/gtvideo.sv header).
// Counting starts at the sync edges, so these are offsets from those.
//   hsync rises at clk 128 = dot 64; pixel k shows at clk 504+10k = dot
//   252+5k (PX_BASE 500 plus the 4-clk fetch pipeline), so 188 dots on
//   gtvideo line 4 = vsync rising; rows start at its line 16 -> 12 lines on
// ---------------------------------------------------------------------------
localparam logic [9:0] PIX_START  = 10'd188;   // dots after hsync rise
localparam logic [2:0] DOTS_PER_X = 3'd5;
localparam logic [9:0] ROW_START  = 10'd12;    // lines after vsync rise

// Five bits per channel are stored; the console's palette has no more
// resolution than that in practice, and it halves the frame store.
wire _unused = &{1'b0, r_in[2:0], g_in[2:0], b_in[2:0], 1'b0};

logic [14:0] fb [0:16383];         // 128x128, {r[7:3], g[7:3], b[7:3]}

// ---- write side ------------------------------------------------------------
logic [9:0] dot;
logic [9:0] line;
logic       hs_d, vs_d;
wire        h_rise = hsync_in & ~hs_d;
wire        v_rise = vsync_in & ~vs_d;

logic [2:0] sub_x;                 // 0..4 within one framebuffer pixel
logic [6:0] fb_x;
logic [6:0] fb_y;
logic       row_phase;             // which of the two lines of a row
logic       taking;                // still inside the 128 pixels
logic       rows_left;             // still inside the 128 rows

always_ff @(posedge clk_sys) begin
    if (reset) begin
        dot <= '0; line <= '0; hs_d <= 1'b0; vs_d <= 1'b0;
        sub_x <= '0; fb_x <= '0; fb_y <= '0; row_phase <= 1'b0;
        taking <= 1'b0; rows_left <= 1'b0;
    end
    else begin
        hs_d <= hsync_in;
        vs_d <= vsync_in;

        // ---- vertical -----------------------------------------------------
        // vsync rises at a line boundary and hsync 32 dots later, so the two
        // edges never coincide: the line counter has to be reset by vsync on
        // its own and advanced by hsync on its own. Tying the reset to both
        // at once left it free-running, which is what scrambled the picture.
        if (v_rise) begin
            line      <= '0;
            fb_y      <= '0;
            row_phase <= 1'b0;
            rows_left <= 1'b1;
        end
        else if (h_rise) begin
            line <= line + 10'd1;
            if (line >= ROW_START && rows_left) begin
                row_phase <= ~row_phase;
                if (row_phase) begin
                    if (fb_y == 7'd127) rows_left <= 1'b0;
                    else                fb_y      <= fb_y + 7'd1;
                end
            end
        end

        // ---- horizontal ---------------------------------------------------
        if (h_rise) begin
            dot    <= '0;
            sub_x  <= '0;
            fb_x   <= '0;
            taking <= 1'b1;
        end
        else if (ce_pix) dot <= dot + 10'd1;

        // One write per framebuffer pixel, taken from the middle of its five
        // dots so a sample never straddles a transition.
        if (ce_pix && !h_rise && dot >= PIX_START && taking && rows_left &&
            line >= ROW_START) begin
            if (sub_x == 3'd2)
                fb[{fb_y, fb_x}] <= {r_in[7:3], g_in[7:3], b_in[7:3]};
            if (sub_x == DOTS_PER_X - 3'd1) begin
                sub_x <= '0;
                if (fb_x == 7'd127) taking <= 1'b0;   // borders are not picture
                else                fb_x   <= fb_x + 7'd1;
            end
            else sub_x <= sub_x + 3'd1;
        end
    end
end

// ---------------------------------------------------------------------------
// Read side: VGA 640x480@60
//   H: 640 active, 16 front, 96 sync, 48 back = 800
//   V: 480 active, 10 front,  2 sync, 33 back = 525
// ---------------------------------------------------------------------------
localparam int H_ACT = 640, H_FP = 16, H_SY = 96, H_TOT = 800;
localparam int V_ACT = 480, V_FP = 10, V_SY = 2,  V_TOT = 525;
localparam int V_PAD = (V_ACT - 128 * 3) / 2;      // 48 black lines each side

logic [9:0] hx, vy;

always_ff @(posedge clk_pix) begin
    if (pix_reset) begin
        hx <= '0;
        vy <= '0;
    end
    else if (hx == H_TOT[9:0] - 10'd1) begin
        hx <= '0;
        vy <= (vy == V_TOT[9:0] - 10'd1) ? '0 : vy + 10'd1;
    end
    else hx <= hx + 10'd1;
end

wire in_pic = (hx < H_ACT[9:0]) &&
              (vy >= V_PAD[9:0]) && (vy < V_PAD[9:0] + 10'd384);

// hx / 5 and (vy - V_PAD) / 3, without dividers: both counters just advance.
logic [2:0] hsub;
logic [6:0] rx;
logic [1:0] vsub;
logic [6:0] ry;

always_ff @(posedge clk_pix) begin
    if (pix_reset) begin
        hsub <= '0; rx <= '0; vsub <= '0; ry <= '0;
    end
    else begin
        if (hx == H_TOT[9:0] - 10'd1) begin
            hsub <= '0;
            rx   <= '0;
            if (vy == V_TOT[9:0] - 10'd1) begin
                vsub <= '0;
                ry   <= '0;
            end
            // The three lines of a source row are vy = V_PAD+3k .. +3k+2, so
            // the sub-counter has to start its run *on* the first picture
            // line, not the one before it.
            else if (vy >= V_PAD[9:0] && vy < V_PAD[9:0] + 10'd384) begin
                if (vsub == 2'd2) begin
                    vsub <= '0;
                    ry   <= ry + 7'd1;
                end
                else vsub <= vsub + 2'd1;
            end
        end
        else if (hx < H_ACT[9:0] - 10'd1) begin
            if (hsub == 3'd4) begin
                hsub <= '0;
                rx   <= rx + 7'd1;
            end
            else hsub <= hsub + 3'd1;
        end
    end
end

logic [14:0] q;
always_ff @(posedge clk_pix) q <= fb[{ry, rx}];

logic de_q, hs_q, vs_q, pic_q;
always_ff @(posedge clk_pix) begin
    hs_q  <= (hx >= H_ACT[9:0] + H_FP[9:0]) &&
             (hx <  H_ACT[9:0] + H_FP[9:0] + H_SY[9:0]);
    vs_q  <= (vy >= V_ACT[9:0] + V_FP[9:0]) &&
             (vy <  V_ACT[9:0] + V_FP[9:0] + V_SY[9:0]);
    de_q  <= (hx < H_ACT[9:0]) && (vy < V_ACT[9:0]);
    pic_q <= in_pic;
end

assign hsync_out = hs_q;
assign vsync_out = vs_q;
assign de_out    = de_q;
assign r_out     = pic_q ? {q[14:10], 3'b000} : 8'h00;
assign g_out     = pic_q ? {q[9:5],   3'b000} : 8'h00;
assign b_out     = pic_q ? {q[4:0],   3'b000} : 8'h00;

endmodule
