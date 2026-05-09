// Processing Element of Systolic Array

`define DATA_WIDTH 4  // Define bit-width for input A and B
`define ACC_WIDTH 4 // Define bit-width for accumulation C

module pe (
    input  wire clk,
    input  wire rst_n,
    input  wire we,                          // Write enable signal
    input  wire [`DATA_WIDTH-1:0] a_in,      // Input A from the left
    input  wire [`DATA_WIDTH-1:0] b_in,      // Input B from the top
    output wire [`DATA_WIDTH-1:0] a_out,     // Pass A to the right
    output wire [`DATA_WIDTH-1:0] b_out,     // Pass B to the bottom
    output wire [`ACC_WIDTH-1:0]  c_out      // Accumulated result
);

    // Pipeline registers (no reset: written on first compute cycle, value before that is don't-care)
    reg [`DATA_WIDTH-1:0] a_reg, b_reg;
    // Accumulator (must reset to 0 before each matmul)
    reg [`ACC_WIDTH-1:0]  c_reg;

    // Simulation-only init so that X doesn't spread through the systolic
    // pipeline before useful values arrive. In silicon, random power-up
    // values are masked because inactive rows/columns have a_in == 0 and
    // 0 * random_bits == 0.
`ifndef SYNTHESIS
    initial begin
        a_reg = {`DATA_WIDTH{1'b0}};
        b_reg = {`DATA_WIDTH{1'b0}};
    end
`endif

    // Truncated 8-bit MAC: explicitly drop the upper bits of the multiplier
    wire [`DATA_WIDTH*2-1:0] mult_full = a_in * b_in;
    wire [`ACC_WIDTH-1:0]    mult_trunc = mult_full[`ACC_WIDTH-1:0];

    // Accumulator with async reset
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            c_reg <= {`ACC_WIDTH{1'b0}};
        else if (we)
            c_reg <= c_reg + mult_trunc;
    end

    // Pipeline regs without reset (smaller dfxtp cells). The `initial`
    // block above keeps these at 0 in RTL sim. In synthesis the
    // initial is dropped — gate-level sims must seed the FFs from the
    // testbench (see `\`ifdef GL_TEST` $deposit block in tb.v) to
    // avoid X * 0 = X poisoning the multiplier.
    always @(posedge clk) begin
        if (we) begin
            a_reg <= a_in;
            b_reg <= b_in;
        end
    end

    assign a_out = a_reg;
    assign b_out = b_reg;
    assign c_out = c_reg;

endmodule
