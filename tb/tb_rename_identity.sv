`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"

module tb_rename_identity;

    reg [6*`RV64_REG_ADDR_WIDTH-1:0] source_arch;
    wire [6*`OPENRV64_PHYS_REG_ADDR_WIDTH-1:0] source_phys;
    reg [2:0] destination_valid;
    reg [3*`RV64_REG_ADDR_WIDTH-1:0] destination_arch;
    wire [3*`OPENRV64_PHYS_REG_ADDR_WIDTH-1:0] destination_new_phys;
    wire [3*`OPENRV64_PHYS_REG_ADDR_WIDTH-1:0] destination_old_phys;

    openrv64_rename_identity #(
        .ARCH_ADDR_WIDTH(`RV64_REG_ADDR_WIDTH),
        .ARCH_REG_COUNT(32),
        .PHYS_ADDR_WIDTH(`OPENRV64_PHYS_REG_ADDR_WIDTH),
        .PHYS_REG_COUNT(`OPENRV64_PHYS_REG_COUNT),
        .LANES(3),
        .SOURCES_PER_LANE(2)
    ) dut (
        .source_arch_i(source_arch),
        .source_phys_o(source_phys),
        .destination_valid_i(destination_valid),
        .destination_arch_i(destination_arch),
        .destination_new_phys_o(destination_new_phys),
        .destination_old_phys_o(destination_old_phys)
    );

    task automatic fail;
        input [8*96-1:0] message;
        begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    integer index;
    initial begin
        source_arch = {
            5'd31, 5'd0, 5'd19, 5'd8, 5'd2, 5'd1
        };
        destination_valid = 3'b101;
        destination_arch = {5'd27, 5'd12, 5'd4};
        #1;

        for (index = 0; index < 6; index = index + 1) begin
            if (source_phys[
                    index*`OPENRV64_PHYS_REG_ADDR_WIDTH +:
                    `OPENRV64_PHYS_REG_ADDR_WIDTH] !==
                {{(`OPENRV64_PHYS_REG_ADDR_WIDTH-`RV64_REG_ADDR_WIDTH)
                   {1'b0}},
                 source_arch[index*`RV64_REG_ADDR_WIDTH +:
                             `RV64_REG_ADDR_WIDTH]}) begin
                fail("source identity mapping changed the register number");
            end
        end

        if ((destination_new_phys[0 +:
                `OPENRV64_PHYS_REG_ADDR_WIDTH] != 6'd4) ||
            (destination_new_phys[`OPENRV64_PHYS_REG_ADDR_WIDTH +:
                `OPENRV64_PHYS_REG_ADDR_WIDTH] != 6'd12) ||
            (destination_new_phys[2*`OPENRV64_PHYS_REG_ADDR_WIDTH +:
                `OPENRV64_PHYS_REG_ADDR_WIDTH] != 6'd27)) begin
            fail("destination identity mapping changed the register number");
        end
        if (destination_old_phys != destination_new_phys) begin
            fail("identity old and new physical mappings diverged");
        end

        destination_valid = 3'b010;
        #1;
        if ((destination_new_phys != {5'd27, 5'd12, 5'd4}) ||
            (destination_old_phys != {5'd27, 5'd12, 5'd4})) begin
            fail("destination validity synthesized into identity mapping");
        end

        $display("PASS: identity rename source and destination tags");
        $finish;
    end

endmodule
