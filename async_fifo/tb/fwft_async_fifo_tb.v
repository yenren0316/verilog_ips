`timescale 1ns/1ps

module fwft_async_fifo_tb;
    parameter DSIZE = 8;
    parameter ASIZE = 4;
    parameter NUM_TRANS = 200;

    reg             winc, wclk, wrst_n;
    reg             rinc, rclk, rrst_n;
    reg [DSIZE-1:0] wdata;
    wire [DSIZE-1:0] rdata;
    wire            wfull;
    wire            rempty;

    integer fd, r, w_idx, r_idx;
    reg [DSIZE-1:0] exp_data [0:NUM_TRANS-1];
    integer pass_cnt, fail_cnt;

    // Instantiate FWFT DUT
    fwft_async_fifo #(DSIZE, ASIZE) dut (
        .winc(winc), .wclk(wclk), .wrst_n(wrst_n),
        .rinc(rinc), .rclk(rclk), .rrst_n(rrst_n),
        .wdata(wdata), .rdata(rdata),
        .wfull(wfull), .rempty(rempty)
    );

    // Clock generation
    initial begin
        wclk = 0;
        forever #5 wclk = ~wclk; // 100MHz
    end

    initial begin
        rclk = 0;
        forever #6.5 rclk = ~rclk; // ~77MHz
    end

    // Test sequence
    initial begin
        // Read pattern
        fd = $fopen("pattern/input.txt", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open pattern/input.txt");
            $finish;
        end
        for (w_idx = 0; w_idx < NUM_TRANS; w_idx = w_idx + 1) begin
            r = $fscanf(fd, "%d\n", exp_data[w_idx]);
        end
        $fclose(fd);

        winc = 0;
        wdata = 0;
        rinc = 0;
        wrst_n = 0;
        rrst_n = 0;
        pass_cnt = 0;
        fail_cnt = 0;
        
        #20;
        wrst_n = 1;
        rrst_n = 1;
    end

    // Write process
    initial begin
        #25; // wait for reset
        for (w_idx = 0; w_idx < NUM_TRANS; w_idx = w_idx + 1) begin
            @(posedge wclk);
            while (wfull) @(posedge wclk); // wait if full
            
            winc <= 1;
            wdata <= exp_data[w_idx];
            @(posedge wclk);
            winc <= 0;
            // random delay
            if ($random % 3 == 0) begin
                repeat($random % 5) @(posedge wclk);
            end
        end
    end

    // Read process (FWFT Logic)
    initial begin
        #25; // wait for reset
        for (r_idx = 0; r_idx < NUM_TRANS; r_idx = r_idx + 1) begin
            @(posedge rclk);
            while (rempty) @(posedge rclk); // wait if empty
            
            // Because it's FWFT, the data is already valid on rdata before we assert rinc.
            if (rdata === exp_data[r_idx]) begin
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL at index %0d: expected %0d, got %0d", r_idx, exp_data[r_idx], rdata);
                fail_cnt = fail_cnt + 1;
            end

            rinc <= 1; // Acknowledge and pop the current data
            @(posedge rclk);
            rinc <= 0;
            
            // random delay
            if ($random % 3 == 0) begin
                repeat($random % 5) @(posedge rclk);
            end
        end

        $display("-----------------------------");
        $display("PASS: %0d  FAIL: %0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("FWFT HARDWARE BIT-TRUE MATCH: SUCCESS");
        else $display("FWFT HARDWARE BIT-TRUE MATCH: FAILED");
        $finish;
    end

    initial begin
        $dumpfile("sim/fwft_async_fifo.vcd");
        $dumpvars(0, fwft_async_fifo_tb);
    end

endmodule
