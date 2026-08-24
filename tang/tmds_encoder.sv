//============================================================================
//  TMDS 8b/10b encoder (DVI 1.0 §3.2.2).
//
//  Two stages: transition minimization (XOR/XNOR chain, bit 8 records which),
//  then DC balancing against a running disparity counter. During blanking the
//  four fixed control tokens carry {vsync, hsync} instead of pixel data.
//
//  Pure RTL — no device primitives, so it simulates under Verilator like the
//  rest of the core. The serializers that consume it live in dvi_tx.sv.
//============================================================================

module tmds_encoder
(
    input  logic       clk,
    input  logic [7:0] din,
    input  logic [1:0] ctrl,      // {c1, c0}; channel 0 carries {vsync, hsync}
    input  logic       de,
    output logic [9:0] dout
);

// ---- stage 1: transition minimization -------------------------------------
logic [3:0] n1d;
always_comb begin
    n1d = 4'd0;
    for (int i = 0; i < 8; i++) n1d = n1d + {3'd0, din[i]};
end

wire use_xnor = (n1d > 4'd4) || (n1d == 4'd4 && din[0] == 1'b0);

logic [8:0] qm;
always_comb begin
    qm[0] = din[0];
    for (int i = 1; i < 8; i++)
        qm[i] = use_xnor ? ~(qm[i-1] ^ din[i]) : (qm[i-1] ^ din[i]);
    qm[8] = ~use_xnor;
end

// ---- stage 2: DC balancing ------------------------------------------------
logic [3:0] n1q;
always_comb begin
    n1q = 4'd0;
    for (int i = 0; i < 8; i++) n1q = n1q + {3'd0, qm[i]};
end

// N1 - N0 over qm[7:0], i.e. 2*N1 - 8
wire signed [5:0] imbalance = $signed({2'd0, n1q}) - 6'sd4 +
                              $signed({2'd0, n1q}) - 6'sd4;

logic signed [5:0] cnt;

always_ff @(posedge clk) begin
    if (!de) begin
        cnt <= '0;
        case (ctrl)
            2'b00: dout <= 10'b1101010100;
            2'b01: dout <= 10'b0010101011;
            2'b10: dout <= 10'b0101010100;
            2'b11: dout <= 10'b1010101011;
        endcase
    end
    else if (cnt == 0 || n1q == 4'd4) begin
        dout <= {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
        cnt  <= qm[8] ? (cnt + imbalance) : (cnt - imbalance);
    end
    else if ((cnt > 0 && n1q > 4'd4) || (cnt < 0 && n1q < 4'd4)) begin
        dout <= {1'b1, qm[8], ~qm[7:0]};
        cnt  <= cnt + (qm[8] ? 6'sd2 : 6'sd0) - imbalance;
    end
    else begin
        dout <= {1'b0, qm[8], qm[7:0]};
        cnt  <= cnt - (qm[8] ? 6'sd0 : 6'sd2) + imbalance;
    end
end

endmodule
