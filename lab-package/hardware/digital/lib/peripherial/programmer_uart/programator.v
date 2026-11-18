
// ======================================
//    TOP MODULE
// ======================================

// Protocol:

 // -> REQ (LOW 100ms)
 // <- READY (0xAA)
 //
 // -> SET_ADDR (0x41)
 // -> ADDR
 // <- ACK (0x5A)
 //
 // -> WRITE_DATA (0x44)
 // -> DATA
 // <- ACK (0x5A)
 //
 // -> DONE (0x96)
 // <- DONE (0x96)
 //
 // -> PING (0x55)
 // <- PING (0x55) - reset timeout timer

 // NACK (0xA5) - resend data
 // TIMEOUT (0x69) - transmision timeout; reset FSM; retransmission needed

module Programator#(
    parameter CLK_FREQ = 1000000,
    parameter BAUD_RATE = 9600,
    parameter LOW_TIME_MS = 100,
    parameter OVERSAMPLING = 16,
    parameter TIMEOUT_MS = 1000
)(
    input clk,
    input rst_n,

    input uart_rx,
    output uart_tx,

    output reg [31:0] waddr,
    output reg [31:0] wdata,
    output reg d_valid,

    output reg rst_req_n
);

    localparam [7:0] READY_MSG      = 8'hAA;
    localparam [7:0] SET_ADDR_MSG   = 8'h41;
    localparam [7:0] WRITE_DATA_MSG = 8'h44;
    localparam [7:0] ACK_MSG        = 8'h5A;
    localparam [7:0] NACK_MSG       = 8'hA5;
    localparam [7:0] TIMEOUT_MSG    = 8'h69;
    localparam [7:0] DONE_MSG       = 8'h96;
    localparam [7:0] PING_MSG       = 8'h55;

    wire sync_rx;
    uart_sync SYNC (
        .clk(clk),
        .rst_n(rst_n),
        .uart_rx(uart_rx),
        .sync_rx(sync_rx)
    );

    wire wake_rq;
    req_detector REQ_DT (
        .clk(clk),
        .rst_n(rst_n),
        .uart_rx(sync_rx),
        .wake_up(wake_rq)
    );
    defparam REQ_DT.CLK_FREQ = CLK_FREQ;
    defparam REQ_DT.LOW_TIME_MS = LOW_TIME_MS;

    reg [7:0] tx_data;
    reg txd_valid;
    wire tx_ready;
    uart_tranciver TX (
        .clk(clk),
        .rst_n(rst_n),
        .data(tx_data),
        .d_valid(txd_valid),
        .ready(tx_ready),
        .uart_tx(uart_tx)
    );
    defparam TX.CLK_FREQ = CLK_FREQ;
    defparam TX.BAUD_RATE = BAUD_RATE;

    wire [7:0] rx_data;
    wire rxd_valid, rx_error;
    uart_receiver RX (
        .clk(clk),
        .rst_n(rst_n),
        .uart_rx(sync_rx),
        .odata(rx_data),
        .d_valid(rxd_valid),
        .error(rx_error)
    );
    defparam RX.CLK_FREQ = CLK_FREQ;
    defparam RX.BAUD_RATE = BAUD_RATE;
    defparam RX.OVERSAMPLING = OVERSAMPLING;



    localparam [2:0] SLEEP = 3'b000,
        WAKING = 3'b001,
        ADDR = 3'b010,
        DATA = 3'b011,
        CMD = 3'b100,
        DONE = 3'b101,
        SHUTDOWN = 3'b110,
        TIMEOUT = 3'b111;
    reg [2:0] state;

    localparam TIMEOUT_CYCLE = (CLK_FREQ/1000)*TIMEOUT_MS;
    reg [$clog2(TIMEOUT_CYCLE)-1:0] timeout_count;


    reg [1:0] addr_byte;
    reg [1:0] data_byte;
    reg [31:0] addr;

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin
            state <= SLEEP;
            timeout_count <= 0;
            d_valid <= 1'b0;
            txd_valid <= 1'b0;
            rst_req_n <= 1'b1;
            addr_byte <= 0;
            data_byte <= 0;
        end
        else begin

            if (state == SLEEP) begin
                timeout_count <= 0;
            end
            else if (timeout_count >= TIMEOUT_CYCLE && state != TIMEOUT) begin
                state <= TIMEOUT;
            end
            else if (rxd_valid || rx_error) begin
                timeout_count <= 0;
            end
            else begin
                timeout_count <= timeout_count + 1;
            end

            case(state)
                SLEEP: begin
                    rst_req_n <= 1'b1;
                    d_valid <= 1'b0;
                    txd_valid <= 1'b0;

                    if (wake_rq) begin
                        state <= WAKING;
                    end
                end
                WAKING: begin
                    rst_req_n <= 1'b0;
                    d_valid <= 1'b0;

                    if (tx_ready) begin
                        txd_valid <= 1'b1;
                        tx_data <= READY_MSG;
                        state <= CMD;

                        addr_byte <= 0;
                        data_byte <= 0;
                    end
                end
                CMD: begin
                    d_valid <= 1'b0;
                    txd_valid <= 1'b0;

                    if (rxd_valid) begin

                        case(rx_data)
                            SET_ADDR_MSG: begin
                                addr_byte <= 0;
                                state <= ADDR;
                            end
                            WRITE_DATA_MSG: begin
                                data_byte <= 0;
                                state <= DATA;
                            end
                            DONE_MSG: begin
                                state <= DONE;
                            end
                            TIMEOUT_MSG: begin

                            end
                            PING_MSG: begin
                                tx_data <= PING_MSG;
                                txd_valid <= 1'b1;
                            end
                        endcase

                    end
                end
                ADDR: begin
                    if (rxd_valid) begin
                        addr[addr_byte*8 +: 8] <= rx_data;
                        addr_byte <= addr_byte + 1;

                        if (addr_byte == 2'b11) begin
                            state <= CMD;
                            tx_data <= ACK_MSG;
                            txd_valid <= 1'b1;
                        end
                    end
                    else if (rx_error) begin
                        tx_data <= NACK_MSG;
                        txd_valid <= 1'b1;
                        addr_byte <= 0;
                    end
                end
                DATA: begin
                    if (rxd_valid) begin
                        wdata[data_byte*8 +: 8] <= rx_data;
                        data_byte <= data_byte + 1;
                        if (data_byte == 2'b11) begin
                            state <= CMD;
                            tx_data <= ACK_MSG;
                            txd_valid <= 1'b1;
                            // data out
                            d_valid <= 1'b1;
                            waddr <= addr;
                            addr <= addr + 4;
                        end
                    end
                    else if (rx_error) begin
                        tx_data <= NACK_MSG;
                        txd_valid <= 1'b1;
                        data_byte <= 0;
                    end
                end
                DONE: begin
                    tx_data <= DONE_MSG;
                    txd_valid <= 1'b1;
                    state <= SHUTDOWN;
                end
                TIMEOUT: begin
                    tx_data <= TIMEOUT_MSG;
                    txd_valid <= 1'b1;

                    state <= SHUTDOWN;
                end
                SHUTDOWN: begin
                    txd_valid <= 1'b0;

                    if (!txd_valid && tx_ready) begin
                        state <= SLEEP;
                    end
                end
            endcase

        end

    end

endmodule



// ======================================
//    SUBMODULES
// ======================================

module uart_sync(
    input clk,
    input rst_n,

    input uart_rx,
    output reg sync_rx
);

    reg sync0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync_rx <= 1'b1;
            sync0 <= 1'b1;
        end
        else begin
            sync0 <= uart_rx;
            sync_rx <= sync0;
        end
    end

endmodule


module req_detector #(
    parameter CLK_FREQ = 1000000,
    parameter LOW_TIME_MS = 100
)(
    input clk,
    input rst_n,

    input uart_rx,

    output reg wake_up
);

    localparam NCYCLES = (CLK_FREQ/1000)*LOW_TIME_MS;
    localparam CMIN = NCYCLES * 95/100;
    localparam CMAX = NCYCLES * 105/100;

    reg [$clog2(CMAX+1)-1: 0] cycle_count;

    localparam IDLE = 1'b0, MEASURE = 1'b1;
    reg state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_count <= 0;
            wake_up <= 1'b0;
            state <= IDLE;
        end
        else begin

            case (state)
                IDLE: begin
                    if (!uart_rx)
                        state <= MEASURE;
                    else begin
                        cycle_count <= 0;
                        wake_up <= 1'b0;
                    end
                end
                MEASURE: begin
                    if (!uart_rx) begin
                        cycle_count <= cycle_count + 1;
                    end
                    else  begin
                        if (cycle_count > CMIN && cycle_count < CMAX)
                            wake_up <= 1'b1;

                        state <= IDLE;
                    end
                end
            endcase

        end
    end

endmodule



module uart_receiver #(
    parameter CLK_FREQ = 1000000,
    parameter BAUD_RATE = 9600,
    parameter OVERSAMPLING = 16
)(
    input clk,
    input rst_n,

    input uart_rx,

    output reg d_valid,
    output reg [7:0] odata,
    output reg error
);

    localparam  CLK_DIV = CLK_FREQ/(BAUD_RATE*OVERSAMPLING);

    reg [($clog2(CLK_DIV)-1):0] div_clk;
    reg sample_clk;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_clk <= 1'b0;
            div_clk <= 0;
        end
        else begin
            if (div_clk == CLK_DIV - 1) begin
                sample_clk <= 1'b1;
                div_clk <= 0;
            end
            else begin
                div_clk <= div_clk + 1;
                sample_clk <= 1'b0;
            end
        end
    end

    localparam [1:0] IDLE = 2'b00, START = 2'b01, DATA = 2'b10, EVAL = 2'b11;

    reg [1:0] state;
    reg [9:0] rdata_buff;

    reg [3:0] bit_count;
    reg [($clog2(OVERSAMPLING)-1):0] sample_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            rdata_buff <= 1'b0;
            sample_count <= 0;
            bit_count <= 0;
            error <= 1'b0;
            d_valid <= 1'b0;
        end
        else begin
            error <= 1'b0;
            d_valid <= 1'b0;

            case(state)
                IDLE: begin
                    bit_count <= 0;
                    sample_count <= 0;

                    if (!uart_rx) begin
                        state <= START;
                    end
                end
                START: begin
                    if (sample_clk) begin
                        if (sample_count == (OVERSAMPLING/2) - 1) begin
                            sample_count <= 0;
                            if (!uart_rx)
                                state <= DATA;
                            else
                                state <= IDLE;
                        end
                        else begin
                            sample_count <= sample_count + 1;
                        end
                    end
                end
                DATA: begin
                    if (sample_clk) begin
                        if (sample_count == OVERSAMPLING - 1) begin
                            sample_count <= 0;
                            if (bit_count == 10) begin
                                state <= EVAL;
                            end
                            else begin
                                rdata_buff <= {uart_rx, rdata_buff[9:1]};
                                bit_count <= bit_count + 1;
                            end
                        end
                        else begin
                            sample_count <= sample_count + 1;
                        end
                    end
                end
                EVAL: begin
                    if ((^rdata_buff[8:0]) || (!rdata_buff[9])) begin
                        error <= 1'b1;
                    end
                    else begin
                        d_valid <= 1'b1;
                        odata <= rdata_buff[7:0];
                    end
                    state <= IDLE;
                end
            endcase

        end
    end

