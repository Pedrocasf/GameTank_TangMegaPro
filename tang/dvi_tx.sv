//============================================================================
//  DVI transmitter: three TMDS-encoded data channels plus the clock channel,
//  serialized 10:1 and driven out as differential pairs.
//
//  clk_serial must be exactly 5x clk_pix (OSER10 does 10 bits per pixel
//  clock on both edges of the fast clock — UG304 §4.3.5); tang/pll_tang.v
//  produces the pair from one PLL so they stay phase-related.
//
//  Encoding is pure RTL in tang/tmds_encoder.sv. This module is the only
//  place that touches device primitives (OSER10, TLVDS_OBUF), so it is the
//  one file in the Tang video path that cannot be simulated — the same
//  boundary the MiSTer build draws around sys/. Under Verilator the
//  primitives collapse to a behavioural stub that keeps the module
//  elaboratable.
//
//  Audio is not carried: this is DVI signalling (video islands only), which
//  every HDMI display accepts. HDMI audio packets are a T5 concern.
//============================================================================

module dvi_tx
(
    input  logic        clk_pix,      // 28.636364 MHz
    input  logic        clk_serial,   // 143.181818 MHz
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

// The clock channel is a fixed half-rate pattern through the same
// serializer, so it tracks the data lanes' path delay.
localparam logic [9:0] CLK_PATTERN = 10'b1111100000;

`ifdef VERILATOR

// Behavioural stub: keeps the module elaboratable in simulation. Serial
// output timing is not modelled — nothing downstream of the FPGA pins is.
assign tmds_clk_p = CLK_PATTERN[0];
assign tmds_clk_n = ~CLK_PATTERN[0];
assign tmds_d_p   = {ch2[0], ch1[0], ch0[0]};
assign tmds_d_n   = ~{ch2[0], ch1[0], ch0[0]};

`else

// The serializers' RESET pin is sampled in the clk_serial domain, but
// `reset` is generated against clk_sys — an unsynchronized crossing that
// PnR flags (and that could release the four lanes on different serial
// clocks, shifting one lane's bit phase). Retime it here.
logic [1:0] rst_ser;
always_ff @(posedge clk_serial) rst_ser <= {rst_ser[0], reset};
wire ser_reset = rst_ser[1];

wire [3:0] ser_q;   // [2:0] = data lanes, [3] = clock lane

// Lane 0 = blue/sync, lane 1 = green, lane 2 = red, lane 3 = clock.
wire [9:0] lane [0:3];
assign lane[0] = ch0;
assign lane[1] = ch1;
assign lane[2] = ch2;
assign lane[3] = CLK_PATTERN;

genvar i;
generate
    for (i = 0; i < 4; i = i + 1) begin : gen_ser
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

    for (i = 0; i < 3; i = i + 1) begin : gen_obuf
        TLVDS_OBUF obuf
        (
            .I  (ser_q[i]),
            .O  (tmds_d_p[i]),
            .OB (tmds_d_n[i])
        );
    end
endgenerate

TLVDS_OBUF obuf_clk
(
    .I  (ser_q[3]),
    .O  (tmds_clk_p),
    .OB (tmds_clk_n)
);

`endif

endmodule
