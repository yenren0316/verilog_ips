`timescale 1ns/1ps

module bfp_encoder_tb;

    // ── 參數（與 DUT 一致）──────────────────────────────────────────────────
    parameter BLOCK_SIZE    = 32;
    parameter DATA_WIDTH    = 16;
    parameter MANTISSA_BITS = 4;
    parameter EXP_BITS      = 5;
    parameter CLK_HALF      = 5;   // 10ns period = 100 MHz

    // ── DUT 訊號 ─────────────────────────────────────────────────────────────
    reg                      clk;
    reg                      rst_n;
    reg                      din_valid;
    reg  [DATA_WIDTH-1:0]    din;
    wire                     din_ready;
    wire                     dout_valid;
    wire [MANTISSA_BITS-1:0] dout_mantissa;
    wire [EXP_BITS-1:0]      dout_exp;
    wire                     dout_last;

    // ── DUT 例化 ─────────────────────────────────────────────────────────────
    bfp_encoder #(
        .BLOCK_SIZE   (BLOCK_SIZE),
        .DATA_WIDTH   (DATA_WIDTH),
        .MANTISSA_BITS(MANTISSA_BITS),
        .EXP_BITS     (EXP_BITS)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .din_valid    (din_valid),
        .din          (din),
        .din_ready    (din_ready),
        .dout_valid   (dout_valid),
        .dout_mantissa(dout_mantissa),
        .dout_exp     (dout_exp),
        .dout_last    (dout_last)
    );

    // ── 時鐘 ─────────────────────────────────────────────────────────────────
    initial clk = 0;
    always #CLK_HALF clk = ~clk;

    // ── 測試向量檔案 ──────────────────────────────────────────────────────────
    integer in_fd, exp_fd;
    integer r;
    integer in_sample;

    // 期望值暫存（每個 block）
    integer exp_e;
    integer exp_m [0:BLOCK_SIZE-1];

    // 計數
    integer pass_cnt, fail_cnt;
    integer blk_idx;

    // 輸出收集（每個 block 收集 BLOCK_SIZE 筆）
    reg signed [MANTISSA_BITS-1:0] got_m   [0:BLOCK_SIZE-1];
    reg        [EXP_BITS-1:0]      got_e;
    integer                         out_cnt;   // 本 block 已收集的 mantissa 數

    // ── 主測試流程 ────────────────────────────────────────────────────────────
    integer k;

    initial begin
        pass_cnt  = 0;
        fail_cnt  = 0;
        blk_idx   = 0;
        out_cnt   = 0;
        got_e     = 0;
        din_valid = 0;
        din       = 0;

        // 開啟輸入向量
        in_fd = $fopen("pattern/input.txt", "r");
        if (in_fd == 0) begin
            $display("ERROR: cannot open pattern/input.txt");
            $finish;
        end

        // 開啟期望輸出
        exp_fd = $fopen("pattern/expected.txt", "r");
        if (exp_fd == 0) begin
            $display("ERROR: cannot open pattern/expected.txt");
            $finish;
        end

        // Reset
        rst_n = 0;
        repeat(4) @(posedge clk);
        @(negedge clk); rst_n = 1;

        // 持續送樣本
        din_valid = 1;
        while (!$feof(in_fd)) begin
            r = $fscanf(in_fd, "%d\n", in_sample);
            if (r != 1) disable send_done;
            din = in_sample[DATA_WIDTH-1:0];
            @(negedge clk);
        end

        begin : send_done
            // 再多送幾個 dummy cycle 讓最後一個 block 完全輸出
            din = 0;
            repeat(BLOCK_SIZE * 3) @(negedge clk);
        end

        din_valid = 0;
        $fclose(in_fd);
        $fclose(exp_fd);

        $display("----------------------------------------------");
        $display("PASS: %0d  FAIL: %0d  (blocks checked: %0d)",
                 pass_cnt, fail_cnt, blk_idx);
        $finish;
    end

    // ── 輸出收集與比對（always block，和輸入並行）─────────────────────────────
    always @(posedge clk) begin
        if (dout_valid) begin
            // 收集輸出
            if (out_cnt == 0)
                got_e = dout_exp;   // 第一筆時記錄 exponent

            got_m[out_cnt] = $signed(dout_mantissa);
            out_cnt        = out_cnt + 1;

            // 每收集滿一個 block 就比對
            if (out_cnt == BLOCK_SIZE || dout_last) begin
                out_cnt = 0;

                // 讀取這個 block 的期望值
                r = $fscanf(exp_fd, "%d", exp_e);
                for (k = 0; k < BLOCK_SIZE; k = k + 1)
                    r = $fscanf(exp_fd, " %d", exp_m[k]);

                // 比對 exponent
                if (got_e !== exp_e[EXP_BITS-1:0]) begin
                    $display("FAIL block %0d: exp got=%0d expected=%0d",
                             blk_idx, got_e, exp_e);
                    fail_cnt = fail_cnt + 1;
                end else begin
                    // 比對所有 mantissa
                    begin : check_m
                        integer fail_m;
                        fail_m = 0;
                        for (k = 0; k < BLOCK_SIZE; k = k + 1) begin
                            if (got_m[k] !== $signed(exp_m[k][MANTISSA_BITS-1:0])) begin
                                if (!fail_m)
                                    $display("FAIL block %0d: mantissa[%0d] got=%0d expected=%0d",
                                             blk_idx, k, got_m[k], exp_m[k]);
                                fail_m = 1;
                            end
                        end
                        if (!fail_m) begin
                            $display("PASS block %0d: exp=%0d", blk_idx, got_e);
                            pass_cnt = pass_cnt + 1;
                        end else begin
                            fail_cnt = fail_cnt + 1;
                        end
                    end
                end

                blk_idx = blk_idx + 1;
            end
        end
    end

endmodule
