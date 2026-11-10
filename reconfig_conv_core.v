`timescale 1ns / 1ps

module reconfig_conv_core (
    input  wire         clk,
    input  wire         rst_n,

    // Control Interface
    input  wire         in_valid,    // Valid pulse for Input Pixels
    input  wire         weight_load, // Pulse to update Weight Cache
    input  wire [1:0]   mode,        // 0:1x1, 1:3x3, 2:7x7
    
    // Data Interface (SHRUNK TO 144-BITS!)
    input  wire [143:0] pixels,      
    input  wire [143:0] weights,     

    // Result Interface
    output reg  [143:0] out_1x1,     // Parallel 1x1 result
    output reg  [15:0]  out_sum,     // Summed 3x3 or 7x7 result
    output reg          out_valid,
    output reg          busy         // High only during 7x7 processing
);

    wire is_folded_mode = (mode == 2'd2); 
    wire is_fast_mode   = !is_folded_mode; 

    localparam IDLE=0, ACCUM=1, ADD_WAIT=2, MERGE_1=3, MERGE_2=4, DONE_WAIT=5;
    reg [2:0] state;
    
    reg [2:0] chunk_in_cnt; // Tracks incoming chunks for 7x7
    reg [2:0] recv_cnt;     // Tracks outgoing partial sums for 7x7
    reg [15:0] acc0, acc1, acc2; 
    reg [2:0] wait_cnt;
    reg [15:0] captured_sum;

    reg  [15:0] add_op_a, add_op_b;
    wire [15:0] add_result;
    reg         add_ce;

    reg [143:0] weight_cache; 

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) weight_cache <= 0;
        else if (weight_load) weight_cache <= weights;
    end

    reg [143:0] px_mux, wt_mux;
    
    always @(*) begin
        if (mode == 2'd0) begin      // 1x1 (Fast - Pixel Stationary)
            // Broadcast the single cached weight to all 9 multipliers
            px_mux = {9{weight_cache[15:0]}}; 
            wt_mux = pixels; 
        end else begin               // 3x3 and 7x7
            px_mux = pixels;
            wt_mux = weight_cache;
        end
    end

    wire [143:0] cl_par_out;
    wire [15:0]  cl_sum_out;
    wire         cl_valid;

    co_cluster U_CLUSTER (
        .clk         (clk),
        .rst_n       (rst_n),
        .is_1x1      (mode == 2'd0),
        .in_valid    (in_valid), // Driven directly by external scheduler now
        .pixels      (px_mux),
        .weights     (wt_mux),
        .parallel_out(cl_par_out),
        .summed_out  (cl_sum_out),
        .out_valid   (cl_valid)
    );


    add_bf16_pipelined U_SHARED_ADD (
        .clk(clk),
        .rst_n(rst_n),
        .ce(add_ce),
        .c(add_op_a),
        .mul(add_op_b),
        .fma(add_result)
    );
    
    always @(*) begin
        add_ce = 0; add_op_a = 0; add_op_b = 0;
        if (state == ADD_WAIT) begin
            add_ce = 1; add_op_a = captured_sum; 
            case(recv_cnt) 3: add_op_b = acc0; 4: add_op_b = acc1; 5: add_op_b = acc2; endcase
        end
        else if (state == MERGE_1) begin add_ce = 1; add_op_a = acc0; add_op_b = acc1; end
        else if (state == MERGE_2) begin add_ce = 1; add_op_a = captured_sum; add_op_b = acc2; end
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state <= IDLE; busy <= 0; chunk_in_cnt <= 0; recv_cnt <= 0;
            acc0 <= 0; acc1 <= 0; acc2 <= 0; wait_cnt <= 0; captured_sum <= 0;
            out_valid <= 0; out_1x1 <= 0; out_sum <= 0;
        end else begin
            out_valid <= 0; // Default pull-down to create perfect 1-cycle pulses

            // PATH A: FAST MODE (Burst Output)
            if (is_fast_mode && cl_valid) begin
                out_valid <= 1;
                if (mode == 2'd0) out_1x1 <= cl_par_out;
                else              out_sum <= cl_sum_out;
            end

            // PATH B: 7x7 FOLDED MODE FSM
            case(state)
                IDLE: begin
                    busy <= 0;
                    if(in_valid && is_folded_mode) begin
                        busy <= 1; state <= ACCUM;
                        chunk_in_cnt <= 1; recv_cnt <= 0;
                        acc0 <= 0; acc1 <= 0; acc2 <= 0;
                    end
                end

                ACCUM: begin
                    if (in_valid) chunk_in_cnt <= chunk_in_cnt + 1;
                    
                    if (cl_valid && is_folded_mode) begin
                        captured_sum <= cl_sum_out; // Lock the cluster's output safely
                        if (recv_cnt < 3) begin
                            // First 3 chunks bypass the adder
                            case(recv_cnt) 0: acc0 <= cl_sum_out; 1: acc1 <= cl_sum_out; 2: acc2 <= cl_sum_out; endcase
                            recv_cnt <= recv_cnt + 1;
                        end else begin
                            // Next 3 chunks trigger the shared adder
                            state <= ADD_WAIT;
                            wait_cnt <= 2; // Adder takes exactly 2 cycles
                        end
                    end
                    else if (recv_cnt == 6) begin
                        state <= MERGE_1;
                        wait_cnt <= 2;
                    end
                end

                ADD_WAIT: begin
                    if (wait_cnt > 0) wait_cnt <= wait_cnt - 1;
                    else begin
                        // Adder is done. Save result to the correct accumulator.
                        case(recv_cnt) 3: acc0 <= add_result; 4: acc1 <= add_result; 5: acc2 <= add_result; endcase
                        recv_cnt <= recv_cnt + 1;
                        state <= ACCUM; // Go back to waiting for the next chunk
                    end
                end

                MERGE_1: begin
                    if (wait_cnt > 0) wait_cnt <= wait_cnt - 1;
                    else begin
                        captured_sum <= add_result; // Safely lock the sum of (acc0 + acc1)
                        state <= MERGE_2;
                        wait_cnt <= 2;
                    end
                end

                MERGE_2: begin
                    if (wait_cnt > 0) wait_cnt <= wait_cnt - 1;
                    else begin
                        out_sum <= add_result; // Final Output!
                        out_valid <= 1;
                        state <= DONE_WAIT;
                    end
                end

                DONE_WAIT: begin
                    state <= IDLE;
                    busy <= 0;
                end
            endcase
        end
    end
endmodule
