//============================================================================
//  GameTank framebuffer VRAM: two 128×128×8bpp pages in one 32 KB
//  true-dual-port BRAM (mirrors the 32K×8 dual-port SRAM on the real board).
//
//  Port A — CPU (and, from M4, blitter) side: page from banking[3]
//           (VRAM page select), byte address {y[6:0], x[6:0]}.
//  Port B — scanout side: page from DMA[1] (VID_OUT_PAGE), read-only.
//
//  Both ports are synchronous (one-clock read latency).
//============================================================================

module vram
(
    input  logic        clk,

    // Port A: CPU/blitter
    input  logic        a_page,
    input  logic [13:0] a_addr,     // {y, x}
    input  logic        a_we,
    input  logic [7:0]  a_din,
    output logic [7:0]  a_dout,

    // Port B: display-snapshot copy source
    input  logic        b_page,
    input  logic [13:0] b_addr,     // {y, x}
    output logic [7:0]  b_dout
);

logic [7:0] mem [0:32767] /*verilator public_flat_rd*/;

// Gowin's BSRAM has no read-before-write mode (PnR: PA2122), so the Tang
// build describes this port as write-through instead. The difference is
// only what the read output shows on a cycle that writes the same address,
// which no consumer here reads — the same argument rtl/acp.sv makes for its
// altsyncram NEW_DATA mapping. Kept behind `GOWIN` so the MiSTer build and
// the Verilator suite see bit-identical RTL until the suite can confirm the
// two forms are interchangeable (docs/PORTING_TANG.md §T2).
`ifdef GOWIN
always_ff @(posedge clk) begin
    if (a_we) begin
        mem[{a_page, a_addr}] <= a_din;
        a_dout <= a_din;
    end
    else a_dout <= mem[{a_page, a_addr}];
end
`else
always_ff @(posedge clk) begin
    if (a_we)
        mem[{a_page, a_addr}] <= a_din;
    a_dout <= mem[{a_page, a_addr}];
end
`endif

always_ff @(posedge clk) begin
    b_dout <= mem[{b_page, b_addr}];
end

endmodule
