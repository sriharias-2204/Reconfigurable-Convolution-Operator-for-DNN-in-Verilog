module dadda_mult_8x7 (
    input  wire [7:0] a, 
    input  wire [6:0] b,  
    output wire [14:0] p  
);
    wire [14:0] pp [0:6];
    genvar i;
    generate
        for (i = 0; i < 7; i = i + 1) begin : pp_gen
            assign pp[i] = (b[i] ? {7'b0, a} : 15'b0) << i;
        end
    endgenerate

    wire [14:0] s1, c1;
    
    csa_15bit st1_csa (.op1(pp[0]), .op2(pp[1]), .op3(pp[2]), .sum_row(s1), .carry_row(c1));

 wire [14:0] s2_1, c2_1; 
    wire [14:0] s2_2, c2_2;
    
    csa_15bit st2_csa1 (.op1(s1), .op2(c1 << 1), .op3(pp[3]), .sum_row(s2_1), .carry_row(c2_1));
        csa_15bit st2_csa2 (.op1(pp[4]), .op2(pp[5]), .op3(pp[6]), .sum_row(s2_2), .carry_row(c2_2));
    
    wire [14:0] s3, c3;
    
    csa_15bit st3_csa (.op1(s2_1), .op2(c2_1 << 1), .op3(s2_2), .sum_row(s3), .carry_row(c3));
    
    wire [14:0] s4, c4;
    
    csa_15bit st4_csa (.op1(s3), .op2(c3 << 1), .op3(c2_2 << 1), .sum_row(s4), .carry_row(c4));
    
    assign p = s4 + (c4 << 1);

endmodule

