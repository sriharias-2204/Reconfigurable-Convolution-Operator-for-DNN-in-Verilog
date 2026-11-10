`timescale 1ns / 1ps

module add_bf16_pipelined (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ce,        
    input  wire [15:0] c,
    input  wire [15:0] mul,
    output reg  [15:0] fma
);

    reg        s1_valid, s1_op_sub, s1_sign;
    reg [7:0]  s1_exp;
    reg [8:0]  s1_sig_a, s1_sig_b; // 1-bit implied + 7-bit mant + 1-bit for shift

    wire c_is_bigger = (c[14:0] >= mul[14:0]);
    wire [7:0] exp_diff = c_is_bigger ? (c[14:7] - mul[14:7]) : (mul[14:7] - c[14:7]);
    
    wire [3:0] shift_amt = (exp_diff > 8) ? 4'd9 : exp_diff[3:0]; 

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 0; s1_exp <= 0; s1_sig_a <= 0; s1_sig_b <= 0; s1_op_sub <= 0; s1_sign <= 0;
        end else if (ce) begin
            s1_valid  <= |c[14:0] || |mul[14:0];
            s1_op_sub <= c[15] ^ mul[15];
            
            if (c_is_bigger) begin
                s1_exp   <= c[14:7];
                s1_sign  <= c[15];
                s1_sig_a <= {1'b1, c[6:0], 1'b0};
                s1_sig_b <= {1'b1, mul[6:0], 1'b0} >> shift_amt; 
            end else begin
                s1_exp   <= mul[14:7];
                s1_sign  <= mul[15];
                s1_sig_a <= {1'b1, mul[6:0], 1'b0};
                s1_sig_b <= {1'b1, c[6:0], 1'b0} >> shift_amt; 
            end
        end
    end

/*    // Stage 1: Alignment & Sort (Area Optimization)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 0; s1_exp <= 0; s1_sig_a <= 0; s1_sig_b <= 0;
        end else if (ce) begin
            s1_valid <= |c[14:0] || |mul[14:0];
            s1_op_sub <= c[15] ^ mul[15];
            
            if (c[14:0] >= mul[14:0]) begin
                s1_exp   <= c[14:7];
                s1_sign  <= c[15];
                s1_sig_a <= {1'b1, c[6:0], 1'b0};
                s1_sig_b <= {1'b1, mul[6:0], 1'b0} >> (c[14:7] - mul[14:7]);
            end else begin
                s1_exp   <= mul[14:7];
                s1_sign  <= mul[15];
                s1_sig_a <= {1'b1, mul[6:0], 1'b0};
                s1_sig_b <= {1'b1, c[6:0], 1'b0} >> (mul[14:7] - c[14:7]);
            end
        end
    end*/

// Stage 2: Math & Normalize (Gated by ce)
    reg [9:0] res_sig; // EXPANDED TO 10 BITS to catch the carry overflow

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fma <= 0;
        else if (ce) begin
            if (!s1_valid) fma <= 0;
            else begin
                // Addition can overflow to 10 bits. Subtraction will remain 9 bits or less.
                res_sig = s1_op_sub ? (s1_sig_a - s1_sig_b) : (s1_sig_a + s1_sig_b);
                
                casex (res_sig)
                    // OVERFLOW CASE: 1.x + 1.x = 10.x (Shift right by 1, Add 1 to Exponent)
                    10'b1xxxxxxxxx: fma <= {s1_sign, s1_exp + 8'd1, res_sig[8:2]};
                    
                    // NORMAL CASE: No overflow
                    10'b01xxxxxxxx: fma <= {s1_sign, s1_exp,        res_sig[7:1]};
                    
                    // SUBTRACTION CANCELLATION CASES: Shift left to find the leading 1
                    10'b001xxxxxxx: fma <= {s1_sign, s1_exp - 8'd1, res_sig[6:0]};
                    10'b0001xxxxxx: fma <= {s1_sign, s1_exp - 8'd2, res_sig[5:0], 1'b0};
                    10'b00001xxxxx: fma <= {s1_sign, s1_exp - 8'd3, res_sig[4:0], 2'b0};
                    10'b000001xxxx: fma <= {s1_sign, s1_exp - 8'd4, res_sig[3:0], 3'b0};
                    10'b0000001xxx: fma <= {s1_sign, s1_exp - 8'd5, res_sig[2:0], 4'b0};
                    10'b00000001xx: fma <= {s1_sign, s1_exp - 8'd6, res_sig[1:0], 5'b0};
                    10'b000000001x: fma <= {s1_sign, s1_exp - 8'd7, res_sig[0],   6'b0};
                    
                    // COMPLETE CANCELLATION (e.g., 1.0 - 1.0 = 0.0)
                    default:        fma <= 16'd0; 
                endcase
            end
        end
    end
endmodule