endmodule



module uart_tranciver #(
    parameter CLK_FREQ = 1000000,
    parameter BAUD_RATE = 9600
)(
    input clk,
    input rst_n,

    input [7:0] data,
    input d_valid,

    output reg uart_tx,
    output reg ready
);

    localparam IDLE = 1'b0, SEND = 1'b1;
    reg state;

    localparam CLK_DIV = CLK_FREQ/BAUD_RATE;

    reg [$clog2(CLK_DIV)-1:0] div_clk;
    reg sample_tick;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_clk <= 0;
            sample_tick <= 1'b0;
        end
        else begin
            if (div_clk == CLK_DIV-1) begin
                div_clk <= 0;
                sample_tick <= 1'b1;
            end
            else begin
                if (state != IDLE)
                    div_clk <= div_clk + 1;
                else
                    div_clk <= 0;

                sample_tick <= 1'b0;
            end
        end
    end

    reg [3:0] bit_count;
    reg [9:0] packet;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            ready <= 1'b0;
            uart_tx <= 1'b1;
            bit_count <= 0;
            packet <= 0;
        end
        else begin

            case(state)
                IDLE: begin
                    if (d_valid) begin
                        ready <= 1'b0;
                        state <= SEND;
                        packet <= {1'b1, (^data), data};
                        uart_tx <= 1'b0;
                        bit_count <= 0;
                    end
                    else begin
                        ready <= 1'b1;
                        uart_tx <= 1'b1;
                    end
                end
                SEND: begin
                    if (sample_tick) begin

                        if (bit_count == 10) begin
                            uart_tx <= 1'b1;
                            state <= IDLE;
                        end
                        else begin
                            uart_tx <= packet[bit_count];
                        end
                        bit_count <= bit_count + 1;
                    end
                end
            endcase
        end
    end


endmodule
