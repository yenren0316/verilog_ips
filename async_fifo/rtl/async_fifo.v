module async_fifo #(
    parameter DSIZE = 8,
    parameter ASIZE = 4
)(
    input  wire             winc, wclk, wrst_n,
    input  wire             rinc, rclk, rrst_n,
    input  wire [DSIZE-1:0] wdata,
    output wire [DSIZE-1:0] rdata,
    output wire             wfull,
    output wire             rempty
);

    wire [ASIZE-1:0] waddr, raddr;
    wire [ASIZE:0]   wq2_rptr, rq2_wptr;
    wire [ASIZE:0]   wptr, rptr;

    // The synchronizers using common library sync_2ff
    sync_2ff #(ASIZE) sync_r2w_inst (
        .q2(wq2_rptr), 
        .d(rptr),
        .clk(wclk), 
        .rst_n(wrst_n)
    );

    sync_2ff #(ASIZE) sync_w2r_inst (
        .q2(rq2_wptr), 
        .d(wptr),
        .clk(rclk), 
        .rst_n(rrst_n)
    );

    // FIFO Memory using common library fifomem
    fifomem #(DSIZE, ASIZE) fifomem_inst (
        .rdata(rdata), 
        .wdata(wdata),
        .waddr(waddr), 
        .raddr(raddr),
        .wclken(winc & ~wfull), 
        .wclk(wclk)
    );

    // Read pointer & empty logic
    rptr_empty #(ASIZE) rptr_empty_inst (
        .rempty(rempty),
        .raddr(raddr),
        .rptr(rptr),
        .rq2_wptr(rq2_wptr),
        .rinc(rinc),
        .rclk(rclk),
        .rrst_n(rrst_n)
    );

    // Write pointer & full logic
    wptr_full #(ASIZE) wptr_full_inst (
        .wfull(wfull),
        .waddr(waddr),
        .wptr(wptr),
        .wq2_rptr(wq2_rptr),
        .winc(winc),
        .wclk(wclk),
        .wrst_n(wrst_n)
    );

endmodule

module rptr_empty #(parameter ASIZE = 4) (
    output reg             rempty,
    output wire [ASIZE-1:0] raddr,
    output reg  [ASIZE:0]   rptr,
    input  wire [ASIZE:0]   rq2_wptr,
    input  wire             rinc, rclk, rrst_n
);
    reg  [ASIZE:0] rbin;
    wire [ASIZE:0] rgraynext, rbinnext;
    wire           rempty_val;

    // Memory read-address pointer
    assign raddr = rbin[ASIZE-1:0];
    assign rbinnext = rbin + (rinc & ~rempty);
    assign rgraynext = (rbinnext >> 1) ^ rbinnext;

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin <= 0;
            rptr <= 0;
        end else begin
            rbin <= rbinnext;
            rptr <= rgraynext;
        end
    end

    assign rempty_val = (rgraynext == rq2_wptr);
    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) rempty <= 1'b1;
        else         rempty <= rempty_val;
    end
endmodule

module wptr_full #(parameter ASIZE = 4) (
    output reg             wfull,
    output wire [ASIZE-1:0] waddr,
    output reg  [ASIZE:0]   wptr,
    input  wire [ASIZE:0]   wq2_rptr,
    input  wire             winc, wclk, wrst_n
);
    reg  [ASIZE:0] wbin;
    wire [ASIZE:0] wgraynext, wbinnext;
    wire           wfull_val;

    // Memory write-address pointer
    assign waddr = wbin[ASIZE-1:0];
    assign wbinnext = wbin + (winc & ~wfull);
    assign wgraynext = (wbinnext >> 1) ^ wbinnext;

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin <= 0;
            wptr <= 0;
        end else begin
            wbin <= wbinnext;
            wptr <= wgraynext;
        end
    end

    // Full condition:
    // MSB mismatch, 2nd MSB mismatch, remaining bits match
    assign wfull_val = (wgraynext == {~wq2_rptr[ASIZE:ASIZE-1], wq2_rptr[ASIZE-2:0]});
    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) wfull <= 1'b0;
        else         wfull <= wfull_val;
    end
endmodule
