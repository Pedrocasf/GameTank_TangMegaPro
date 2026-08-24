//============================================================================
//  GameTank core — Tang Mega 138K Pro board top (T2: video bring-up).
//
//  Milestone T2 of docs/PORTING_TANG.md: get the console's raster onto a
//  display with no front-end at all. Everything the core needs beyond video
//  is stubbed here:
//
//    - cartridge   : the built-in boot cart in BRAM, exactly as the MiSTer
//                    wrapper serves it before an OSD load (GameTank.sv)
//    - DDR3        : tang/ddr_bram.sv, a 64 KB on-chip stand-in (T3 replaces
//                    it with the Gowin DDR3 controller)
//    - SD / saves  : tied off; no image is ever mounted
//    - gamepads    : tied off (T5)
//    - audio       : not routed off-chip yet (T5)
//
//  Video path: rtl/gtvideo.sv raster -> tang/linedouble.sv -> tang/dvi_tx.sv
//  -> DVI TX port 0 on the dock. See docs/PORTING_TANG.md §T2.
//============================================================================

module gametank_tang
(
    input  logic       clk,          // 50 MHz, dock pin P16
    input  logic       rst_n,        // board button, active low

    output logic [4:0] led,          // active low

    output logic       tmds_clk_p,
    output logic       tmds_clk_n,
    output logic [2:0] tmds_d_p,
    output logic [2:0] tmds_d_n
);

///////////////////////////   CLOCKS   ///////////////////////////////////////

wire clk_sys;       // 28.636364 MHz — 8x NTSC colorburst, the console clock
wire clk_serial;    // 143.181818 MHz — 5x, for the TMDS serializers
wire pll_lock;

pll_tang pll
(
    .clkin      (clk),
    .clk_sys    (clk_sys),
    .clk_serial (clk_serial),
    .lock       (pll_lock)
);

// Hold the console in reset until the PLL is locked and settled.
logic [15:0] rst_cnt = '0;
always_ff @(posedge clk_sys) begin
    if (!pll_lock || !rst_n) rst_cnt <= '0;
    else if (!rst_cnt[15])   rst_cnt <= rst_cnt + 1'd1;
end
wire reset = ~rst_cnt[15];

///////////////////////////   BOOT CART   ////////////////////////////////////

// Same image the MiSTer build boots (rtl/bootcart.mem); the core serves the
// $8000-$FFFF window from here until a .gtr download completes, which at T2
// never happens.
logic [7:0] bootcart [0:32767];
initial $readmemh("rtl/bootcart.mem", bootcart);

wire [14:0] cart_addr;
logic [7:0] cart_data;
always_ff @(posedge clk_sys) cart_data <= bootcart[cart_addr];

///////////////////////////   MEMORY STUB   //////////////////////////////////

wire        ddr_rd, ddr_we;
wire [28:0] ddr_addr;
wire [63:0] ddr_din;
wire [7:0]  ddr_be, ddr_burstcnt;
wire [63:0] ddr_dout;
wire        ddr_dout_ready, ddr_busy;

ddr_bram ddr
(
    .clk        (clk_sys),
    .reset      (reset),
    .rd         (ddr_rd),
    .we         (ddr_we),
    .addr       (ddr_addr),
    .din        (ddr_din),
    .be         (ddr_be),
    .burstcnt   (ddr_burstcnt),
    .dout       (ddr_dout),
    .dout_ready (ddr_dout_ready),
    .busy       (ddr_busy)
);

///////////////////////////   CONSOLE   //////////////////////////////////////

wire       ce_pix, hblank, hsync, vblank, vsync;
wire [7:0] video_r, video_g, video_b;
wire [15:0] audio_l, audio_r;
wire       dl_busy, dl_wait;
wire [31:0] sd_lba;
wire       sd_rd, sd_wr;
wire [7:0] sd_buff_din;

gametank gametank
(
    .clk_sys (clk_sys),
    .reset   (reset),

    .cart_addr (cart_addr),
    .cart_data (cart_data),

    // no download path at T2
    .dl_active (1'b0),
    .dl_wr     (1'b0),
    .dl_addr   (21'd0),
    .dl_data   (8'd0),
    .dl_busy   (dl_busy),
    .dl_wait   (dl_wait),

    // no save path at T2
    .sd_lba       (sd_lba),
    .sd_rd        (sd_rd),
    .sd_wr        (sd_wr),
    .sd_ack       (1'b0),
    .sd_buff_addr (9'd0),
    .sd_buff_dout (8'd0),
    .sd_buff_din  (sd_buff_din),
    .sd_buff_wr   (1'b0),
    .img_mounted  (1'b0),
    .img_readonly (1'b0),
    .img_size     (64'd0),
    .bk_load      (1'b0),
    .bk_save      (1'b0),
    .autosave     (1'b0),
    .osd_open     (1'b0),

    .ddr_rd         (ddr_rd),
    .ddr_we         (ddr_we),
    .ddr_addr       (ddr_addr),
    .ddr_din        (ddr_din),
    .ddr_be         (ddr_be),
    .ddr_burstcnt   (ddr_burstcnt),
    .ddr_dout       (ddr_dout),
    .ddr_dout_ready (ddr_dout_ready),
    .ddr_busy       (ddr_busy),

    .joy1 (8'd0),
    .joy2 (8'd0),

    .ce_pix  (ce_pix),
    .hblank  (hblank),
    .hsync   (hsync),
    .vblank  (vblank),
    .vsync   (vsync),
    .video_r (video_r),
    .video_g (video_g),
    .video_b (video_b),

    .audio_l (audio_l),
    .audio_r (audio_r)
);

///////////////////////////   VIDEO OUT   ////////////////////////////////////

wire       de_out, hsync_out, vsync_out;
wire [7:0] r_out, g_out, b_out;

linedouble linedouble
(
    .clk       (clk_sys),
    .reset     (reset),
    .ce_pix    (ce_pix),
    .hsync_in  (hsync),
    .hblank_in (hblank),
    .vsync_in  (vsync),
    .vblank_in (vblank),
    .r_in      (video_r),
    .g_in      (video_g),
    .b_in      (video_b),
    .hsync_out (hsync_out),
    .vsync_out (vsync_out),
    .de_out    (de_out),
    .r_out     (r_out),
    .g_out     (g_out),
    .b_out     (b_out)
);

dvi_tx dvi
(
    .clk_pix    (clk_sys),
    .clk_serial (clk_serial),
    .reset      (reset),
    .de         (de_out),
    .hsync      (hsync_out),
    .vsync      (vsync_out),
    .r          (r_out),
    .g          (g_out),
    .b          (b_out),
    .tmds_clk_p (tmds_clk_p),
    .tmds_clk_n (tmds_clk_n),
    .tmds_d_p   (tmds_d_p),
    .tmds_d_n   (tmds_d_n)
);

///////////////////////////   LEDS   /////////////////////////////////////////

// [0] PLL locked, [1] out of reset, [2] frame heartbeat, [3] audio activity,
// [4] blink so a dead clock is obvious at a glance.
logic [24:0] blink;
always_ff @(posedge clk_sys) blink <= blink + 1'd1;

logic vsync_d;
logic [5:0] frame_cnt;
always_ff @(posedge clk_sys) begin
    vsync_d <= vsync;
    if (vsync & ~vsync_d) frame_cnt <= frame_cnt + 1'd1;
end

assign led = ~{blink[24], |audio_l, frame_cnt[5], ~reset, pll_lock};

endmodule
