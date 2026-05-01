module fwft_async_fifo #(
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

    // Internal standard FIFO signals
    wire [DSIZE-1:0] std_rdata;
    wire             std_rempty;
    wire             std_rinc;

    // FWFT Output Register
    reg [DSIZE-1:0] dout_r;
    reg             valid_r;

    // Instantiate standard async FIFO
    async_fifo #(
        .DSIZE(DSIZE),
        .ASIZE(ASIZE)
    ) std_fifo_inst (
        .winc(winc),
        .wclk(wclk),
        .wrst_n(wrst_n),
        .rinc(std_rinc),
        .rclk(rclk),
        .rrst_n(rrst_n),
        .wdata(wdata),
        .rdata(std_rdata),
        .wfull(wfull),
        .rempty(std_rempty)
    );

    // FWFT Read Logic
    // We read from the standard FIFO whenever our output register is empty (invalid)
    // or when the user is reading the current valid word (rinc) and there's more data available.
    assign std_rinc = ~std_rempty && (~valid_r || rinc);

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            valid_r <= 1'b0;
            dout_r  <= {DSIZE{1'b0}};
        end else begin
            if (std_rinc) begin
                // A new word was popped from std_fifo, so it will be valid next cycle.
                valid_r <= 1'b1;
                dout_r  <= std_rdata;
            end else if (rinc) begin
                // User read the current word, but no new word was fetched
                valid_r <= 1'b0;
            end
        end
    end

    // The FWFT FIFO is empty if our output register has no valid data
    assign rempty = ~valid_r;
    assign rdata  = dout_r;

endmodule
