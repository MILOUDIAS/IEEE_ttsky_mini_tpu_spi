`define INST_LEN 12
`define NN 9                   // N*N
`define ACC_WIDTH  4


module tpu_interface(
    input wire clk,
    input wire rst_n,
    
    // spi pins
    input wire mosi,
    input wire cs,
    input wire sclk,

    output wire miso
);

wire [`ACC_WIDTH*`NN-1:0]  array_data_out;
wire  [`INST_LEN-1:0] instruction;
wire ready_to_send;

tpu uut_tpu (
    .clk(clk),
    .rst_n(rst_n),
    .instruction(instruction),
    .ready_to_send(ready_to_send),
    .array_data_out(array_data_out)
);

spi uut_spi (
    .clk(clk),
    .rst_n(rst_n),
    .mosi(mosi),
    .cs(cs),
    .sclk(sclk),
    .data_buffer_output(instruction),
    .ready_to_send(ready_to_send),
    .miso(miso),
    .data_in(array_data_out)

);

endmodule
