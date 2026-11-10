`timescale 1ns / 1ps

module bf16_approx_trunc (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [15:0]  a,   
    input  wire [15:0]  b,   
    output reg  [15:0]  out
);

    // Stage 1: Combinational Logic
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

    // Stage 2: Balanced Pipeline Registers
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

 // =========================================================
    // Stage 3: Normalization & Faster Output Clamping
    // =========================================================
    wire [15:0] prod_ext = {pipe_prod, 1'b0};
    reg [7:0] final_exp;
    reg [6:0] final_mant;
    reg [15:0] next_out; // <-- ADDED: Intermediate combinational signal

    always @(*) begin
        if (prod_ext[15]) begin 
            final_exp  = pipe_exp[7:0] + 1'b1;
            final_mant = prod_ext[14:8];
        end else begin
            final_exp  = pipe_exp[7:0];
            final_mant = prod_ext[13:7];
        end

        // High-Speed Clamping Logic assigned to NEXT_OUT
        if (pipe_exp < 0)        next_out = {pipe_sign, 8'h00, 7'b0}; // Underflow
        else if (pipe_exp > 255) next_out = {pipe_sign, 8'hFF, 7'b0}; // Overflow/Inf
        else                     next_out = {pipe_sign, final_exp, final_mant};
    end

    // =========================================================
    // Stage 4: Output Register (Restores 2-Cycle Latency!)
    // =========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) out <= 16'd0;
        else out <= next_out;
    end
endmodule

/*`timescale 1ns / 1ps

