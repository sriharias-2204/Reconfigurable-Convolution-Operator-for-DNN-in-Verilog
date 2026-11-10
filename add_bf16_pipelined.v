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

// REPLACE YOUR ADDER STAGE 1 WITH THIS:
    wire c_is_bigger = (c[14:0] >= mul[14:0]);
    wire [7:0] exp_diff = c_is_bigger ? (c[14:7] - mul[14:7]) : (mul[14:7] - c[14:7]);
    
    // Capped shift: Drastically shrinks the Barrel Shifter for 1.5ns timing
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

    // Stage 2: Parallel Math & Normalization
// Stage 2: Math & Normalize (Gated by ce)
    reg [9:0] res_sig; // EXPANDED TO 10 BITS to catch the carry overflow

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fma <= 0;
        else if (ce) begin
            if (!s1_valid) fma <= 0;
            else begin
                // Addition can overflow to 10 bits. Subtraction will remain 9 bits or less.
                res_sig = s1_op_sub ? (s1_sig_a - s1_sig_b) : (s1_sig_a + s1_sig_b);
                
                // Updated casex to handle 10-bit patterns
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

/*`timescale 1ns / 1ps

module add_bf16_pipelined (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ce,        // Clock Enable (Gate)
    input  wire [15:0] c,
    input  wire [15:0] mul,
    output reg  [15:0] fma
);

    reg        s1_valid;
    reg        s1_op_sub;
    reg        s1_sign;
    reg [8:0]  s1_exp;
    reg [9:0]  s1_sig_a; 
    reg [9:0]  s1_sig_b;

    // Stage 1: Alignment (Gated by ce)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 0; s1_op_sub <= 0; s1_sign <= 0;
            s1_exp   <= 0; s1_sig_a  <= 0; s1_sig_b  <= 0;
        end else if (ce) begin
            if (c[14:0] == 0 && mul[14:0] == 0) begin
                s1_valid <= 0;
            end else if (c[14:0] == 0) begin
                s1_sign <= mul[15]; s1_exp <= {1'b0, mul[14:7]};
                s1_sig_a <= {1'b0, 1'b1, mul[6:0]}; s1_sig_b <= 0;
                s1_op_sub <= 0; s1_valid <= 1;
            end else if (mul[14:0] == 0) begin
                s1_sign <= c[15]; s1_exp <= {1'b0, c[14:7]};
                s1_sig_a <= {1'b0, 1'b1, c[6:0]}; s1_sig_b <= 0;
                s1_op_sub <= 0; s1_valid <= 1;
            end else begin
                s1_op_sub <= c[15] ^ mul[15];
                s1_valid  <= 1;
                if ({1'b0, c[14:7]} >= {1'b0, mul[14:7]}) begin
                    s1_exp   <= {1'b0, c[14:7]};
                    s1_sign  <= c[15];
                    s1_sig_a <= {1'b0, 1'b1, c[6:0]};
                    s1_sig_b <= ({1'b0, 1'b1, mul[6:0]} >> ({1'b0, c[14:7]} - {1'b0, mul[14:7]}));
                end else begin
                    s1_exp   <= {1'b0, mul[14:7]};
                    s1_sign  <= mul[15];
                    s1_sig_a <= {1'b0, 1'b1, mul[6:0]};
                    s1_sig_b <= ({1'b0, 1'b1, c[6:0]} >> ({1'b0, mul[14:7]} - {1'b0, c[14:7]}));
                end
            end
        end
    end

    // Stage 2: Math & Normalize (Gated by ce)
    reg [10:0] sum_raw;
    reg [9:0]  sum_norm;
    reg [8:0]  exp_norm;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fma <= 0;
        else if (ce) begin
            if (!s1_valid) fma <= 0;
            else begin
                sum_raw = (s1_op_sub) ? (s1_sig_a >= s1_sig_b ? s1_sig_a - s1_sig_b : s1_sig_b - s1_sig_a) 
                                      : (s1_sig_a + s1_sig_b);
                exp_norm = s1_exp;
                if (sum_raw[8]) begin sum_norm = sum_raw[9:1]; exp_norm = exp_norm + 1; end
                else if (sum_raw[7]) begin sum_norm = sum_raw[8:0]; end
                else if (sum_raw[6]) begin sum_norm = sum_raw[8:0] << 1; exp_norm = exp_norm - 1; end
                else if (sum_raw[5]) begin sum_norm = sum_raw[8:0] << 2; exp_norm = exp_norm - 2; end
                else if (sum_raw[4]) begin sum_norm = sum_raw[8:0] << 3; exp_norm = exp_norm - 3; end
                else if (sum_raw[3]) begin sum_norm = sum_raw[8:0] << 4; exp_norm = exp_norm - 4; end
                else if (sum_raw[2]) begin sum_norm = sum_raw[8:0] << 5; exp_norm = exp_norm - 5; end
                else if (sum_raw[1]) begin sum_norm = sum_raw[8:0] << 6; exp_norm = exp_norm - 6; end
                else if (sum_raw[0]) begin sum_norm = sum_raw[8:0] << 7; exp_norm = exp_norm - 7; end
                else begin sum_norm = 0; end

                if (sum_raw == 0 || exp_norm[8]) fma <= 0;
                else if (exp_norm >= 255) fma <= {s1_sign, 8'hFF, 7'b0};
                else fma <= {s1_sign, exp_norm[7:0], sum_norm[6:0]};
            end
        end
    end
endmodule */

