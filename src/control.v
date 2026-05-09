// Control Unit of Mini TPU
// Memory A and Memory B share an identical read pattern, so the read
// signals are computed once and broadcast.

`define DATA_WIDTH 4
`define INST_LEN 12
`define N 3

module control (
    input wire clk,
    input wire rst_n,
    input wire [`INST_LEN-1:0] instruction,

    output wire array_write_enable,
    output reg  [1:0] array_output_row,
    output reg  [1:0] array_output_col,

    output wire [`DATA_WIDTH-1:0] mema_data_in,
    output wire mema_write_enable,
    output wire [1:0] mema_write_line,
    output wire [1:0] mema_write_elem,

    output wire [`DATA_WIDTH-1:0] memb_data_in,
    output wire memb_write_enable,
    output wire [1:0] memb_write_line,
    output wire [1:0] memb_write_elem,

    output wire [`N-1:0]   mema_read_enable,
    output wire [`N*2-1:0] mema_read_elem,

    output wire [`N-1:0]   memb_read_enable,
    output wire [`N*2-1:0] memb_read_elem,
    output reg ready_to_send
);

    // Counter holds enough range for the longest matmul drain time.
    // Total useful range is 1 .. 2N (inclusive), so 4 bits is plenty.
    reg [3:0] counter;

    wire [1:0] opcode     = instruction[`INST_LEN-1:`INST_LEN-2];
    wire       mem_select = instruction[`INST_LEN-3];
    wire [1:0] row        = instruction[`INST_LEN-5:`INST_LEN-6];
    wire [1:0] col        = instruction[`INST_LEN-7:`INST_LEN-8];
    wire [`DATA_WIDTH-1:0] imm = instruction[`DATA_WIDTH-1:0];

    localparam LOAD  = 2'b10;
    localparam STORE = 2'b11;
    localparam RUN   = 2'b01;

    wire is_load  = (opcode == LOAD);
    wire is_run   = (opcode == RUN || counter > 0);
    wire is_store = (opcode == STORE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
        begin
            counter <= 4'd0;
            ready_to_send <= 0;
        end
        else if (counter == 2*`N + 1) begin
            counter <= 0;
            ready_to_send <= 1;
        end
        else if (is_run)
            counter <= counter + 1'b1;
        else
            ready_to_send <= 0;
    end

    // ------------------------------------------------------------------
    // Shared read pattern.
    // For row i, output is enabled when counter is in [i+1, i+N], and
    // the column selector walks 0,1,...,N-1 across those cycles.
    // ------------------------------------------------------------------
    wire [`N-1:0]   read_enable_shared;
    wire [`N*2-1:0] read_elem_shared;

    genvar i;
    generate
        for (i = 0; i < `N; i = i + 1) begin : read_pattern_gen
            assign read_enable_shared[i] = (counter > i) && (counter < (i + `N + 1));
            assign read_elem_shared[(i*2)+:2] =
                (counter == (i + 1)) ? 2'd0 :
                (counter == (i + 2)) ? 2'd1 :
                (counter == (i + 3)) ? 2'd2 : 2'd0;
        end
    endgenerate

    assign mema_read_enable = read_enable_shared;
    assign memb_read_enable = read_enable_shared;
    assign mema_read_elem   = read_elem_shared;
    assign memb_read_elem   = read_elem_shared;

    // ------------------------------------------------------------------
    // Write path.
    // ------------------------------------------------------------------
    wire load_a = is_load && !mem_select;
    wire load_b = is_load &&  mem_select;

    assign mema_data_in      = load_a ? imm : {`DATA_WIDTH{1'b0}};
    assign memb_data_in      = load_b ? imm : {`DATA_WIDTH{1'b0}};

    assign mema_write_enable = load_a;
    assign memb_write_enable = load_b;

    assign mema_write_line   = load_a ? row : 2'b00;
    assign mema_write_elem   = load_a ? col : 2'b00;

    assign memb_write_line   = load_b ? row : 2'b00;
    assign memb_write_elem   = load_b ? col : 2'b00;

    // Latch the STORE row/col on each STORE instruction so that the result
    // mux holds a stable value between SPI transactions. The SPI's
    // data_ready is a single-cycle pulse, so without latching the result
    // would only be valid for one clk cycle per STORE.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            array_output_row <= 2'b00;
            array_output_col <= 2'b00;
        end else if (is_store) begin
            array_output_row <= row;
            array_output_col <= col;
        end
    end

    assign array_write_enable  = is_run;

endmodule
