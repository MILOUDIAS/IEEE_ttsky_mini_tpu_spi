`define INSTRUCTION_WIDTH 12
`define ACC_WIDTH  4
`define NN 9                   // N*N
`define BIT_COUNT 4
//`define 

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


reg [`INSTRUCTION_WIDTH-1:0] data_buffer;
reg [`BIT_COUNT-1:0] bit_counter;
reg [`BIT_COUNT-1:0] bit_counter_prev;
reg [$clog2(`ACC_WIDTH*`NN)-1:0] output_data_bit_counter; // Counter for bits in data_in
//reg [3:0] addr_counter;
reg data_ready;
reg is_sending;
reg reset_data;

//reg [`DATA_WIDTH-1:0] data_buffer;

always @(posedge sclk or negedge rst_n) begin
    if(!rst_n) begin
        data_buffer <= 0;
        bit_counter <= 0;
        output_data_bit_counter <= 0;
        miso <= 0;
        reset_data <= 0;
    end else begin
        // end
        if (bit_counter == `INSTRUCTION_WIDTH-1)
            bit_counter <= 0;
        if (!cs) begin
            if(is_sending) begin
                miso <= data_in[output_data_bit_counter];
                output_data_bit_counter <= output_data_bit_counter + 1;
            end
            data_buffer <= {mosi, data_buffer[`INSTRUCTION_WIDTH-1:1]}; // Shift in new bit
            // if (bit_counter == `INSTRUCTION_WIDTH) begin
            //     bit_counter <= 0; 
            // end else
            if (bit_counter <`INSTRUCTION_WIDTH-1)
                bit_counter <= bit_counter + 1;
            
        end else begin
            bit_counter <= 0;
            //data_ready <= 0;
            //is_sending <= 0;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        is_sending <= 0;
        data_ready <= 0;
        bit_counter_prev <= 0;
    end else begin
        bit_counter_prev <= bit_counter;
        if(ready_to_send && !cs) begin
            is_sending <= 1;
        end
        if(is_sending && output_data_bit_counter == `ACC_WIDTH*`NN) begin
            is_sending <= 0;
            //output_data_bit_counter <= 0;
        end
        // Pulse data_ready for exactly one clk cycle when bit_counter wraps
        // from MAX (= INSTRUCTION_WIDTH-1) back to 0, i.e. right after the
        // last bit of an instruction has been shifted in.
        if (bit_counter == 0 && bit_counter_prev == `INSTRUCTION_WIDTH-1) begin
            data_ready <= 1;
        end else begin
            data_ready <= 0;
        end
    end
end

assign data_buffer_output = (data_ready)? data_buffer : 0;
endmodule
