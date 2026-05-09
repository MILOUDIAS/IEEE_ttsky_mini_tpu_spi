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
    output wire [7:0]  result,   // upper bits zero-padded
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
    wire [1:0]                 array_output_row;
    wire [1:0]                 array_output_col;

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
        .array_output_row(array_output_row),
        .array_output_col(array_output_col),

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

    // ------------------------------------------------------------------
    // Output mux — selects one of NN accumulators using {row, col}.
    // Out-of-range row/col returns 0.
    // ------------------------------------------------------------------
    wire [`ACC_WIDTH-1:0] result_array [0:`NN-1];

    genvar i;
    generate
        for (i = 0; i < `NN; i = i + 1) begin : extract_results
            assign result_array[i] = array_data_out[`ACC_WIDTH*(i+1)-1:`ACC_WIDTH*i];
        end
    endgenerate

    wire [`ACC_WIDTH-1:0] selected =
        (array_output_row < `N && array_output_col < `N) ?
            result_array[array_output_row*`N + array_output_col] :
            {`ACC_WIDTH{1'b0}};

    // Drive the unused upper bits of `result` through a (* keep *)
    // flip-flop rather than a direct constant. Yosys would otherwise
    // tie them straight to sky130_fd_sc_hd__conb_1.LO, whose internal
    // pulldown to VGND causes magic to merge the corresponding output
    // pins with VGND in the layout extraction — and LVS rejects the
    // resulting "uo_out[7:4] shorted to VGND" mismatches.
    (* keep = "true" *) reg [7-`ACC_WIDTH:0] result_high_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) result_high_q <= {(8 - `ACC_WIDTH){1'b0}};
        else        result_high_q <= {(8 - `ACC_WIDTH){1'b0}};
    end

    assign result = { result_high_q, selected };

endmodule
