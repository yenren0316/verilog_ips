module rom #(
    parameter DSIZE     = 8,
    parameter ASIZE     = 4,
    parameter INIT_FILE = ""
)(
    output wire [DSIZE-1:0] rdata,
    input  wire [ASIZE-1:0] raddr
);
    localparam DEPTH = 1 << ASIZE;
    reg [DSIZE-1:0] mem [0:DEPTH-1];

    initial begin
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    assign rdata = mem[raddr];
endmodule
