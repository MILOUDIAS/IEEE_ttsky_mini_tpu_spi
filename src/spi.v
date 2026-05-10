`define INSTRUCTION_WIDTH 12
`define ACC_WIDTH  4
`define NN 9                   // N*N
`define BIT_COUNT 4

module spi (
    input wire clk,
    input wire rst_n,

    input wire mosi,
    input wire cs,
    input wire sclk,
    input wire ready_to_send,
    input wire [`ACC_WIDTH*`NN-1:0] data_in,

    output reg miso,
    output wire [`INSTRUCTION_WIDTH-1:0] data_buffer_output
);

localparam OUTPUT_DATA_BITS = `ACC_WIDTH*`NN;

// ---------------------------------------------------------------------------
// SCLK domain: receive SPI instructions and transmit flattened TPU results.
// ---------------------------------------------------------------------------
reg [`INSTRUCTION_WIDTH-1:0] data_buffer;
reg [`INSTRUCTION_WIDTH-1:0] instr_data_sclk;
reg [`BIT_COUNT-1:0] bit_counter;
reg instr_req_toggle_sclk;

reg tx_req_sync_1;
reg tx_req_sync_2;
reg tx_ack_toggle_sclk;
reg is_sending;
reg [$clog2(OUTPUT_DATA_BITS+1)-1:0] output_data_bit_counter;
reg [OUTPUT_DATA_BITS-1:0] tx_shift_data;

reg instr_req_sync_1;
reg instr_req_sync_2;

reg [`INSTRUCTION_WIDTH-1:0] instruction_clk;
reg data_ready;

reg [OUTPUT_DATA_BITS-1:0] tx_data_clk;
reg tx_req_toggle_clk;
reg tx_ack_sync_1;
reg tx_ack_sync_2;

wire tx_pending_sclk = (tx_req_sync_2 != tx_ack_toggle_sclk);
wire tx_pending_clk = (tx_req_toggle_clk != tx_ack_sync_2);

always @(posedge sclk or negedge rst_n) begin
    if (!rst_n) begin
        data_buffer <= 0;
        instr_data_sclk <= 0;
        bit_counter <= 0;
        instr_req_toggle_sclk <= 0;

        tx_req_sync_1 <= 0;
        tx_req_sync_2 <= 0;
        tx_ack_toggle_sclk <= 0;
        is_sending <= 0;
        output_data_bit_counter <= 0;
        tx_shift_data <= 0;
        miso <= 0;
    end else begin
        tx_req_sync_1 <= tx_req_toggle_clk;
        tx_req_sync_2 <= tx_req_sync_1;

        if (cs) begin
            bit_counter <= 0;
            is_sending <= 0;
            output_data_bit_counter <= 0;
        end else if (is_sending) begin
            miso <= tx_shift_data[output_data_bit_counter];
            if (output_data_bit_counter == OUTPUT_DATA_BITS-1) begin
                is_sending <= 0;
                output_data_bit_counter <= 0;
                tx_ack_toggle_sclk <= tx_req_sync_2;
            end else begin
                output_data_bit_counter <= output_data_bit_counter + 1'b1;
            end
        end else if (tx_pending_sclk) begin
            tx_shift_data <= tx_data_clk;
            miso <= tx_data_clk[0];
            is_sending <= 1;
            output_data_bit_counter <= 1;
        end else begin
            data_buffer <= {mosi, data_buffer[`INSTRUCTION_WIDTH-1:1]};
            if (bit_counter == `INSTRUCTION_WIDTH-1) begin
                bit_counter <= 0;
                instr_data_sclk <= {mosi, data_buffer[`INSTRUCTION_WIDTH-1:1]};
                instr_req_toggle_sclk <= !instr_req_toggle_sclk;
            end else begin
                bit_counter <= bit_counter + 1'b1;
            end
        end
    end
end

// ---------------------------------------------------------------------------
// CLK domain: present one-cycle instruction pulses to the TPU and latch TPU
// result data until the SCLK domain acknowledges that it has been sent.
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        instr_req_sync_1 <= 0;
        instr_req_sync_2 <= 0;
        instruction_clk <= 0;
        data_ready <= 0;

        tx_data_clk <= 0;
        tx_req_toggle_clk <= 0;
        tx_ack_sync_1 <= 0;
        tx_ack_sync_2 <= 0;
    end else begin
        instr_req_sync_1 <= instr_req_toggle_sclk;
        instr_req_sync_2 <= instr_req_sync_1;

        tx_ack_sync_1 <= tx_ack_toggle_sclk;
        tx_ack_sync_2 <= tx_ack_sync_1;

        data_ready <= 0;
        if (instr_req_sync_1 != instr_req_sync_2) begin
            instruction_clk <= instr_data_sclk;
            data_ready <= 1;
        end

        if (ready_to_send && !tx_pending_clk) begin
            tx_data_clk <= data_in;
            tx_req_toggle_clk <= !tx_req_toggle_clk;
        end
    end
end

assign data_buffer_output = data_ready ? instruction_clk : 0;

endmodule
