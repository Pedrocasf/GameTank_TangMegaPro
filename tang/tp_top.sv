//============================================================================
//  Bring-up test pattern: VGA 640x480@60 colour bars out of the same DVI
//  transmitter the console uses.
//
//  This exists to answer one question that the console build cannot: does the
//  TMDS link work at all? It shares tang/dvi_tx.sv, tang/tmds_encoder.sv, the
//  pin constraints and the board, and differs only in what drives them — a
//  standard, universally accepted video mode from a self-contained pattern
//  generator, with no console, no line doubler and no memory anywhere in the
//  path.
//
//    picture  -> the link, serializers, buffers and pin constraints are good,
//                and the fault is the console's native 908x524 @ 60.2 Hz mode
//                or the doubler feeding it;
//    nothing  -> the fault is in the output stage or the board, and no amount
//                of work on the console video path will help.
//
//  Build with: gw_sh tang/syn.tcl tp
//============================================================================

module tp_top
(
    input  logic       clk,          // 50 MHz, dock pin P16
    input  logic       rst_n,        // board button, active low

    output logic [4:0] led,          // active low

    output logic       tmds_clk_p,
    output logic       tmds_clk_n,
    output logic [2:0] tmds_d_p,
    output logic [2:0] tmds_d_n
);

wire clk_pix, clk_serial, pll_lock;

`ifdef TP_CONSOLE_MODE
// Same generator, but on the console's own clocks and raster totals. If the
// bars survive the standard mode and vanish here, the console's mode is what
// the display refuses — and nothing about the doubler or the core is at fault.
pll_tang pll
(
    .clkin      (clk),
    .clk_sys    (clk_pix),
    .clk_serial (clk_serial),
    .clk_sdram  (),
    .lock       (pll_lock)
);
`else
pll_tp pll
(
    .clkin      (clk),
    .clk_pix    (clk_pix),
    .clk_serial (clk_serial),
    .lock       (pll_lock)
);
`endif

logic [15:0] rst_cnt = '0;
always_ff @(posedge clk_pix) begin
    if (!pll_lock || !rst_n) rst_cnt <= '0;
    else if (!rst_cnt[15])   rst_cnt <= rst_cnt + 1'd1;
end
wire reset = ~rst_cnt[15];

// ---- VGA 640x480@60 timing ------------------------------------------------
// H: 640 active, 16 front, 96 sync, 48 back = 800
// V: 480 active, 10 front,  2 sync, 33 back = 525
`ifdef TP_CONSOLE_MODE
// rtl/gtvideo.sv doubled: 908 dots, hsync at 32-63, active from 160; 524
// lines, vsync at 8-15, active from 32.
localparam int H_ACT = 748, H_FP = 0,  H_SY = 32, H_TOT = 908;
localparam int V_ACT = 492, V_FP = 0,  V_SY = 8,  V_TOT = 524;
`else
localparam int H_ACT = 640, H_FP = 16, H_SY = 96, H_TOT = 800;
localparam int V_ACT = 480, V_FP = 10, V_SY = 2,  V_TOT = 525;
`endif

logic [9:0] hx;
logic [9:0] vy;

always_ff @(posedge clk_pix) begin
    if (reset) begin
        hx <= '0;
        vy <= '0;
    end
    else if (hx == H_TOT - 1) begin
        hx <= '0;
        vy <= (vy == V_TOT - 1) ? '0 : vy + 10'd1;
    end
    else hx <= hx + 10'd1;
end

wire hsync = (hx >= H_ACT + H_FP) && (hx < H_ACT + H_FP + H_SY);
wire vsync = (vy >= V_ACT + V_FP) && (vy < V_ACT + V_FP + V_SY);
wire de    = (hx < H_ACT) && (vy < V_ACT);

// ---- colour bars, plus a moving band so a frozen frame is obvious --------
logic [7:0] frame;
always_ff @(posedge clk_pix)
    if (hx == 0 && vy == 0) frame <= frame + 8'd1;

wire [2:0] bar = hx[9:7];               // eight bars of 80 pixels
wire       band = (vy[8:0] >= {1'b0, frame}) && (vy[8:0] < {1'b0, frame} + 9'd16);

wire [7:0] r_out = band ? 8'hFF : {8{bar[2]}};
wire [7:0] g_out = band ? 8'hFF : {8{bar[1]}};
wire [7:0] b_out = band ? 8'hFF : {8{bar[0]}};

dvi_tx dvi
(
    .clk_pix    (clk_pix),
    .clk_serial (clk_serial),
    .reset      (reset),
    .de         (de),
    .hsync      (hsync),
    .vsync      (vsync),
    .r          (de ? r_out : 8'h00),
    .g          (de ? g_out : 8'h00),
    .b          (de ? b_out : 8'h00),
    .tmds_clk_p (tmds_clk_p),
    .tmds_clk_n (tmds_clk_n),
    .tmds_d_p   (tmds_d_p),
    .tmds_d_n   (tmds_d_n)
);

// [0] PLL locked, [1] out of reset, [2] frame heartbeat, [4] slow blink.
logic [23:0] blink;
always_ff @(posedge clk_pix) blink <= blink + 1'd1;

assign led = ~{blink[23], 1'b0, frame[5], ~reset, pll_lock};

endmodule
