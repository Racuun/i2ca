`timescale 1ns / 1ps

module top_wrapper (
    input clk,             // Pin E3 (100 MHz)
    input rst_n,           // Pin C12 (CPU_RESETN)
    input UART_RX,         // Pin C4
    output UART_TX        // Pin D4
);

    reg [5:0] clk_div_cnt = 6'd0;
    reg clk_1mhz = 1'b0;
    always @(posedge clk or negedge rst_n) begin: clock_divider
        if (!rst_n) begin
            clk_div_cnt <= 6'd0;
            clk_1mhz <= 1'b0;
        end else begin
            if (clk_div_cnt == 6'd24) begin
                clk_div_cnt <= 6'd0;
                clk_1mhz <= ~clk_1mhz;
            end else begin
                clk_div_cnt <= clk_div_cnt + 1'b1;
            end
        end
    end: clock_divider
    
    wire clk_1mhz_bufg;
    BUFG bufg0 (
        .I(clk_1mhz),
        .O(clk_1mhz_bufg)
    );


    // CPU

    //hart core_inst (
    //    .clk(clk_1mhz_bufg),
    //    .rst_n(rst_n)
    //);

endmodule


