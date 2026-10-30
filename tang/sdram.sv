//============================================================================
//  16-bit SDRAM controller for the Tang port (T3).
//
//  Drops in behind rtl/ddr_mux.sv in place of the DDR3 bridge: it speaks the
//  same MiSTer DDRAM protocol the three clients already assume — hold rd/we
//  until !busy (that cycle is the acceptance), then a read returns `burstcnt`
//  64-bit beats each flagged by dout_ready. Nothing in rtl/ changes.
//
//  Target: Sipeed TANG_SDRAM module (40-pin header), 16-bit, 143 MHz rated.
//  Organisation assumed is a 256 Mbit x16 part: 4 banks x 8192 rows x 512
//  columns = 32 MB. We use 2.5 MB of it (512 KB GRAM + 2 MB cart image).
//
//  ---- why this shape -------------------------------------------------------
//
//  A 6502 bus cycle is 279 ns. This controller answers a read in roughly
//  100-200 ns, so a cart-cache miss or a GRAM row fetch can be served inside
//  one CPU cycle — the whole point of choosing SDRAM over the board's DDR3
//  (docs/PORTING_TANG.md §T3). Bandwidth is a non-issue: the console needs
//  under 10 MB/s and this sustains over 100.
//
//  Clocking: one PLL, clk_sdram = 3 x clk_bus, phase-related by construction.
//  The handshake between the two domains is therefore *synchronous
//  multi-rate*, not a CDC — the .sdc declares both as generated clocks off the
//  same master so STA times the transfers (~11.6 ns), and no synchronizer
//  flops are needed. Do not put these two clocks in different
//  set_clock_groups: that would silently un-time these paths.
//
//  Row policy: the open row is kept across transactions and closed only for a
//  refresh or a row change, so repeated access to one row (the blitter
//  streaming a GRAM row, the CPU walking a cart page) costs CL + burst and
//  nothing more. Beats of a burst are consecutive columns, and a beat landing
//  on a different row simply re-activates — which is also how a burst that
//  crosses a row boundary is handled, with no special case.
//
//  Writes are single-beat. That is not a limitation: the DDRAM protocol hands
//  the client's one `din` per command, and all three clients (GRAM
//  CPU-window writes, cart download, flash program) issue burstcnt = 1.
//
//  Deliberate slack: successive READs in one burst go out every 6 clocks
//  rather than the 4 that BL4 would allow, because each beat re-enters the
//  row check. That costs sustained bandwidth we do not need (114 MB/s instead
//  of 172) and keeps the state machine one shape instead of two.
//============================================================================

module sdram #(
    // clk_sdram in kHz — also the cycles per millisecond, which is what the
    // refresh and power-up timers are derived from.
    parameter int CLK_KHZ = 85937,
    // Byte 0x3000_0000 as a 64-bit word address: the base rtl/gram_ddr.sv and
    // rtl/cart.sv place their images above (MiSTer DDR3 map, kept as-is).
    parameter logic [28:0] BASE_WORD = 29'h0600_0000,
    // Extra clocks between the CAS latency and the cycle we sample dq_in.
    //
    // 0 is the value the protocol calls for with no flight time, and it is
    // what sim/unit/test_sdram.cpp verifies against the chip model: a READ
    // driven out of edge N is sampled by the chip at N+1, its four words are
    // latchable at N+3..N+6, and RD_PIPE = CL puts our capture window exactly
    // there. On hardware the round trip out to the module and back may push
    // the data past the setup window at N+3, in which case this becomes 1 —
    // that, and the ODDR clock polarity in tang/sdram_io.sv, are the two
    // knobs for read alignment during bring-up.
    parameter int RD_EXTRA = 0
)(
    input  logic        clk_bus,      // clk_sys, 28.646 MHz — client domain
    input  logic        clk_sdram,    // 3 x clk_bus, 85.94 MHz
    input  logic        reset,        // clk_bus domain, held over power-up

    // ---- client port (clk_bus), rtl/ddr_mux.sv protocol -------------------
    input  logic        rd,
    input  logic        we,
    input  logic [28:0] addr,         // 64-bit word address
    input  logic [63:0] din,
    input  logic [7:0]  be,
    input  logic [7:0]  burstcnt,
    output logic [63:0] dout,
    output logic        dout_ready,
    output logic        busy,

    output logic        init_done,    // release the console reset on this

    // ---- SDRAM pins (clk_sdram) -------------------------------------------
    output logic        sd_cke,
    output logic        sd_cs_n,
    output logic        sd_ras_n,
    output logic        sd_cas_n,
    output logic        sd_we_n,
    output logic [1:0]  sd_ba,
    output logic [12:0] sd_a,
    output logic [1:0]  sd_dqm,
    input  logic [15:0] dq_in,
    output logic [15:0] dq_out,
    output logic        dq_oe
);

