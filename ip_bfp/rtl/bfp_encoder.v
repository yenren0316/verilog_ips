// bfp_encoder.v
// BFP Hardware Encoder：ping-pong buffer 架構，非阻塞，100% 吞吐量
//
// 演算法（對應 bfp_sim_optimal.py 的 uniform_bfp_hardware）：
//   e = ceil(log2(max_val / max_int))，scale = 2^e
//   mantissa = clip(round(sample / scale), -(2^(M-1)), 2^(M-1)-1)
//
// 架構：
//   INIT_FILL（前 BLOCK_SIZE 週期）：填 buf[0]，追蹤 abs_max，無輸出
//   STEADY：寫入 buf[wsel]、讀出 buf[~wsel]，同週期進行（cnt 共用）
//
// 使用 commonlib/fifomem.v（combinational read，synchronous write）
// fifomem 需在編譯時一起傳入：
//   iverilog ... rtl/bfp_encoder.v ../commonlib/fifomem.v

`timescale 1ns/1ps

module bfp_encoder #(
    parameter BLOCK_SIZE    = 32,   // samples per block（必須為 2 的次方）
    parameter DATA_WIDTH    = 16,   // 輸入樣本位元寬（有號）
    parameter MANTISSA_BITS = 4,    // 輸出 mantissa 位元數
    parameter EXP_BITS      = 5     // shared exponent 位元數
) (
    input  wire                      clk,
    input  wire                      rst_n,

    // 輸入 stream
    input  wire                      din_valid,
    input  wire [DATA_WIDTH-1:0]     din,
    output wire                      din_ready,    // 穩態恆為 1，INIT_FILL 期間亦為 1

    // 輸出 stream
    output reg                       dout_valid,
    output reg  [MANTISSA_BITS-1:0]  dout_mantissa,
    output reg  [EXP_BITS-1:0]       dout_exp,
    output reg                       dout_last     // block 最後一筆 pulse
);

    // ── 衍生參數 ────────────────────────────────────────────────────────────
    localparam ASIZE    = $clog2(BLOCK_SIZE);           // 位址位元數（5 for BLOCK_SIZE=32）
    localparam ABS_W    = DATA_WIDTH - 1;               // abs_sample 位元寬（15）
    localparam MAX_INT  = (1 << (MANTISSA_BITS-1)) - 1; // e.g. 4-bit → 7
    localparam MIN_INT  = -(1 << (MANTISSA_BITS-1));    // e.g. 4-bit → -8

    // ── 狀態 ────────────────────────────────────────────────────────────────
    localparam S_INIT   = 1'b0;
    localparam S_STEADY = 1'b1;

    reg state;

    // ── 計數與選擇器 ────────────────────────────────────────────────────────
    reg [ASIZE-1:0] cnt;    // 0..BLOCK_SIZE-1，fill/read 共用地址
    reg             wsel;   // 0=正在寫 ping，1=正在寫 pong

    // cnt==31 的一週期後才切換 wsel（fill 結束邊界）
    wire cnt_last = (cnt == BLOCK_SIZE - 1);

    // ── Absolute Value & Saturation（有號 → 無號，-32768 飽和至 32767）───────
    wire signed [DATA_WIDTH-1:0] din_s = din;
    // Saturate -32768 → +32767 before storing (matches Python golden model)
    wire signed [DATA_WIDTH-1:0] din_sat =
        (din_s == {1'b1, {(DATA_WIDTH-1){1'b0}}})   // -32768
            ? {{1'b0}, {(DATA_WIDTH-1){1'b1}}}        // → +32767
            : din_s;
    wire [ABS_W-1:0] abs_sample =
        (din_s == {1'b1, {(DATA_WIDTH-1){1'b0}}})  // -32768
            ? {(ABS_W){1'b1}}                        // → 32767（飽和）
            : din_s[DATA_WIDTH-1]
                ? (~din_s[ABS_W-1:0] + 1'b1)        // 負數取反加一
                :  din_s[ABS_W-1:0];                 // 正數直接取 bit

    // ── Ping-Pong Buffer（重用 fifomem）────────────────────────────────────
    wire [DATA_WIDTH-1:0] ping_rdata, pong_rdata;

    fifomem #(.DSIZE(DATA_WIDTH), .ASIZE(ASIZE)) u_ping (
        .rdata  (ping_rdata),
        .raddr  (cnt),
        .wdata  (din_sat),
        .waddr  (cnt),
        .wclken (din_valid & ~wsel),   // wsel=0：填 ping
        .wclk   (clk)
    );

    fifomem #(.DSIZE(DATA_WIDTH), .ASIZE(ASIZE)) u_pong (
        .rdata  (pong_rdata),
        .raddr  (cnt),
        .wdata  (din_sat),
        .waddr  (cnt),
        .wclken (din_valid & wsel),    // wsel=1：填 pong
        .wclk   (clk)
    );

    // 正在被讀取（處理）的 buffer：~wsel
    wire [DATA_WIDTH-1:0] proc_rdata = wsel ? ping_rdata : pong_rdata;

    // ── abs_max 追蹤（每 block 填入時更新）──────────────────────────────────
    reg [ABS_W-1:0] abs_max_reg [0:1];   // [0]=ping, [1]=pong

    // ── Shared Exponent Latch ────────────────────────────────────────────────
    reg [EXP_BITS-1:0] e_reg [0:1];      // [0]=ping 的 exponent, [1]=pong 的

    // ── LZD：15-bit priority encoder → leading zero count ───────────────────
    // lzc = 0 表示 bit14 為 1（最大值）
    function automatic [3:0] lzc15;
        input [ABS_W-1:0] x;   // 15-bit
        casez (x)
            15'b1??????????????: lzc15 = 4'd0;
            15'b01?????????????: lzc15 = 4'd1;
            15'b001????????????: lzc15 = 4'd2;
            15'b0001???????????: lzc15 = 4'd3;
            15'b00001??????????: lzc15 = 4'd4;
            15'b000001?????????: lzc15 = 4'd5;
            15'b0000001????????: lzc15 = 4'd6;
            15'b00000001???????: lzc15 = 4'd7;
            15'b000000001??????: lzc15 = 4'd8;
            15'b0000000001?????: lzc15 = 4'd9;
            15'b00000000001????: lzc15 = 4'd10;
            15'b000000000001???: lzc15 = 4'd11;
            15'b0000000000001??: lzc15 = 4'd12;
            15'b00000000000001?: lzc15 = 4'd13;
            15'b000000000000001: lzc15 = 4'd14;
            default:             lzc15 = 4'd15;  // x==0，e 輸出 0
        endcase
    endfunction

    // abs_max_cur: combinationally incorporate the current sample so that
    // the last sample of the block is included when latching e_new.
    wire [ABS_W-1:0]    abs_max_cur = (abs_sample > abs_max_reg[wsel])
                                        ? abs_sample : abs_max_reg[wsel];
    wire [3:0]          lzc_val  = lzc15(abs_max_cur);
    wire [3:0]          msb_pos  = 4'd14 - lzc_val;
    // Stage 1: e_base = max(0, msb_pos - (M-2)) — preliminary from MSB position
    wire [EXP_BITS-1:0] e_base   = (msb_pos <= (MANTISSA_BITS - 2))
                                     ? {EXP_BITS{1'b0}}
                                     : (msb_pos - (MANTISSA_BITS - 2));
    // Stage 2: check MAX_INT << e_base >= abs_max; if not, e = e_base + 1
    wire [31:0]         thresh32 = MAX_INT << e_base;
    wire [EXP_BITS-1:0] e_new    = (abs_max_cur == {ABS_W{1'b0}}) ? {EXP_BITS{1'b0}}
                                     : (thresh32[ABS_W-1:0] >= abs_max_cur)
                                       ? e_base : (e_base + 1'b1);

    // ── Barrel Shift + Round + Clip ──────────────────────────────────────────
    // 讀取的是 ~wsel 的 buffer，使用 e_reg[~wsel]
    wire [EXP_BITS-1:0]           e_cur    = e_reg[~wsel];
    wire signed [DATA_WIDTH-1:0]  sample_r = proc_rdata;

    // Round-to-nearest：加 half LSB（e_cur > 0 時）
    // 用 (DATA_WIDTH+1) bits 防溢位
    // Explicit sign-extension of sample_r to avoid unsigned context in ternary.
    wire signed [DATA_WIDTH:0] sample_ext = {{1{sample_r[DATA_WIDTH-1]}}, sample_r};
    wire signed [DATA_WIDTH:0] rounded =
        sample_ext + $signed({{1'b0}, ((e_cur > 0) ? ({{DATA_WIDTH{1'b0}}, 1'b1} << (e_cur - 1))
                                                   : {DATA_WIDTH{1'b0}})});

    // Arithmetic right shift
    wire signed [DATA_WIDTH:0] shifted = rounded >>> e_cur;

    // Clip to [MIN_INT, MAX_INT]
    wire [MANTISSA_BITS-1:0] mantissa_next =
        (shifted > $signed(MAX_INT)) ? MAX_INT[MANTISSA_BITS-1:0] :
        (shifted < $signed(MIN_INT)) ? MIN_INT[MANTISSA_BITS-1:0] :
                                       shifted[MANTISSA_BITS-1:0];

    // ── 狀態機 + 資料路徑（同步邏輯）────────────────────────────────────────
    assign din_ready = 1'b1;   // 此設計假設上游持續送資料

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_INIT;
            cnt      <= {ASIZE{1'b0}};
            wsel     <= 1'b0;
            for (i = 0; i < 2; i = i + 1) begin
                abs_max_reg[i] <= {ABS_W{1'b0}};
                e_reg[i]       <= {EXP_BITS{1'b0}};
            end
            dout_valid    <= 1'b0;
            dout_mantissa <= {MANTISSA_BITS{1'b0}};
            dout_exp      <= {EXP_BITS{1'b0}};
            dout_last     <= 1'b0;
        end else begin
            dout_last <= 1'b0;   // 預設不 pulse

            if (din_valid) begin
                // ── 更新 abs_max（填入端）─────────────────────────────────
                if (abs_sample > abs_max_reg[wsel])
                    abs_max_reg[wsel] <= abs_sample;

                // ── cnt 推進 ──────────────────────────────────────────────
                if (cnt_last) begin
                    cnt <= {ASIZE{1'b0}};

                    // ── Block 邊界：latch exponent，清零 abs_max，切換 wsel ─
                    e_reg[wsel]       <= e_new;
                    abs_max_reg[wsel] <= {ABS_W{1'b0}};   // 清零給下一個 block
                    wsel              <= ~wsel;

                    // INIT → STEADY 轉換
                    if (state == S_INIT)
                        state <= S_STEADY;

                    // dout_last 在下一週期（pipeline 補償）
                    if (state == S_STEADY)
                        dout_last <= 1'b1;
                end else begin
                    cnt <= cnt + 1'b1;
                end

                // ── 輸出（STEADY 時）──────────────────────────────────────
                if (state == S_STEADY) begin
                    dout_valid    <= 1'b1;
                    dout_mantissa <= mantissa_next;
                    dout_exp      <= e_reg[~wsel];
                end else begin
                    dout_valid <= 1'b0;
                end
            end else begin
                dout_valid <= 1'b0;
            end
        end
    end

endmodule
