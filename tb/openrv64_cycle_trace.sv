`timescale 1ns/1ps

// Simulation sink for the synthesizable trace pins on openrv64_top. Enable it
// with +cycle-trace=<path>. The CSV is deliberately flat: Verilator, cocotb,
// and non-HDL tooling can consume the same schema without a waveform reader.
module openrv64_cycle_trace (
    input logic         clk,
    input logic         rst_n,
    input logic [63:0]  trace_cycle,
    input logic [4:0]   trace_valid,
    input logic [4:0]   trace_stall,
    input logic [4:0]   trace_flush,
    input logic [4:0]   trace_advance,
    input logic [319:0] trace_ids,
    input logic [319:0] trace_pcs,
    input logic [159:0] trace_instrs,
    input logic [7:0]   trace_events,
    input logic [7:0]   trace_stall_causes,
    input logic         trace_retire_valid,
    input logic         trace_retire_arch,
    input logic         trace_retire_exception,
    input logic [4:0]   trace_retire_cause,
    input logic [63:0]  trace_retire_next_pc,
    input logic         trace_retire_rd_write,
    input logic [4:0]   trace_retire_rd,
    input logic [63:0]  trace_retire_wdata
);

    integer trace_fd;
    string trace_path;

    initial begin
        trace_fd = 0;

        if ($value$plusargs("cycle-trace=%s", trace_path)) begin
            trace_fd = $fopen(trace_path, "w");

            if (trace_fd == 0) begin
                $fatal(1, "cannot open cycle trace: %0s", trace_path);
            end

            $fwrite(trace_fd,
                "schema,cycle,valid,stall,flush,advance,events,stall_causes,");
            $fwrite(trace_fd,
                "if_uid,if_pc,if_instr,id_uid,id_pc,id_instr,");
            $fwrite(trace_fd,
                "ex_uid,ex_pc,ex_instr,mem_uid,mem_pc,mem_instr,");
            $fwrite(trace_fd,
                "wb_uid,wb_pc,wb_instr,retire_valid,retire_arch,");
            $fwrite(trace_fd,
                "retire_exception,retire_cause,retire_next_pc,");
            $fwrite(trace_fd,
                "retire_rd_write,retire_rd,retire_wdata\n");
        end
    end

    always @(negedge clk) begin
        if (trace_fd != 0 && rst_n) begin
            $fwrite(trace_fd,
                "openrv64-cycle-v1,%0d,%02x,%02x,%02x,%02x,%02x,%02x,",
                trace_cycle, trace_valid, trace_stall, trace_flush,
                trace_advance, trace_events, trace_stall_causes);
            $fwrite(trace_fd,
                "%016x,%016x,%08x,%016x,%016x,%08x,",
                trace_ids[0*64 +: 64], trace_pcs[0*64 +: 64],
                trace_instrs[0*32 +: 32], trace_ids[1*64 +: 64],
                trace_pcs[1*64 +: 64], trace_instrs[1*32 +: 32]);
            $fwrite(trace_fd,
                "%016x,%016x,%08x,%016x,%016x,%08x,",
                trace_ids[2*64 +: 64], trace_pcs[2*64 +: 64],
                trace_instrs[2*32 +: 32], trace_ids[3*64 +: 64],
                trace_pcs[3*64 +: 64], trace_instrs[3*32 +: 32]);
            $fwrite(trace_fd,
                "%016x,%016x,%08x,%0d,%0d,%0d,%02x,%016x,%0d,%0d,%016x\n",
                trace_ids[4*64 +: 64], trace_pcs[4*64 +: 64],
                trace_instrs[4*32 +: 32], trace_retire_valid,
                trace_retire_arch, trace_retire_exception,
                trace_retire_cause, trace_retire_next_pc,
                trace_retire_rd_write, trace_retire_rd,
                trace_retire_wdata);
        end
    end

    final begin
        if (trace_fd != 0) begin
            $fclose(trace_fd);
        end
    end

endmodule
