`timescale 1ns/1ps

module complex_mixer_tb;
    parameter DATA_W  = 16;
    parameter PHASE_W = 16;
    parameter LATENCY = 3;       // pipeline stages

    reg                      clk, rst_n;
    reg                      din_valid;
    reg  signed [DATA_W-1:0] din_i, din_q;
    reg  [PHASE_W-1:0]       freq_word;
    wire                     dout_valid;
    wire signed [DATA_W-1:0] dout_i, dout_q;

    complex_mixer #(
        .DATA_W  (DATA_W),
        .AMP_W   (12),
        .PHASE_W (PHASE_W),
        .NCO_ROM ("pattern/nco_rom.hex")
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .din_valid (din_valid),
        .din_i     (din_i),
        .din_q     (din_q),
        .freq_word (freq_word),
        .dout_valid(dout_valid),
        .dout_i    (dout_i),
        .dout_q    (dout_q)
    );

    always #5 clk = ~clk;

    integer fd_in, fd_exp;
    integer r_in, r_exp;
    integer exp_i, exp_q;
    integer pass_cnt, fail_cnt;
    integer in_i, in_q, fw;

    initial begin
        clk       = 0;
        rst_n     = 0;
        din_valid = 0;
        din_i     = 0;
        din_q     = 0;
        freq_word = 0;
        pass_cnt  = 0;
        fail_cnt  = 0;

        @(posedge clk); #1;
        @(posedge clk); #1;
        rst_n = 1;

        fd_in  = $fopen("pattern/input.txt",    "r");
        fd_exp = $fopen("pattern/expected.txt", "r");
        if (fd_in == 0 || fd_exp == 0) begin
            $display("ERROR: cannot open pattern files");
            $finish;
        end

        // Feed all inputs back-to-back
        while (!$feof(fd_in)) begin
            r_in = $fscanf(fd_in, "%d %d %d\n", in_i, in_q, fw);
            if (r_in != 3) disable input_loop;
            @(posedge clk); #1;
            din_valid = 1;
            din_i     = in_i[DATA_W-1:0];
            din_q     = in_q[DATA_W-1:0];
            freq_word = fw[PHASE_W-1:0];
        end

        begin : input_loop
            // Drain pipeline
            repeat (LATENCY + 1) begin
                @(posedge clk); #1;
                din_valid = 0;
            end
        end

        $fclose(fd_in);
        $fclose(fd_exp);
        $display("-----------------------------");
        $display("PASS: %0d  FAIL: %0d", pass_cnt, fail_cnt);
        $finish;
    end

    // Output checker: fires whenever dout_valid is asserted
    always @(posedge clk) begin
        if (dout_valid) begin
            r_exp = $fscanf(fd_exp, "%d %d\n", exp_i, exp_q);
            if (r_exp == 2) begin
                if (dout_i === exp_i[DATA_W-1:0] && dout_q === exp_q[DATA_W-1:0]) begin
                    $display("PASS: out_i=%0d out_q=%0d", dout_i, dout_q);
                    pass_cnt = pass_cnt + 1;
                end else begin
                    $display("FAIL: out_i=%0d (exp %0d)  out_q=%0d (exp %0d)",
                             dout_i, exp_i, dout_q, exp_q);
                    fail_cnt = fail_cnt + 1;
                end
            end
        end
    end

endmodule
