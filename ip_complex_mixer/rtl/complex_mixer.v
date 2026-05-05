// complex_mixer.v
// Complex frequency mixer with NCO-optimized quarter-wave shared ROM.
//
// Architecture (3-stage pipeline):
//   Stage 1: phase_acc += freq_word
//   Stage 2: latch NCO sin/cos (nco_lut is combinational), latch I/Q input
//   Stage 3: complex multiply, truncate to DATA_W bits
//
// Output formula:
//   dout_i = din_i * cos - din_q * sin
//   dout_q = din_i * sin + din_q * cos
//
// Multiply: DATA_W(16) x AMP_W(12) = 28-bit signed; keep [27:12] → 16-bit.
// Latency: 3 cycles from din_valid to dout_valid.
//
// NCO ROM: commonlib/rom.v (async read, $readmemh initialized).
// Compile: iverilog ... complex_mixer.v nco_lut.v ../../commonlib/rom.v

`timescale 1ns/1ps

module complex_mixer #(
    parameter DATA_W   = 16,
    parameter AMP_W    = 12,
    parameter PHASE_W  = 16,
    parameter NCO_ROM  = "pattern/nco_rom.hex"
)(
    input  wire                   clk,
    input  wire                   rst_n,

    input  wire                   din_valid,
    input  wire signed [DATA_W-1:0]  din_i,
    input  wire signed [DATA_W-1:0]  din_q,
    input  wire [PHASE_W-1:0]     freq_word,

    output reg                    dout_valid,
    output reg  signed [DATA_W-1:0]  dout_i,
    output reg  signed [DATA_W-1:0]  dout_q
);
    // ── Stage 1: Phase Accumulator ───────────────────────────────────────────
    reg [PHASE_W-1:0] phase_acc;
    reg [PHASE_W-1:0] phase_r;    // registered phase fed into NCO LUT
    reg               valid1;
    reg signed [DATA_W-1:0] I1, Q1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_acc <= {PHASE_W{1'b0}};
            phase_r   <= {PHASE_W{1'b0}};
            valid1    <= 1'b0;
            I1        <= {DATA_W{1'b0}};
            Q1        <= {DATA_W{1'b0}};
        end else begin
            if (din_valid)
                phase_acc <= phase_acc + freq_word;
            phase_r <= phase_acc;   // snapshot before increment takes effect
            valid1  <= din_valid;
            I1      <= din_i;
            Q1      <= din_q;
        end
    end

    // ── NCO LUT (combinational, between Stage 1 and Stage 2) ─────────────────
    wire signed [AMP_W-1:0] nco_sin, nco_cos;

    nco_lut #(
        .PHASE_W   (PHASE_W),
        .AMP_W     (AMP_W),
        .INIT_FILE (NCO_ROM)
    ) u_nco (
        .phase   (phase_r),
        .sin_out (nco_sin),
        .cos_out (nco_cos)
    );

    // ── Stage 2: Latch NCO output and I/Q ────────────────────────────────────
    reg signed [AMP_W-1:0]  sin_r, cos_r;
    reg signed [DATA_W-1:0] I2, Q2;
    reg                     valid2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sin_r  <= {AMP_W{1'b0}};
            cos_r  <= {AMP_W{1'b0}};
            I2     <= {DATA_W{1'b0}};
            Q2     <= {DATA_W{1'b0}};
            valid2 <= 1'b0;
        end else begin
            sin_r  <= nco_sin;
            cos_r  <= nco_cos;
            I2     <= I1;
            Q2     <= Q1;
            valid2 <= valid1;
        end
    end

    // ── Stage 3: Complex Multiply ─────────────────────────────────────────────
    // Products: 16-bit x 12-bit = 28-bit signed
    // Truncate: keep bits [27:12] → 16-bit (divide by 2^12 = AMP full-scale)
    localparam PROD_W = DATA_W + AMP_W;  // 28

    wire signed [PROD_W-1:0] I_cos = I2 * cos_r;
    wire signed [PROD_W-1:0] Q_sin = Q2 * sin_r;
    wire signed [PROD_W-1:0] I_sin = I2 * sin_r;
    wire signed [PROD_W-1:0] Q_cos = Q2 * cos_r;

    wire signed [PROD_W:0] sum_i = I_cos - Q_sin;   // 29-bit to avoid overflow
    wire signed [PROD_W:0] sum_q = I_sin + Q_cos;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout_i     <= {DATA_W{1'b0}};
            dout_q     <= {DATA_W{1'b0}};
            dout_valid <= 1'b0;
        end else begin
            dout_i     <= sum_i[PROD_W-1 : AMP_W];   // [27:12]
            dout_q     <= sum_q[PROD_W-1 : AMP_W];
            dout_valid <= valid2;
        end
    end

endmodule