module bf16_approx_trunc (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [15:0]  a,
    input  wire [15:0]  b,
    output reg  [15:0]  out
);

    // =========================================================
    // Stage 1: Input Register + Sign + Exponent Add
    // =========================================================
    reg        s1_sign;
    reg signed [9:0] s1_exp;
    reg [7:0]  s1_mant_a;
    reg [6:0]  s1_mant_b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_sign   <= 1'b0;
            s1_exp    <= 10'sd0;
            s1_mant_a <= 8'd0;
            s1_mant_b <= 7'd0;
        end else begin
            s1_sign   <= a[15] ^ b[15];
            s1_exp    <= {2'b0,a[14:7]} + {2'b0,b[14:7]} - 10'sd127;
            s1_mant_a <= {1'b1, a[6:0]};
            s1_mant_b <= {1'b1, b[6:1]};   // truncated mantissa
        end
    end

    // =========================================================
    // Stage 2: Mantissa Multiply
    // =========================================================
    wire [14:0] mult_core;

    dadda_mult_8x7 u_dadda_core (
        .a(s1_mant_a),
        .b(s1_mant_b),
        .p(mult_core)
    );

    reg [14:0] s2_prod;
    reg signed [9:0] s2_exp;
    reg s2_sign;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_prod <= 15'd0;
            s2_exp  <= 10'sd0;
            s2_sign <= 1'b0;
        end else begin
            s2_prod <= mult_core;
            s2_exp  <= s1_exp;
            s2_sign <= s1_sign;
        end
    end

    // =========================================================
    // Stage 3: Normalize + Exponent Adjust + BF16 Pack
    // =========================================================
    reg [15:0] norm_prod;
    reg signed [9:0] norm_exp;
    reg [15:0] next_out;

    wire [15:0] product_raw = {s2_prod, 1'b0};

    always @(*) begin
        // Normalization
        if (product_raw[15]) begin
            norm_prod = product_raw >> 1;
            norm_exp  = s2_exp + 1;
        end else begin
            norm_prod = product_raw;
            norm_exp  = s2_exp;
        end

        // Clamp + Pack BF16
        if (norm_exp < 0)
            next_out = {s2_sign, 8'h00, norm_prod[13:7]};
        else if (norm_exp > 255)
            next_out = {s2_sign, 8'hFF, norm_prod[13:7]};
        else
            next_out = {s2_sign, norm_exp[7:0], norm_prod[13:7]};
    end

    // Output Register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            out <= 16'h0000;
        else
            out <= next_out;
    end

endmodule*/


/*`timescale 1ns / 1ps
// 2 pipeline stages/2 clock cycles
module bf16_approx_trunc (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [15:0]  a,   // Already Registered & Isolated by Parent
    input  wire [15:0]  b,   // Already Registered & Isolated by Parent
    output reg  [15:0]  out
);

    // =========================================================
    // Stage 1: Combinational Logic
    // =========================================================
    wire sign_res = a[15] ^ b[15];
    wire signed [9:0] exp_temp = {2'b0,a[14:7]} + {2'b0,b[14:7]} - 10'sd127;

    // Mantissa Prep
    wire [7:0] mant_a_fixed  = {1'b1, a[6:0]};
    wire [6:0] mant_b_approx = {1'b1, b[6:1]}; 
    wire [14:0] product_core;
    
    // Core Multiplier
    dadda_mult_8x7 u_dadda_core (
        .a(mant_a_fixed), .b(mant_b_approx), .p(product_core)
    );

    // =========================================================
    // Stage 2: Pipeline Registers
    // =========================================================
    reg [14:0] pipe_prod;
    reg signed [9:0] pipe_exp;
    reg pipe_sign;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            pipe_prod <= 0; pipe_exp <= 0; pipe_sign <= 0;
        end else begin
            pipe_prod <= product_core;
            pipe_exp  <= exp_temp;
            pipe_sign <= sign_res;
        end
    end

    // =========================================================
    // Stage 3: Normalization & Output
    // =========================================================
    reg [15:0] next_out;
    reg [15:0] norm_prod;
    reg signed [9:0] norm_exp;
    wire [15:0] product_raw = {pipe_prod, 1'b0};

    always @(*) begin
        // Normalize
        if (product_raw[15]) begin
            norm_prod = product_raw >> 1;
            norm_exp  = pipe_exp + 1;
        end else begin
            norm_prod = product_raw;
            norm_exp  = pipe_exp;
        end

        // Clamp / Round
        if (norm_exp < 0) next_out = {pipe_sign, 8'h00, norm_prod[13:7]};
        else if (norm_exp > 255) next_out = {pipe_sign, 8'hFF, norm_prod[13:7]};
        else next_out = {pipe_sign, norm_exp[7:0], norm_prod[13:7]};
    end

    // Output Register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) out <= 0;
        else out <= next_out;
    end

endmodule */

/*`timescale 1ns / 1ps

module bf16_approx_trunc (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         lane_en, // NOVELTY: Gating Signal
    input  wire [15:0]  a,
    input  wire [15:0]  b,
    output reg  [15:0]  out
);

    // =========================================================
    // Stage 1: Gated Input Registers (Freeze Logic)
    // =========================================================
    // If lane_en is 0, these registers HOLD their value.
    // This stops switching activity in the multiplier tree.
    reg [15:0] reg_a, reg_b;
    reg        sign_r;
    reg signed [9:0] exp_temp_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_a      <= 0; reg_b      <= 0;
            sign_r     <= 0; exp_temp_r <= 0;
        end else if (lane_en) begin
            reg_a      <= a;
            reg_b      <= b;
            sign_r     <= a[15] ^ b[15];
            exp_temp_r <= {2'b0,a[14:7]} + {2'b0,b[14:7]} - 10'sd127;
        end
        // Implicit ELSE: Registers hold previous value (Static Power only)
    end

    // =========================================================
    // Stage 2: Combinational Multiplier Core
    // =========================================================
    wire [7:0] mant_a_fixed = {1'b1, reg_a[6:0]};
    wire [6:0] mant_b_approx = {1'b1, reg_b[6:1]}; 
    wire [14:0] product_core;
    
    // Ensure 'dadda_mult_8x7' is in your project
    dadda_mult_8x7 u_dadda_core (
        .a(mant_a_fixed), .b(mant_b_approx), .p(product_core)
    );

    // =========================================================
    // Stage 3: Pipeline Register & Output Gating
    // =========================================================
    reg [14:0] pipe_prod;
    reg signed [9:0] pipe_exp;
    reg pipe_sign;
    
    // We also pipeline the enable signal to zero-out the final result
    reg lane_en_pipe;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            pipe_prod <= 0; pipe_exp <= 0; pipe_sign <= 0; lane_en_pipe <= 0;
        end else begin
            // We can update pipe regs every cycle, or gate them too.
            // Updating them is fine because if lane_en was 0, 
            // product_core is static (no toggle), so power is low.
            pipe_prod <= product_core;
            pipe_exp  <= exp_temp_r;
            pipe_sign <= sign_r;
            lane_en_pipe <= lane_en;
        end
    end

    // Normalization & Output Logic
    reg [15:0] next_out;
    reg [15:0] norm_prod;
    reg signed [9:0] norm_exp;
    wire [15:0] product_raw = {pipe_prod, 1'b0};

    always @(*) begin
        // Normalize
        if (product_raw[15]) begin
            norm_prod = product_raw >> 1;
            norm_exp  = pipe_exp + 1;
        end else begin
            norm_prod = product_raw;
            norm_exp  = pipe_exp;
        end

        // Round/Clamp
        if (norm_exp < 0) 
            next_out = {pipe_sign, 8'h00, norm_prod[13:7]};
        else if (norm_exp > 255) 
            next_out = {pipe_sign, 8'hFF, norm_prod[13:7]};
        else 
            next_out = {pipe_sign, norm_exp[7:0], norm_prod[13:7]};
    end

    // Final Output Register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) out <= 0;
        else if (lane_en_pipe) out <= next_out;
        else out <= 16'd0; // Force Zero if lane was disabled
    end

endmodule
*/
/*`timescale 1ns / 1ps

module bf16_approx_trunc (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [15:0]  a,
    input  wire [15:0]  b,
    output reg  [15:0]  out
);

    reg [15:0] reg_a, reg_b;
    reg        sign_r;
    reg signed [9:0] exp_temp_r;
    reg        a_zero_r, b_zero_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_a      <= 0; reg_b      <= 0;
            sign_r     <= 0; exp_temp_r <= 0;
            a_zero_r   <= 1; b_zero_r   <= 1;
        end else begin
            reg_a      <= a;
            reg_b      <= b;
            a_zero_r   <= (a[14:0] == 0);
            b_zero_r   <= (b[14:0] == 0);
            sign_r     <= a[15] ^ b[15];
            exp_temp_r <= {2'b0,a[14:7]} + {2'b0,b[14:7]} - 10'sd127;
        end
    end

    wire [7:0] mant_a_fixed = {1'b1, reg_a[6:0]};
    wire [6:0] mant_b_approx = {1'b1, reg_b[6:1]}; 

    wire [14:0] product_core;
    
    dadda_mult_8x7 u_dadda_core (
        .a(mant_a_fixed), .b(mant_b_approx), .p(product_core)
    );
    reg [14:0] pipe_prod;
    reg signed [9:0] pipe_exp;
    reg pipe_sign;
    reg pipe_zero;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            pipe_prod <= 0; pipe_exp <= 0; pipe_sign <= 0; pipe_zero <= 0;
        end else begin
            pipe_prod <= product_core;
            pipe_exp  <= exp_temp_r;
            pipe_sign <= sign_r;
            pipe_zero <= (a_zero_r || b_zero_r); 
        end
    end
    wire [15:0] product_raw = {pipe_prod, 1'b0};
    reg [15:0] next_out;
    reg [15:0] norm_prod;
    reg signed [9:0] norm_exp;

    always @(*) begin
        // Normalize
        if (product_raw[15]) begin
            norm_prod = product_raw >> 1;
            norm_exp  = pipe_exp + 1;
        end else begin
            norm_prod = product_raw;
            norm_exp  = pipe_exp;
        end

        // Round/Clamp
        if (norm_exp < 0) 
            next_out = {pipe_sign, 8'h00, norm_prod[13:7]};
        else if (norm_exp > 255) 
            next_out = {pipe_sign, 8'hFF, norm_prod[13:7]};
        else 
            next_out = {pipe_sign, norm_exp[7:0], norm_prod[13:7]};

        // Final Zero Override (Happens at the very end to save timing)
        if (pipe_zero) next_out = 16'd0;
    end

    // Output Register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) out <= 0;
        else out <= next_out;
    end

endmodule*/

/*`timescale 1ns / 1ps

module bf16_approx_trunc (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] a,
    input  wire [15:0] b,
    output reg  [15:0] out
);

    // =========================================================
    // Stage 1: Register ALL inputs & control (CRITICAL)
    // =========================================================
    reg [15:0] reg_a, reg_b;
    reg        a_zero_r, b_zero_r;
    reg        sign_r;
    reg signed [9:0] exp_temp_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_a      <= 16'd0;
            reg_b      <= 16'd0;
            a_zero_r   <= 1'b1;
            b_zero_r   <= 1'b1;
            sign_r     <= 1'b0;
            exp_temp_r <= 10'sd0;
        end else begin
            reg_a      <= a;
            reg_b      <= b;
            a_zero_r   <= (a[14:0] == 0);
            b_zero_r   <= (b[14:0] == 0);
            sign_r     <= a[15] ^ b[15];
            exp_temp_r <= {2'b0,a[14:7]} + {2'b0,b[14:7]} - 10'sd127;
        end
    end

    // =========================================================
    // Field Extraction (from registered operands)
    // =========================================================
    wire [6:0] mant_a = reg_a[6:0];
    wire [6:0] mant_b = reg_b[6:0];

    // =========================================================
    // Mantissa Preparation (ZERO-SAFE)
    // =========================================================
    wire [7:0] mant_a_fixed =
        a_zero_r ? 8'd0 : {1'b1, mant_a};

    wire [6:0] mant_b_approx =
        b_zero_r ? 7'd0 : {1'b1, mant_b[6:1]}; // truncated approx

    // =========================================================
    // Dadda Multiplier Core (8x7)
    // =========================================================
    wire [14:0] product_core;

    dadda_mult_8x7 u_dadda_core (
        .a(mant_a_fixed),
        .b(mant_b_approx),
        .p(product_core)
    );

    // Align to Q1.15
    wire [15:0] product_raw = {product_core, 1'b0};

    // =========================================================
    // Stage 2: Normalization + Truncation
    // =========================================================
    reg [15:0] norm_prod;
    reg signed [9:0] norm_exp;
    reg [15:0] next_out;

    always @(*) begin
        // ----------------------------
        // ZERO short-circuit
        // ----------------------------
        if (a_zero_r || b_zero_r) begin
            next_out = 16'h0000;
        end else begin
            // ----------------------------
            // Normalize
            // ----------------------------
            if (product_raw[15]) begin
                norm_prod = product_raw >> 1;
                norm_exp  = exp_temp_r + 1;
            end else begin
                norm_prod = product_raw;
                norm_exp  = exp_temp_r;
            end

            // ----------------------------
            // Clamp exponent + truncate
            // ----------------------------
            if (norm_exp < 0) begin
                next_out = {sign_r, 8'h00, norm_prod[13:7]};
            end else if (norm_exp > 255) begin
                next_out = {sign_r, 8'hFF, norm_prod[13:7]};
            end else begin
                next_out = {sign_r, norm_exp[7:0], norm_prod[13:7]};
            end
        end
    end

    // =========================================================
    // Stage 3: Output Register
    // =========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            out <= 16'd0;
        else
            out <= next_out;
    end
//assign out = next_out;


endmodule
*/


/*`timescale 1ns / 1ps

module bf16_approx_trunc (
    input wire clk,             // Added Clock
    input wire rst_n,           // Added Active-Low Reset
    input wire [15:0] a,
    input wire [15:0] b,
    output reg [15:0] out
);

    // --- Stage 1: Input Registers ---
    reg [15:0] reg_a, reg_b;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_a <= 16'd0;
            reg_b <= 16'd0;
        end else begin
            reg_a <= a;
            reg_b <= b;
        end
    end

    // --- Combinational Logic (Using Registered Inputs) ---
    wire sign_a = reg_a[15];
    wire sign_b = reg_b[15];
    
    wire [7:0] exp_a = reg_a[14:7];
    wire [7:0] exp_b = reg_b[14:7];
    
    wire [6:0] mant_a = reg_a[6:0];
    wire [6:0] mant_b = reg_b[6:0];

    wire [7:0] mant_a_fixed = {1'b1, mant_a};
    wire [6:0] mant_b_approx = {1'b1, mant_b[6:1]};
    wire [14:0] product_core;

    dadda_mult_8x7 u_dadda_core (
        .a(mant_a_fixed),   // 8 bits
        .b(mant_b_approx),  // 7 bits
        .p(product_core)    // 15 bits output
    );

    wire [15:0] product_raw;
    assign product_raw = {product_core, 1'b0};

    wire res_sign = sign_a ^ sign_b;
    wire signed [9:0] exp_temp = {2'b0, exp_a} + {2'b0, exp_b} - 10'sd127;

    reg [15:0] norm_prod;
    reg signed [9:0] norm_exp;
    reg [15:0] next_out; // Temporary variable for the next output

    always @(*) begin
        // Normalization
        if (product_raw[15]) begin
            norm_prod = product_raw >> 1;
            norm_exp = exp_temp + 1;
        end else begin
            norm_prod = product_raw;
            norm_exp = exp_temp;
        end

        // Truncation Logic (Select bits 13:7)
        // Note: norm_prod is 16 bits. Bit 15 is hidden 1 (or 0 if denorm). 
        // 1.xxxx... format.
        // We take the top 7 fractional bits for truncation.
        // (Ensure this bit slicing matches your specific truncation/approx requirement)
        
        // Final Output Logic
        if (reg_a[14:0] == 0 || reg_b[14:0] == 0) begin
            next_out = 16'h0000;
        end else begin
            if (norm_exp < 0) begin
                next_out = {res_sign, 8'h00, norm_prod[13:7]}; 
            end else if (norm_exp > 255) begin
                next_out = {res_sign, 8'hFF, norm_prod[13:7]}; 
            end else begin
                next_out = {res_sign, norm_exp[7:0], norm_prod[13:7]};
            end
        end
    end

    // --- Stage 2: Output Register ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out <= 16'd0;
        end else begin
            out <= next_out;
        end
    end

endmodule */