//============================================================================
//  SDRAM pad layer: the bidirectional data bus and the forwarded clock.
//
//  Split out of tang/sdram.sv so the controller itself stays pure RTL and
//  simulatable — the same boundary tang/dvi_tx.sv draws around its
//  serializers.
//
//  The clock goes out through an ODDR (D0=1, D1=0) rather than a plain
//  assignment so it leaves via an IO flop, giving it the same launch point
//  and routing class as the command and data pins. Feeding the ODDR with the
//  inverted controller clock puts the module's sampling edge in the middle of
//  our output window — the usual half-period of setup margin, and the first
//  thing to revisit if reads come back garbled (the other knob being
//  sdram's RD_EXTRA).
//============================================================================

module sdram_io
(
    input  logic        clk_sdram,
    input  logic [15:0] dq_out,
    input  logic        dq_oe,
    output logic [15:0] dq_in,

    output logic        sdram_clk,
    inout  wire  [15:0] sdram_dq
);

assign sdram_dq = dq_oe ? dq_out : 16'bz;
assign dq_in    = sdram_dq;

`ifdef VERILATOR
assign sdram_clk = ~clk_sdram;
`else
ODDR clk_fwd
(
    .Q0  (sdram_clk),
    .Q1  (),
    .D0  (1'b1),
    .D1  (1'b0),
    .TX  (1'b0),
    .CLK (~clk_sdram)
);
`endif

endmodule
