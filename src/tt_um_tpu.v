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


// Drive the unused/constant output pins through (* keep *)-attributed
// flip-flops rather than direct constant assigns. Yosys would otherwise
// tie them straight to a `sky130_fd_sc_hd__conb_1.LO` cell, whose
// internal pulldown to VGND causes magic's spice extraction to merge
// the pin nets with VGND — and the resulting electrical shorts make
// LVS report dozens of unmatched-pin errors. With (* keep *) the
// registers survive synthesis as real dfrtp cells driving each pin.
(* keep = "true" *) reg [6:0] uio_oe_high_q;
(* keep = "true" *) reg [6:0] uio_out_high_q;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        uio_oe_high_q  <= 7'b0;
        uio_out_high_q <= 7'b0;
    end else begin
        uio_oe_high_q  <= 7'b0;
        uio_out_high_q <= 7'b0;
    end
end

assign uio_oe[0]    = 1'b1;            // MISO output enable (constant 1)
assign uio_oe[7:1]  = uio_oe_high_q;   // unused; held at 0 by FFs
assign uio_out[7:1] = uio_out_high_q;  // unused; held at 0 by FFs


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
