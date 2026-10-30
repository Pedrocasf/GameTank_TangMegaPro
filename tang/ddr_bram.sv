//============================================================================
//  T2 scaffolding: a BRAM standing in for DDR3 behind the core's memory port.
//
//  rtl/ddr_mux.sv speaks the MiSTer DDRAM protocol — hold rd/we until !busy
//  (that cycle is the acceptance), then a read returns `burstcnt` 64-bit
//  beats each flagged by dout_ready. This module implements exactly that
//  against a small on-chip memory so the video path can be brought up on
//  hardware before the Gowin DDR3 controller exists (T3).
//
//  WORDS is deliberately tiny: 8192 x 64 bit = 64 KB, which is one GRAM bank
//  (docs/HARDWARE.md §Blitter — GRAM addresses are {bank[2:0], ...}), so all
//  eight banks alias onto the same storage. That is enough for a boot cart
//  that lives in bank 0, and nothing else runs at T2: the cartridge client is
//  idle until a .gtr download completes, and the save streamer is idle
//  without a mounted image. It is not enough for a real game — that is what
//  T3 replaces.
//============================================================================

module ddr_bram #(parameter int WORDS = 8192)
(
    input  logic        clk,
    input  logic        reset,

    input  logic        rd,
    input  logic        we,
    input  logic [28:0] addr,        // 64-bit word address
    input  logic [63:0] din,
    input  logic [7:0]  be,
    input  logic [7:0]  burstcnt,
    output logic [63:0] dout,
    output logic        dout_ready,
    output logic        busy
);

localparam int AW = $clog2(WORDS);

logic [AW-1:0] rd_ptr;
logic [7:0]    beats;
logic          streaming;

wire [AW-1:0] a_now  = addr[AW-1:0];
wire          accept = rd & ~streaming;
wire          wr_now = we & ~streaming;

// Address the memory a beat ahead: the accept cycle presents the first
// address, and rd_ptr is already pointing at the second by the time the
// first beat is delivered.
wire [AW-1:0] raddr = streaming ? rd_ptr : a_now;

// One byte-wide array per lane. Byte enables become per-array write enables,
// which infers cleanly instead of leaning on byte-write support.
logic [7:0] q [0:7];

genvar i;
generate
    for (i = 0; i < 8; i = i + 1) begin : lane
        logic [7:0] m [0:WORDS-1];
        always_ff @(posedge clk) begin
            if (wr_now && be[i]) m[a_now] <= din[i*8 +: 8];
            q[i] <= m[raddr];
        end
    end
endgenerate

assign dout = {q[7], q[6], q[5], q[4], q[3], q[2], q[1], q[0]};
assign busy = streaming;

always_ff @(posedge clk) begin
    if (reset) begin
        streaming  <= 1'b0;
        dout_ready <= 1'b0;
        beats      <= '0;
        rd_ptr     <= '0;
    end
    else begin
        dout_ready <= 1'b0;

        if (!streaming) begin
            if (accept) begin
                streaming <= 1'b1;
                beats     <= burstcnt;
                rd_ptr    <= a_now + 1'd1;
            end
        end
        else begin
            dout_ready <= 1'b1;          // data for the previous address
            if (beats == 8'd1)
                streaming <= 1'b0;
            else begin
                beats  <= beats - 8'd1;
                rd_ptr <= rd_ptr + 1'd1;
            end
        end
    end
end

endmodule