// ---------------------------------------------------------------------------
// Timing in clk_sdram cycles at 85.94 MHz (11.64 ns/cycle). Values are the -6
// speed grade numbers common to W9825G6KH-class parts, rounded up.
// ---------------------------------------------------------------------------
localparam int         CL      = 2;        // CAS latency; MODE_REG must agree
localparam logic [4:0] W_RCD   = 5'd2;     // 18 ns  ACTIVE -> READ/WRITE
localparam logic [4:0] W_RP    = 5'd2;     // 18 ns  PRECHARGE -> ACTIVE
localparam logic [4:0] W_RFC   = 5'd6;     // 60 ns  AUTO REFRESH cycle
localparam logic [4:0] W_WR    = 5'd2;     // 12 ns  write recovery
localparam logic [4:0] W_MRD   = 5'd2;     // LOAD MODE REGISTER -> command
localparam int         BL      = 4;        // one 64-bit beat = 4 words
localparam int         RD_PIPE = CL + RD_EXTRA;

// Gap between the command for one beat and the row check for the next. Long
// enough that this beat's BL4 has left the data bus.
localparam logic [4:0] W_BEAT  = 5'd3;
// After the last READ: CAS latency plus the four data words.
localparam logic [4:0] W_RDEND = 5'(RD_PIPE + BL);

// CLK_KHZ is cycles per millisecond:
localparam logic [15:0] INIT_WAIT = 16'(CLK_KHZ / 5);     // 200 us
localparam logic [15:0] REF_INTVL = 16'(CLK_KHZ / 128);   // 7.8125 us

// Mode register: burst length 4 (A[2:0]=010), sequential (A[3]=0), CAS
// latency 2 (A[6:4]=010), write burst = read burst (A[9]=0).
localparam logic [12:0] MODE_REG = 13'h022;

// {cs_n, ras_n, cas_n, we_n}
localparam logic [3:0] CMD_NOP     = 4'b0111;
localparam logic [3:0] CMD_ACTIVE  = 4'b0011;
localparam logic [3:0] CMD_READ    = 4'b0101;
localparam logic [3:0] CMD_WRITE   = 4'b0100;
localparam logic [3:0] CMD_PRE     = 4'b0010;
localparam logic [3:0] CMD_REFRESH = 4'b0001;
localparam logic [3:0] CMD_MRS     = 4'b0000;

// ---------------------------------------------------------------------------
// Address mapping. A 64-bit beat is 4 SDRAM words, so the beat index shifts up
// by two to become a column; BL4 wraps inside its aligned 4-word block, which
// is exactly one beat.
//   col[8:0] = {beat[6:0], 2'b00}   row[12:0] = beat[19:7]   ba = beat[21:20]
// ---------------------------------------------------------------------------
localparam int BEAT_BITS = 22;             // 4M beats = 32 MB
localparam int MAX_BEATS = 8;


// ===========================================================================
// Bus side (clk_bus): accept one transaction, hand it to the engine, then play
// the collected beats out one per bus clock.
// ===========================================================================
logic [63:0] beatbuf [0:MAX_BEATS-1];   // written by the engine, read here
logic        req;                       // level, bus -> engine
logic        ack;                       // level, engine -> bus

logic [BEAT_BITS-1:0] req_beat;
logic [3:0]           req_beats;        // 1..8
logic [63:0]          req_din;
logic [7:0]           req_be;
logic                 req_we;

typedef enum logic [1:0] { BUS_IDLE, BUS_RUN, BUS_PLAY, BUS_DONE } bus_state_t;
bus_state_t bus_st;

logic [2:0] play_idx;

wire [28:0] local_word = addr - BASE_WORD;

// Only 32 MB is reachable and only 8 beats can be asked for; the rest of
// those inputs is deliberately dropped (same idiom as rtl/gametank.sv).
wire _unused = &{1'b0, local_word[28:BEAT_BITS], burstcnt[7:4], 1'b0};

