//============================================================================
//  DVI transmitter: three TMDS-encoded data channels plus the clock channel,
//  serialized 10:1 and driven out as differential pairs.
//
//  clk_serial must be exactly 5x clk_pix, and clk_pix must be *derived* from
//  it by the CLKDIV in tang/pll_tang.v — OSER10 needs the two in a defined
//  phase relationship, which two independent PLL outputs do not guarantee.
//
//  The output stage follows the arrangement proven on this board by
//  Pedrocasf/486tang (src/ddr3_framebuffer.v), which matters in three ways
//  that each produce a dead link when got wrong:
//
//    - ELVDS_OBUF, not TLVDS_OBUF. These carriers run the HDMI bank at 3.3 V
//      and drive TMDS as emulated LVDS through the board's resistor network.
//    - the constraints must say IO_TYPE=LVCMOS33D explicitly. Left to itself
//      the fitter picks LVDS25 for TLVDS or LVDS25E for ELVDS — both 2.5 V
//      standards, on a 3.3 V bank.
//    - the clock lane is driven straight from the pixel clock, not
//      serialized. A 1111100000 pattern through a fourth OSER10 makes the
//      same waveform on paper, and is not what the working design does.
//
//  Encoding is pure RTL in tang/tmds_encoder.sv, verified symbol by symbol in
//  sim/unit/test_tmds_encoder.cpp. This module is the only place in the Tang
//  video path that touches device primitives, so it is the one file that
//  cannot be simulated — the same boundary the MiSTer build draws around
//  sys/. Under Verilator the primitives collapse to a behavioural stub that
//  keeps the module elaboratable.
//
//  Audio is not carried: this is DVI signalling (video islands only), which
//  every HDMI display accepts. HDMI audio packets are a T5 concern.
//============================================================================

module dvi_tx
(
    input  logic        clk_pix,      // 28.645833 MHz
    input  logic        clk_serial,   // 143.229167 MHz
    input  logic        reset,

    input  logic        de,
    input  logic        hsync,
    input  logic        vsync,
    input  logic [7:0]  r,
    input  logic [7:0]  g,
    input  logic [7:0]  b,

    output logic        tmds_clk_p,
    output logic        tmds_clk_n,
    output logic [2:0]  tmds_d_p,
    output logic [2:0]  tmds_d_n
);

wire [9:0] ch0, ch1, ch2;

// Channel 0 (blue) carries the sync bits during blanking; 1 and 2 idle to
// control token 0.
tmds_encoder enc_b (.clk(clk_pix), .din(b), .ctrl({vsync, hsync}), .de(de), .dout(ch0));
tmds_encoder enc_g (.clk(clk_pix), .din(g), .ctrl(2'b00),          .de(de), .dout(ch1));
tmds_encoder enc_r (.clk(clk_pix), .din(r), .ctrl(2'b00),          .de(de), .dout(ch2));

`ifdef VERILATOR

// Behavioural stub: keeps the module elaboratable in simulation. Serial
// output timing is not modelled — nothing downstream of the FPGA pins is.
assign tmds_clk_p = clk_pix;
assign tmds_clk_n = ~clk_pix;
assign tmds_d_p   = {ch2[0], ch1[0], ch0[0]};
assign tmds_d_n   = ~{ch2[0], ch1[0], ch0[0]};

`else

// Retime the reset before it reaches the serializers, and do it on the pixel
// clock rather than the serial one. Both matter:
//   - all three lanes take RESET from the same flop, so they leave reset
//     together and no lane's 10-bit boundary ends up shifted;
//   - on the serial clock there is only one serial period (2.3 ns at
//     1366x768 rates) for the release to reach three distributed OSER10s,
//     which does not close. On the pixel clock there are five.
// The release itself is asynchronous by nature, so the .sdc excludes these
// paths from analysis; what it cannot do is make three lanes agree, which is
// what the single source flop is for.
logic [1:0] rst_ser;
always_ff @(posedge clk_pix) rst_ser <= {rst_ser[0], reset};
wire ser_reset = rst_ser[1];

wire [2:0] ser_q;

// Lane 0 = blue/sync, lane 1 = green, lane 2 = red.
wire [9:0] lane [0:2];
assign lane[0] = ch0;
assign lane[1] = ch1;
assign lane[2] = ch2;

genvar i;
generate
    for (i = 0; i < 3; i = i + 1) begin : gen_ser
        OSER10 ser
        (
            .Q     (ser_q[i]),
            .D0    (lane[i][0]),
            .D1    (lane[i][1]),
            .D2    (lane[i][2]),
            .D3    (lane[i][3]),
            .D4    (lane[i][4]),
            .D5    (lane[i][5]),
            .D6    (lane[i][6]),
            .D7    (lane[i][7]),
            .D8    (lane[i][8]),
            .D9    (lane[i][9]),
            .PCLK  (clk_pix),
            .FCLK  (clk_serial),
            .RESET (ser_reset)
        );
    end
endgenerate

// Four pads in one arrayed instantiation: the clock lane takes the pixel
// clock directly, the three data lanes take their serializer outputs.
ELVDS_OBUF tmds_bufds [3:0]
(
    .I  ({clk_pix,    ser_q}),
    .O  ({tmds_clk_p, tmds_d_p}),
    .OB ({tmds_clk_n, tmds_d_n})
);

`endif

endmodule
