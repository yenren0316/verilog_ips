module sync_2ff #(parameter ASIZE = 4) (
    output reg [ASIZE:0] q2,
    input  wire [ASIZE:0] d,
    input  wire           clk, rst_n
);
    reg [ASIZE:0] q1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) {q2, q1} <= 0;
        else        {q2, q1} <= {q1, d};
    end
endmodule
