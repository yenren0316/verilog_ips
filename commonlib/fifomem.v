module fifomem #(
    parameter DSIZE = 8, 
    parameter ASIZE = 4
)(
    output wire [DSIZE-1:0] rdata,
    input  wire [DSIZE-1:0] wdata,
    input  wire [ASIZE-1:0] waddr, raddr,
    input  wire             wclken, wclk
);
    localparam DEPTH = 1<<ASIZE;
    reg [DSIZE-1:0] mem [0:DEPTH-1];

    assign rdata = mem[raddr];

    always @(posedge wclk) begin
        if (wclken) begin
            mem[waddr] <= wdata;
        end
    end
endmodule