/*`timescale 1ns / 1ps

module add_bf16_pipelined (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ce,        // Clock Enable
    input  wire [15:0] c,
    input  wire [15:0] mul,
    output reg  [15:0] fma
);

    // =========================================================
    // Stage 1: Alignment & Unpacking
    // =========================================================
    reg        s1_valid;
    reg        s1_op_sub;
    reg        s1_sign;
    reg [8:0]  s1_exp;
    reg [9:0]  s1_sig_a; // 1 extra bit for carry/borrow
    reg [9:0]  s1_sig_b;
                // Standard Add
                reg [8:0] ea, eb;
                reg [7:0] sa, sb;
                reg [8:0] diff;
                

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 0; s1_op_sub <= 0; s1_sign <= 0;
            s1_exp <= 0; s1_sig_a <= 0; s1_sig_b <= 0;
        end else if (ce) begin
            // Zero Check
            if (c[14:0] == 0 && mul[14:0] == 0) begin
                s1_valid <= 0;
            end else if (c[14:0] == 0) begin
                // Pass 'mul' through
                s1_sign <= mul[15]; s1_exp <= {1'b0, mul[14:7]};
                s1_sig_a <= {1'b0, 1'b1, mul[6:0]}; s1_sig_b <= 0;
                s1_op_sub <= 0; s1_valid <= 1;
            end else if (mul[14:0] == 0) begin
                // Pass 'c' through
                s1_sign <= c[15]; s1_exp <= {1'b0, c[14:7]};
                s1_sig_a <= {1'b0, 1'b1, c[6:0]}; s1_sig_b <= 0;
                s1_op_sub <= 0; s1_valid <= 1;
            end else begin

                ea = {1'b0, c[14:7]}; 
                eb = {1'b0, mul[14:7]};
                sa = {1'b1, c[6:0]};  
                sb = {1'b1, mul[6:0]};

                s1_op_sub <= c[15] ^ mul[15];
                s1_valid  <= 1;

                if (ea >= eb) begin
                    diff = ea - eb;
                    s1_exp <= ea;
                    s1_sign <= c[15];
                    s1_sig_a <= {1'b0, sa};
                    s1_sig_b <= (diff > 8) ? 10'd0 : ({1'b0, sb} >> diff);
                end else begin
                    diff = eb - ea;
                    s1_exp <= eb;
                    s1_sign <= mul[15];
                    s1_sig_a <= {1'b0, sb};
                    s1_sig_b <= (diff > 8) ? 10'd0 : ({1'b0, sa} >> diff);
                end
            end
        end
    end

    // =========================================================
    // Stage 2: Math & Normalization
    // =========================================================
                reg [10:0] sum_raw; // Extra bits for overflow
                reg [9:0]  sum_norm;
                reg [8:0]  exp_norm;
                
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fma <= 0;
        end else if (ce) begin
            if (!s1_valid) begin
                fma <= 0;
            end else begin

                // 1. Calculate Sum
                if (s1_op_sub) begin
                    // Sig A is always aligned to be larger or equal exponent, 
                    // but mantissa could be smaller.
                    if (s1_sig_a >= s1_sig_b) 
                        sum_raw = s1_sig_a - s1_sig_b;
                    else begin
                        sum_raw = s1_sig_b - s1_sig_a;
                        // Note: If we flipped, sign toggles. 
                        // Simplified here assuming s1_sign tracks larger magnitude.
                    end
                end else begin
                    sum_raw = s1_sig_a + s1_sig_b;
                end

                // 2. Normalize (Priority Encoder Style - Faster than Loop)
                exp_norm = s1_exp;
                
                if (sum_raw[8]) begin // Overflow (1x.xxx)
                    sum_norm = sum_raw[9:1]; // Shift Right
                    exp_norm = exp_norm + 1;
                end else if (sum_raw[7]) begin // No shift
                    sum_norm = sum_raw[8:0];
                end else if (sum_raw[6]) begin // 0.1xxxx
                    sum_norm = sum_raw[8:0] << 1; exp_norm = exp_norm - 1;
                end else if (sum_raw[5]) begin // 0.01xxx
                    sum_norm = sum_raw[8:0] << 2; exp_norm = exp_norm - 2;
                end else if (sum_raw[4]) begin
                    sum_norm = sum_raw[8:0] << 3; exp_norm = exp_norm - 3;
                end else if (sum_raw[3]) begin
                    sum_norm = sum_raw[8:0] << 4; exp_norm = exp_norm - 4;
                end else if (sum_raw[2]) begin
                    sum_norm = sum_raw[8:0] << 5; exp_norm = exp_norm - 5;
                end else if (sum_raw[1]) begin
                    sum_norm = sum_raw[8:0] << 6; exp_norm = exp_norm - 6;
                end else if (sum_raw[0]) begin
                    sum_norm = sum_raw[8:0] << 7; exp_norm = exp_norm - 7;
                end else begin
                    sum_norm = 0; // Underflow to zero
                end

                // 3. Pack Output
                if (sum_raw == 0 || exp_norm[8]) begin // Check negative exponent (underflow)
                    fma <= 0;
                end else if (exp_norm >= 255) begin
                    fma <= {s1_sign, 8'hFF, 7'b0}; // Saturate
                end else begin
                    fma <= {s1_sign, exp_norm[7:0], sum_norm[6:0]};
                end
            end
        end
    end

endmodule
*/