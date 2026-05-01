`timescale 1ns/1ps

module template_tb;
    reg  [7:0] a, b;
    wire [8:0] sum;
    integer    fd, r;
    integer    exp_sum;
    integer    pass_cnt, fail_cnt;

    adder8 dut (.a(a), .b(b), .sum(sum));

    initial begin
        pass_cnt = 0;
        fail_cnt = 0;
        fd = $fopen("pattern/input.txt", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open ../pattern/input.txt");
            $finish;
        end

        while (!$feof(fd)) begin
            r = $fscanf(fd, "%d %d %d\n", a, b, exp_sum);
            if (r != 3) disable finish_block;
            #10;
            if (sum === exp_sum[8:0]) begin
                $display("PASS: a=%0d b=%0d sum=%0d", a, b, sum);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: a=%0d b=%0d sum=%0d (expected %0d)", a, b, sum, exp_sum);
                fail_cnt = fail_cnt + 1;
            end
        end

        begin : finish_block
            $fclose(fd);
            $display("-----------------------------");
            $display("PASS: %0d  FAIL: %0d", pass_cnt, fail_cnt);
            $finish;
        end
    end
endmodule
