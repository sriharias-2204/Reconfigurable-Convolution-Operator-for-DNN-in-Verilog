`timescale 1ns / 1ps

module icg_cell (
    input wire clk,
    input wire en,
    output wire gclk
);
    // Behavioral Latch-Based Clock Gating
    // Synthesis tools (Genus) will map this to a physical ICG cell.
    reg en_latch;
    always @(clk or en) begin
        if (!clk) en_latch <= en;
    end
    assign gclk = clk & en_latch;
endmodule
