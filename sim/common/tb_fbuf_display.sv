// Test-only wrapper: the real rtl/gtvideo.sv raster feeding
// tang/fbuf_display.sv, so the framebuffer's reconstruction of (x, y) is
// checked against the actual video generator rather than against a C++
// restatement of the same assumptions.
//
// The framebuffer gtvideo scans out is supplied by the harness through
// fb_data, so the test controls exactly which byte sits at which coordinate.
//
// Not part of any synthesized build.

module tb_fbuf_display
(
    input  logic        clk_sys,
    input  logic        reset,
    input  logic        clk_pix,
    input  logic        pix_reset,

    // framebuffer the console scans out (driven by the harness)
    output logic [13:0] fb_addr,
    input  logic [7:0]  fb_data,

    // display output
    output logic        hsync_out,
    output logic        vsync_out,
    output logic        de_out,
    output logic [7:0]  r_out,
    output logic [7:0]  g_out,
    output logic [7:0]  b_out,

    // console-side raster, exposed so the test can see what was sent
    output logic        ce_pix,
    output logic        hsync_native,
    output logic        vsync_native,
    output logic [7:0]  r_native,
    output logic [7:0]  g_native,
    output logic [7:0]  b_native
);

// gtvideo outputs this wrapper does not forward.
/* verilator lint_off UNUSEDSIGNAL */
logic hblank, vblank, vsync_nmi;
/* verilator lint_on UNUSEDSIGNAL */

gtvideo gtvideo
(
    .clk       (clk_sys),
    .reset     (reset),
    .fb_addr   (fb_addr),
    .fb_data   (fb_data),
    .ce_pix    (ce_pix),
    .hblank    (hblank),
    .hsync     (hsync_native),
    .vblank    (vblank),
    .vsync     (vsync_native),
    .r         (r_native),
    .g         (g_native),
    .b         (b_native),
    .vsync_nmi (vsync_nmi)
);

fbuf_display display
(
    .clk_sys   (clk_sys),
    .reset     (reset),
    .ce_pix    (ce_pix),
    .hsync_in  (hsync_native),
    .vsync_in  (vsync_native),
    .r_in      (r_native),
    .g_in      (g_native),
    .b_in      (b_native),

    .clk_pix   (clk_pix),
    .pix_reset (pix_reset),
    .hsync_out (hsync_out),
    .vsync_out (vsync_out),
    .de_out    (de_out),
    .r_out     (r_out),
    .g_out     (g_out),
    .b_out     (b_out)
);

endmodule
