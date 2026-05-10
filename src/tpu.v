// Mini TPU top — 3x3 systolic array, 4-bit datapath
//
// Sized to fit a TinyTapeout 1x1 tile (160 x 100 um).

`timescale 1ns/1ps
`define DATA_WIDTH 4
`define ACC_WIDTH  4
`define INST_WIDTH 12
`define N 3
`define NN 9                   // N*N

module tpu (
    input wire clk,
    input wire rst_n,

    input wire  [`INST_WIDTH-1:0] instruction,
    output wire ready_to_send,
    output wire [`ACC_WIDTH*`NN-1:0]  array_data_out

);

    wire [`DATA_WIDTH-1:0] mema_data_in;
    wire                   mema_write_enable;
    wire [1:0]             mema_write_line;
    wire [1:0]             mema_write_elem;
    wire [`N-1:0]          mema_read_enable;
    wire [`N*2-1:0]        mema_read_elem;

    wire [`DATA_WIDTH-1:0] memb_data_in;
    wire                   memb_write_enable;
    wire [1:0]             memb_write_line;
    wire [1:0]             memb_write_elem;
    wire [`N-1:0]          memb_read_enable;
    wire [`N*2-1:0]        memb_read_elem;

    wire                       array_write_enable;
    wire [`DATA_WIDTH*`N-1:0]  array_a_in;
    wire [`DATA_WIDTH*`N-1:0]  array_b_in;

    array array_inst (
        .clk      (clk),
        .rst_n    (rst_n),
        .we       (array_write_enable),
        .a_in     (array_a_in),
        .b_in     (array_b_in),
        .data_out (array_data_out)
    );

    control control_unit (
        .clk(clk),
        .rst_n(rst_n),
        .instruction(instruction),

        .array_write_enable(array_write_enable),

        .mema_data_in(mema_data_in),
        .mema_write_enable(mema_write_enable),
        .mema_write_line(mema_write_line),
        .mema_write_elem(mema_write_elem),

        .memb_data_in(memb_data_in),
        .memb_write_enable(memb_write_enable),
        .memb_write_line(memb_write_line),
        .memb_write_elem(memb_write_elem),

        .mema_read_enable(mema_read_enable),
        .mema_read_elem(mema_read_elem),

        .memb_read_enable(memb_read_enable),
        .memb_read_elem(memb_read_elem),
        .ready_to_send(ready_to_send)
    );

    memory memory_a (
        .clk(clk),
        .rst_n(rst_n),
        .write_enable(mema_write_enable),
        .write_line(mema_write_line),
        .write_elem(mema_write_elem),
        .data_in(mema_data_in),
        .read_enable(mema_read_enable),
        .read_elem(mema_read_elem),
        .data_out(array_a_in)
    );

    memory memory_b (
        .clk(clk),
        .rst_n(rst_n),
        .write_enable(memb_write_enable),
        .write_line(memb_write_line),
        .write_elem(memb_write_elem),
        .data_in(memb_data_in),
        .read_enable(memb_read_enable),
        .read_elem(memb_read_elem),
        .data_out(array_b_in)
    );

endmodule
