`timescale 1ns / 1ps

module co_cluster (
    input  wire         clk, 
    input  wire         rst_n,
    input  wire         is_1x1,      // 1=1x1 Mode, 0=3x3/7x7 Mode
    input  wire         in_valid,  
    input  wire [143:0] pixels,
    input  wire [143:0] weights,
    output reg  [143:0] parallel_out, 
    output reg  [15:0]  summed_out,   
    output wire         out_valid   
);

    //Multiplier Array (Clock Gating + Operand Isolation)
    wire [15:0] p [0:8];
    genvar i;
    generate
        for(i=0; i<9; i=i+1) begin : mult_array
            wire [15:0] px = pixels[16*i +: 16];
            wire [15:0] wt = weights[16*i +: 16];

            // Sparsity Detection: Only active if pixel is non-zero
            wire px_nonzero = |px[14:0];
            wire active = in_valid && px_nonzero;

            wire gclk_in;
            icg_cell u_icg (.clk(clk), .en(active), .gclk(gclk_in));

            reg [15:0] reg_px, reg_wt;
            always @(posedge gclk_in or negedge rst_n) begin
                if (!rst_n) begin reg_px <= 0; reg_wt <= 0; end
                else begin reg_px <= px; reg_wt <= wt; end
            end

            // Valid pipeline to control Operand Isolation
            reg stage1_valid;
            always @(posedge clk or negedge rst_n) begin
                if(!rst_n) stage1_valid <= 0;
                else stage1_valid <= active;
            end

            // Operand Isolation
            wire [15:0] px_iso = stage1_valid ? reg_px : 16'd0;
            wire [15:0] wt_iso = stage1_valid ? reg_wt : 16'd0;

            bf16_approx_trunc u_mul (
                .clk(clk), .rst_n(rst_n),
                .a(px_iso), .b(wt_iso), .out(p[i])
            );
        end
    endgenerate

    reg [3:0] fast_valid_pipe;  
    reg [11:0] slow_valid_pipe; 

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            fast_valid_pipe <= 0;
            slow_valid_pipe <= 0;
        end else begin
            fast_valid_pipe <= {fast_valid_pipe[2:0],  (in_valid && is_1x1)};
            slow_valid_pipe <= {slow_valid_pipe[10:0], (in_valid && !is_1x1)};
        end
    end
    
    assign out_valid = fast_valid_pipe[3] || slow_valid_pipe[11];

    wire gclk_par_out;
    icg_cell u_icg_par (.clk(clk), .en(fast_valid_pipe[2]), .gclk(gclk_par_out));
    
    always @(posedge gclk_par_out or negedge rst_n) begin
        if(!rst_n) parallel_out <= 0;
        else parallel_out <= {p[8],p[7],p[6],p[5],p[4],p[3],p[2],p[1],p[0]};
    end

    wire [15:0] adder_p [0:8];
    genvar j;
    generate
        for(j=0; j<9; j=j+1) begin : adder_iso
            // If in 1x1 mode, force all bits to 0 to completely freeze the adder tree combinational logic
            assign adder_p[j] = is_1x1 ? 16'd0 : p[j];
        end
    endgenerate

    // Clock the 96 Flip-Flops ONLY if we are in 3x3 mode AND data is flowing
    wire shift_active = (!is_1x1) && (in_valid || |slow_valid_pipe[11:0]);
    wire gclk_shift;
    icg_cell u_icg_shift (.clk(clk), .en(shift_active), .gclk(gclk_shift));

    reg [15:0] p8_d [0:5];
    integer k;
    
    always @(posedge gclk_shift or negedge rst_n) begin 
        if(!rst_n) for(k=0; k<6; k=k+1) p8_d[k] <= 0;
        else begin
            p8_d[0] <= adder_p[8];
            for(k=1; k<6; k=k+1) p8_d[k] <= p8_d[k-1];
        end
    end

    wire [15:0] s1 [0:3], s2 [0:1], s3, tree_final;
    add_bf16_pipelined a1_0 (.clk(clk), .rst_n(rst_n), .ce(shift_active), .c(adder_p[0]), .mul(adder_p[1]), .fma(s1[0]));
    add_bf16_pipelined a1_1 (.clk(clk), .rst_n(rst_n), .ce(shift_active), .c(adder_p[2]), .mul(adder_p[3]), .fma(s1[1]));
    add_bf16_pipelined a1_2 (.clk(clk), .rst_n(rst_n), .ce(shift_active), .c(adder_p[4]), .mul(adder_p[5]), .fma(s1[2]));
    add_bf16_pipelined a1_3 (.clk(clk), .rst_n(rst_n), .ce(shift_active), .c(adder_p[6]), .mul(adder_p[7]), .fma(s1[3]));
    
    add_bf16_pipelined a2_0 (.clk(clk), .rst_n(rst_n), .ce(shift_active), .c(s1[0]), .mul(s1[1]), .fma(s2[0]));
    add_bf16_pipelined a2_1 (.clk(clk), .rst_n(rst_n), .ce(shift_active), .c(s1[2]), .mul(s1[3]), .fma(s2[1]));
    
    add_bf16_pipelined a3_0 (.clk(clk), .rst_n(rst_n), .ce(shift_active), .c(s2[0]), .mul(s2[1]), .fma(s3));
    
    add_bf16_pipelined a4_0 (.clk(clk), .rst_n(rst_n), .ce(shift_active), .c(s3), .mul(p8_d[5]), .fma(tree_final));

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) summed_out <= 0;
        else begin
            if (slow_valid_pipe[10]) summed_out <= tree_final;
        end
    end

endmodule 
