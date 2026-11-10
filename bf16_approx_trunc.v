`timescale 1ns / 1ps

module bf16_approx_trunc (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [15:0]  a,   
    input  wire [15:0]  b,   
    output reg  [15:0]  out
);

    wire sign_res = a[15] ^ b[15];
    // Use 9 bits to prevent overflow before bias subtraction
    wire signed [9:0] exp_sum = {2'b0, a[14:7]} + {2'b0, b[14:7]};
    wire signed [9:0] exp_biased = exp_sum - 10'sd127;

    wire [7:0] mant_a = {1'b1, a[6:0]};
    wire [6:0] mant_b = {1'b1, b[6:1]}; 
    wire [14:0] product_core;
    
    dadda_mult_8x7 u_dadda_core (
        .a(mant_a), .b(mant_b), .p(product_core)
    );

    reg [14:0] pipe_prod;
    reg signed [9:0] pipe_exp;
    reg pipe_sign;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            pipe_prod <= 0; pipe_exp <= 0; pipe_sign <= 0;
        end else begin
            pipe_prod <= product_core;
            pipe_exp  <= exp_biased;
            pipe_sign <= sign_res;
        end
    end

    wire [15:0] prod_ext = {pipe_prod, 1'b0};
    reg [7:0] final_exp;
    reg [6:0] final_mant;
    reg [15:0] next_out; // Intermediate combinational signal

    always @(*) begin
        if (prod_ext[15]) begin 
            final_exp  = pipe_exp[7:0] + 1'b1;
            final_mant = prod_ext[14:8];
        end else begin
            final_exp  = pipe_exp[7:0];
            final_mant = prod_ext[13:7];
        end

        if (pipe_exp < 0)        next_out = {pipe_sign, 8'h00, 7'b0}; // Underflow
        else if (pipe_exp > 255) next_out = {pipe_sign, 8'hFF, 7'b0}; // Overflow/Inf
        else                     next_out = {pipe_sign, final_exp, final_mant};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) out <= 16'd0;
        else out <= next_out;
    end
endmodule
