/*
 * Copyright (c) 2025 Dennis Du and Rick Gao
 * SPDX-License-Identifier: Apache-2.0
 */


module tt_um_tpu (
`ifdef USE_POWER_PINS
    inout VPWR,                 // 1.8V power supply (analog inout)
    inout VGND,                 // ground (analog inout)
`endif
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high)
    input  wire       ena,      // always 1 when the design is powered
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);


assign uio_oe[0] = 1; // Enable MISO output
assign uio_oe[7:1] = 0; // Disable other outputs

assign uio_out[7:1] = 0; // Set unused outputs to 0


tpu_interface uut_tpu_interface(
    .clk(clk),
    .rst_n(rst_n),
    
    // spi pins
    .mosi(ui_in[0]), // Assuming MOSI is connected to uio_in[0]
    .cs(ui_in[1]),   // Assuming CS is connected to uio_in[1]
    .sclk(ui_in[2]), // Assuming SCLK is connected to uio_in[2]

    .miso(uio_out[0]), // Assuming MISO is connected to uio_out[0]

    // tpu wire
    .result(uo_out)
);
wire _unused = &{ui_in[7:3], uio_in[7:0], ena}; // Prevent unused signal warnings

endmodule
