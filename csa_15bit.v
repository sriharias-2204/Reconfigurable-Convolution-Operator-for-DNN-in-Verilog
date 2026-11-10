module csa_15bit (
    input  [14:0] op1,
    input  [14:0] op2,
    input  [14:0] op3,
    output [14:0] sum_row,
    output [14:0] carry_row
);
    genvar i;
    generate
        for (i = 0; i < 15; i = i + 1) begin : fa_gen
            full_adder fa_inst (.a(op1[i]), .b(op2[i]), .cin(op3[i]), .sum(sum_row[i]), .cout(carry_row[i]));
        end
    endgenerate
endmodule

module full_adder (
    input a, b, cin,
    output sum, cout
);
    assign sum = a ^ b ^ cin;
    assign cout = (a & b) | (b & cin) | (a & cin);
endmodule