always_ff @(posedge clk_bus) begin
    if (reset) begin
        bus_st     <= BUS_IDLE;
        req        <= 1'b0;
        dout_ready <= 1'b0;
        play_idx   <= '0;
    end
    else begin
        dout_ready <= 1'b0;

        case (bus_st)
        BUS_IDLE: begin
            if ((rd || we) && init_done) begin
                req_beat  <= local_word[BEAT_BITS-1:0];
                // A write is one beat (see header); a read takes the client's
                // count, clamped to the buffer.
                req_beats <= we                    ? 4'd1 :
                             (burstcnt == 8'd0)    ? 4'd1 :
                             (burstcnt > 8'd8)     ? 4'd8
                                                   : burstcnt[3:0];
                req_din   <= din;
                req_be    <= be;
                req_we    <= we;
                req       <= 1'b1;
                bus_st    <= BUS_RUN;
            end
        end

        BUS_RUN: begin
            if (ack) begin
                if (req_we) begin
                    req    <= 1'b0;
                    bus_st <= BUS_DONE;
                end
                else begin
                    play_idx <= '0;
                    bus_st   <= BUS_PLAY;
                end
            end
        end

        // Beats leave at one per bus clock. The protocol constrains their
        // order and count, not their spacing.
        BUS_PLAY: begin
            dout       <= beatbuf[play_idx];
            dout_ready <= 1'b1;
            if ({1'b0, play_idx} == req_beats - 4'd1) begin
                req    <= 1'b0;
                bus_st <= BUS_DONE;
            end
            else play_idx <= play_idx + 3'd1;
        end

        // Wait for the engine to see req drop, so one command can never be
        // taken for two.
        BUS_DONE: if (!ack) bus_st <= BUS_IDLE;
        endcase
    end
end

assign busy = (bus_st != BUS_IDLE) || !init_done;

// ===========================================================================
// SDRAM engine (clk_sdram)
// ===========================================================================
logic [3:0] cmd;
assign {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} = cmd;

logic [15:0] init_cnt;
logic [3:0]  init_refs;
logic [15:0] ref_cnt;
logic        ref_pending;

logic        row_open;
logic [12:0] open_row;
logic [1:0]  open_bank;

logic [BEAT_BITS-1:0] beat;
logic [3:0]           beats_left;
logic                 doing_write;

// The address mapping described above, off the beat being worked on.
wire [8:0]  beat_col  = {beat[6:0], 2'b00};
wire [12:0] beat_row  = beat[19:7];
wire [1:0]  beat_bank = beat[21:20];

logic [4:0] wait_cnt;
logic [1:0] wr_word;

// Read capture: a marker pushed in when a READ issues arrives CL + RD_EXTRA
// cycles later and enables four capture cycles.
logic [RD_PIPE-1:0] rd_mark;
logic [2:0]         cap_cnt;
logic [2:0]         cap_beat;
logic [1:0]         cap_word;

// A PRECHARGE while read data is still on the way would truncate the burst.
wire rd_inflight = (cap_cnt != 3'd0) || (rd_mark != '0);

typedef enum logic [3:0] {
    S_INIT_WAIT, S_INIT_REF, S_INIT_MRS, S_INIT_DONE,
    S_IDLE, S_PRE, S_ACT, S_RW, S_BURST, S_FINISH
} eng_state_t;
eng_state_t st;

logic req_q;
wire  req_seen = req_q && (st == S_IDLE) && !ack;

always_ff @(posedge clk_sdram) begin
    if (reset) begin
        st          <= S_INIT_WAIT;
        cmd         <= CMD_NOP;
        sd_cke      <= 1'b0;
        sd_dqm      <= 2'b11;
        dq_oe       <= 1'b0;
        init_cnt    <= INIT_WAIT;
        init_refs   <= '0;
        ref_cnt     <= '0;
        ref_pending <= 1'b0;
        row_open    <= 1'b0;
        ack         <= 1'b0;
        rd_mark     <= '0;
        cap_cnt     <= '0;
        cap_beat    <= '0;
        cap_word    <= '0;
        wait_cnt    <= '0;
        init_done   <= 1'b0;
        req_q       <= 1'b0;
    end
    else begin
        req_q  <= req;
        cmd    <= CMD_NOP;
        sd_cke <= 1'b1;
        dq_oe  <= 1'b0;
        sd_dqm <= 2'b00;

        // ---- refresh timer (free-running) --------------------------------
        if (ref_cnt == REF_INTVL) begin
            ref_cnt     <= '0;
            ref_pending <= 1'b1;
        end
        else ref_cnt <= ref_cnt + 16'd1;

        // ---- read capture pipeline ---------------------------------------
        rd_mark <= {rd_mark[RD_PIPE-2:0], 1'b0};
        if (rd_mark[RD_PIPE-1]) cap_cnt <= 3'd4;

        if (cap_cnt != 3'd0) begin
            beatbuf[cap_beat][cap_word*16 +: 16] <= dq_in;
            cap_cnt <= cap_cnt - 3'd1;
            if (cap_word == 2'd3) begin
                cap_word <= 2'd0;
                cap_beat <= cap_beat + 3'd1;
            end
            else cap_word <= cap_word + 2'd1;
        end

        if (wait_cnt != 5'd0) wait_cnt <= wait_cnt - 5'd1;

        case (st)
        // ---- power-up: 200 us of NOPs, PRECHARGE ALL, 8 refreshes, MRS ----
        S_INIT_WAIT: begin
            if (init_cnt == 16'd0) begin
                cmd      <= CMD_PRE;
                sd_a     <= 13'h400;              // A10 = 1: all banks
                wait_cnt <= W_RP;
                st       <= S_INIT_REF;
            end
            else init_cnt <= init_cnt - 16'd1;
        end

        S_INIT_REF: begin
            if (wait_cnt == 5'd0) begin
                if (init_refs == 4'd8) begin
                    cmd      <= CMD_MRS;
                    sd_ba    <= 2'b00;
                    sd_a     <= MODE_REG;
                    wait_cnt <= W_MRD;
                    st       <= S_INIT_MRS;
                end
                else begin
                    cmd       <= CMD_REFRESH;
                    init_refs <= init_refs + 4'd1;
                    wait_cnt  <= W_RFC;
                end
            end
        end

        S_INIT_MRS: if (wait_cnt == 5'd0) st <= S_INIT_DONE;

        S_INIT_DONE: begin
            init_done   <= 1'b1;
            ref_pending <= 1'b0;
            st          <= S_IDLE;
        end

        // ---- idle: refresh first, then work ------------------------------
        S_IDLE: begin
            ack <= 1'b0;
            if (wait_cnt == 5'd0) begin
                if (ref_pending) begin
                    if (row_open) begin
                        cmd      <= CMD_PRE;
                        sd_a     <= 13'h400;
                        row_open <= 1'b0;
                        wait_cnt <= W_RP;
                    end
                    else begin
                        cmd         <= CMD_REFRESH;
                        ref_pending <= 1'b0;
                        wait_cnt    <= W_RFC;
                    end
                end
                else if (req_seen) begin
                    beat        <= req_beat;
                    beats_left  <= req_beats;
                    doing_write <= req_we;
                    cap_beat    <= '0;
                    cap_word    <= '0;
                    st          <= S_PRE;
                end
            end
        end

        // ---- one beat: re-activate only on a row change -------------------
        // Covers the first beat and a burst crossing a row boundary alike.
        S_PRE: begin
            if (wait_cnt == 5'd0 && !rd_inflight) begin
                if (row_open && (open_row  != beat_row ||
                                 open_bank != beat_bank)) begin
                    cmd      <= CMD_PRE;
                    sd_a     <= 13'h400;
                    row_open <= 1'b0;
                    wait_cnt <= W_RP;
                end
                else st <= row_open ? S_RW : S_ACT;
            end
        end

        S_ACT: begin
            if (wait_cnt == 5'd0) begin
                cmd       <= CMD_ACTIVE;
                sd_ba     <= beat_bank;
                sd_a      <= beat_row;
                open_row  <= beat_row;
                open_bank <= beat_bank;
                row_open  <= 1'b1;
                wait_cnt  <= W_RCD;
                st        <= S_RW;
            end
        end

        S_RW: begin
            if (wait_cnt == 5'd0) begin
                sd_ba     <= beat_bank;
                sd_a      <= 13'd0;
                sd_a[8:0] <= beat_col;        // A10 = 0: keep the row open
                if (doing_write) begin
                    cmd     <= CMD_WRITE;
                    dq_oe   <= 1'b1;
                    dq_out  <= req_din[15:0];
                    sd_dqm  <= ~req_be[1:0];
                    wr_word <= 2'd1;
                end
                else begin
                    cmd        <= CMD_READ;
                    rd_mark[0] <= 1'b1;
                end
                st <= S_BURST;
            end
        end

        S_BURST: begin
            if (doing_write) begin
                dq_oe  <= 1'b1;
                dq_out <= req_din[wr_word*16 +: 16];
                sd_dqm <= ~req_be[wr_word*2 +: 2];
                if (wr_word == 2'd3) begin
                    wait_cnt <= W_WR;
                    st       <= S_FINISH;
                end
                else wr_word <= wr_word + 2'd1;
            end
            else if (wait_cnt == 5'd0) begin
                if (beats_left == 4'd1) begin
                    wait_cnt <= W_RDEND;
                    st       <= S_FINISH;
                end
                else begin
                    beats_left <= beats_left - 4'd1;
                    beat       <= beat + 1'd1;
                    wait_cnt   <= W_BEAT;
                    st         <= S_PRE;
                end
            end
        end

        // Data is in beatbuf (reads) or committed (writes): raise ack and hold
        // it until the bus side drops req. The row stays open.
        S_FINISH: begin
            if (wait_cnt == 5'd0) begin
                if (req_q) ack <= 1'b1;
                else begin
                    ack <= 1'b0;
                    st  <= S_IDLE;
                end
            end
        end

        // Unreachable encodings: start over rather than sit in a state with
        // no exit.
        default: st <= S_INIT_WAIT;
        endcase
    end
end

endmodule
