`timescale 1ns/1ps

// Glitch-free clock-gating boundary.
//
// The generic implementation is the canonical latch-and-AND ICG pattern.
// ASIC synthesis must map this module to the target library's integrated
// clock-gating cell.  FPGA builds must replace it with the target clock-enable
// primitive rather than implementing clk_o through ordinary fabric logic.
// Keeping the gate behind one module gives those flows a stable mapping seam.
module openrv64_clock_gate (
    input  wire clk_i,
    input  wire rst_ni,
    input  wire enable_i,
    input  wire test_enable_i,
    output wire clk_o,
    output wire enable_latched_o
);

    (* clock_gating_cell = "yes" *) reg enable_latched_q;

    // The enable may change only while the source clock is low.  Reset keeps
    // the destination clock running so every gated-domain register observes
    // its reset assertion and release sequence.
    always_latch begin
        if (!rst_ni)
            enable_latched_q = 1'b1;
        else if (!clk_i)
            enable_latched_q = enable_i || test_enable_i;
    end

    assign clk_o = clk_i && enable_latched_q;
    assign enable_latched_o = enable_latched_q;

endmodule
