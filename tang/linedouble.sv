//============================================================================
//  Line doubler: the console's native 240p raster -> a 480p-class DVI mode.
//
//  rtl/gtvideo.sv emits 908 dots per line at ce_pix = clk_sys/2 (14.318 MHz)
//  and 262 lines per frame, 60.19 Hz. Each input line is 1816 clk_sys; two
//  output lines of 908 dots at the full 28.636 MHz clock occupy exactly the
//  same 1816 clk. So the doubled raster is 908 x 524 @ 60.19 Hz on a
//  28.636364 MHz pixel clock — near enough to 640x480 that displays lock to
//  it, and the console's real refresh rate is preserved rather than
//  resampled (docs/REQUIREMENTS.md R3).
//
//  Horizontal timing is not re-derived here: the input's own hsync/hblank
//  bits are stored per dot alongside the pixel and replayed on output. Since
//  the output line has the same dot count as the input line, replaying that
//  waveform at the doubled line rate reproduces correct h-timing by
//  construction, with no duplicated constants to drift from gtvideo.sv.
//  Vertical state (vsync/vblank) is sampled once per line and held across
//  both output lines, which stretches each in lines while preserving its
//  duration in time — exactly what doubling requires.
//
//  Buffer dot 0 is the input's hsync rising edge (gtvideo dot 32), so the
//  whole raster is shifted 32 dots against the input's own numbering; a
//  display locks to the replayed sync waveform, not to that numbering.
//  Scanout runs one input line behind: the line being written lives in the
//  other buffer bank.
//============================================================================

module linedouble
(
    input  logic        clk,          // clk_sys, 28.636364 MHz
    input  logic        reset,

    // native side (rtl/gtvideo.sv)
    input  logic        ce_pix,
    input  logic        hsync_in,
    input  logic        hblank_in,
    input  logic        vsync_in,
    input  logic        vblank_in,
    input  logic [7:0]  r_in,
    input  logic [7:0]  g_in,
    input  logic [7:0]  b_in,

    // doubled side (one pixel per clk)
    output logic        hsync_out,
    output logic        vsync_out,
    output logic        de_out,
    output logic [7:0]  r_out,
    output logic [7:0]  g_out,
    output logic [7:0]  b_out
);

localparam logic [9:0] DOTS = 10'd908;   // dots per line, both sides
localparam int W = 26;                   // {hsync, hblank, r, g, b}

logic [W-1:0] linebuf [0:2047] /*verilator public_flat_rd*/;

logic [9:0] in_x, out_x;
logic       bank;                    // bank currently being written
logic       hsync_d;
wire        anchor = hsync_in & ~hsync_d;   // start of an input line

// At the anchor the incoming dot already belongs to the next line, so the
// write is steered to the bank the flip is about to select.
wire        wr_bank = anchor ? ~bank : bank;
wire [9:0]  wr_x    = anchor ? 10'd0 : in_x;

// Vertical state, delayed one line to match the buffered pixels
logic v_cur_vs, v_cur_vb, v_out_vs, v_out_vb;

always_ff @(posedge clk) begin
    if (reset) begin
        hsync_d  <= 1'b0;
        in_x     <= '0;
        out_x    <= '0;
        bank     <= 1'b0;
        v_cur_vs <= 1'b0;
        v_cur_vb <= 1'b0;
        v_out_vs <= 1'b0;
        v_out_vb <= 1'b0;
    end
    else begin
        hsync_d <= hsync_in;

        // ---- input side: one dot per ce_pix ------------------------------
        if (ce_pix)
            linebuf[{wr_bank, wr_x}] <= {hsync_in, hblank_in, r_in, g_in, b_in};

        if (anchor)
            in_x <= ce_pix ? 10'd1 : 10'd0;
        else if (ce_pix)
            in_x <= (in_x == DOTS - 10'd1) ? '0 : in_x + 10'd1;

        // ---- output side: one dot per clk --------------------------------
        out_x <= (anchor || out_x == DOTS - 10'd1) ? '0 : out_x + 10'd1;

        // ---- line boundary ------------------------------------------------
        if (anchor) begin
            bank     <= ~bank;
            v_out_vs <= v_cur_vs;     // the line about to be replayed
            v_out_vb <= v_cur_vb;
            v_cur_vs <= vsync_in;
            v_cur_vb <= vblank_in;
        end
    end
end

// Read the bank not being written; one clock of latency, and hsync/hblank
// travel in the same word as the pixel so they cannot skew against it.
logic [W-1:0] q;
always_ff @(posedge clk) q <= linebuf[{~bank, out_x}];

assign hsync_out = q[25];
assign vsync_out = v_out_vs;
assign de_out    = ~(q[24] | v_out_vb);
assign r_out     = q[23:16];
assign g_out     = q[15:8];
assign b_out     = q[7:0];

endmodule
