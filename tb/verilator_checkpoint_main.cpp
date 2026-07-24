#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <string>

#include "Vtb_opensbi.h"
#include "Vtb_opensbi___024root.h"
#include "verilated.h"
#include "verilated_save.h"

namespace {

const char* plusarg_value(int argc, char** argv, const char* prefix) {
    const std::size_t prefix_len = std::strlen(prefix);
    for (int index = 1; index < argc; ++index) {
        if (std::strncmp(argv[index], prefix, prefix_len) == 0)
            return argv[index] + prefix_len;
    }
    return nullptr;
}

bool has_plusarg(int argc, char** argv, const char* name) {
    for (int index = 1; index < argc; ++index) {
        if (std::strcmp(argv[index], name) == 0)
            return true;
    }
    return false;
}

uint32_t parse_cycle(const char* text, const char* option) {
    if (!text || !*text) {
        std::cerr << "Missing " << option << " value\n";
        std::exit(EXIT_FAILURE);
    }

    errno = 0;
    char* end = nullptr;
    const unsigned long long value = std::strtoull(text, &end, 0);
    if (errno != 0 || !end || *end != '\0'
        || value > std::numeric_limits<uint32_t>::max()) {
        std::cerr << "Invalid " << option << " value: " << text << '\n';
        std::exit(EXIT_FAILURE);
    }
    return static_cast<uint32_t>(value);
}

void save_model(const char* path, VerilatedContext* context,
                Vtb_opensbi* top) {
    VerilatedSave stream;
    stream.open(path);
    if (!stream.isOpen()) {
        std::cerr << "Unable to open checkpoint for writing: " << path << '\n';
        std::exit(EXIT_FAILURE);
    }
    stream << context;
    stream << *top;
    stream.close();
}

void restore_model(const char* path, VerilatedContext* context,
                   Vtb_opensbi* top) {
    VerilatedRestore stream;
    stream.open(path);
    if (!stream.isOpen()) {
        std::cerr << "Unable to open checkpoint for reading: " << path << '\n';
        std::exit(EXIT_FAILURE);
    }
    stream >> context;
    stream >> *top;
    stream.close();
}

void reopen_trace(const char* path, const char* name, std::string& model_path,
                  IData& model_fd) {
    if (!path)
        return;
    model_path = path;
    model_fd = VL_FOPEN_NN(model_path, "w");
    if (model_fd == 0) {
        std::cerr << "Unable to open restored " << name
                  << " trace: " << path << '\n';
        std::exit(EXIT_FAILURE);
    }
    std::cout << "TRACE OPENED name=" << name << " path=" << path << '\n';
}

void reopen_restored_traces(int argc, char** argv, Vtb_opensbi* top) {
    Vtb_opensbi___024root* const root = top->rootp;
    reopen_trace(plusarg_value(argc, argv, "+instruction_trace="),
                 "instruction", root->tb_opensbi__DOT__instruction_trace_path,
                 root->tb_opensbi__DOT__instruction_trace_fd);
    reopen_trace(plusarg_value(argc, argv, "+lsu_trace="), "lsu",
                 root->tb_opensbi__DOT__lsu_trace_path,
                 root->tb_opensbi__DOT__lsu_trace_fd);
    reopen_trace(plusarg_value(argc, argv, "+ccx_trace="), "ccx",
                 root->tb_opensbi__DOT__ccx_trace_path,
                 root->tb_opensbi__DOT__ccx_trace_fd);
}

template <std::size_t Words>
uint64_t wide_bits64(const VlWide<Words>& value, unsigned lsb) {
    const unsigned word = lsb / 32;
    const unsigned shift = lsb % 32;
    uint64_t result = static_cast<uint64_t>(value[word]) >> shift;
    if (word + 1 < Words)
        result |= static_cast<uint64_t>(value[word + 1]) << (32 - shift);
    if (shift != 0 && word + 2 < Words)
        result |= static_cast<uint64_t>(value[word + 2]) << (64 - shift);
    return result;
}

void write_pipeline_trace(std::ostream& stream, Vtb_opensbi* top) {
    Vtb_opensbi___024root* const root = top->rootp;

#define CORE3P(name) \
    root->tb_opensbi__DOT__dut__DOT__u_core__DOT__g_backend_3p__DOT__u_core_3p__DOT__##name
#define BACKEND3P(name) CORE3P(u_backend__DOT__##name)
#define WINDOW3P(name) \
    BACKEND3P(u_dispatch__DOT__g_3p__DOT__u_window__DOT__##name)
#define RETIRE3P(name) BACKEND3P(u_retire_queue__DOT__##name)
#define FETCH3P(name) \
    CORE3P(g_fetch_axi__DOT__u_fetch__DOT__##name)
#define BUS3P(name) \
    CORE3P(u_bus__DOT__g_ccx__DOT__u_bus__DOT__##name)

    const auto& trace_pcs =
        root->tb_opensbi__DOT__dut__DOT__u_core__DOT__three_trace_pcs;
    const auto& trace_instrs =
        root->tb_opensbi__DOT__dut__DOT__u_core__DOT__three_trace_instrs;
    unsigned retire_valid = 0;
    unsigned retire_complete = 0;
    unsigned window_valid = 0;
    unsigned window_issued = 0;
    for (unsigned index = 0; index < 16; ++index) {
        retire_valid |= (RETIRE3P(valid_q)[index] & 1U) << index;
        retire_complete |= (RETIRE3P(complete_q)[index] & 1U) << index;
        window_valid |= (WINDOW3P(valid_q)[index] & 1U) << index;
        window_issued |= (WINDOW3P(issued_q)[index] & 1U) << index;
    }

    stream << std::dec << "cycle=" << top->checkpoint_cycle_o
           << std::hex << std::setfill('0')
           << " valid=" << std::setw(2)
           << static_cast<unsigned>(CORE3P(trace_valid_raw))
           << " advance=" << std::setw(2)
           << static_cast<unsigned>(CORE3P(trace_advance_raw))
           << " flush=" << std::setw(2)
           << static_cast<unsigned>(CORE3P(trace_flush_raw))
           << " stall=" << std::setw(2)
           << static_cast<unsigned>(
                  root->tb_opensbi__DOT__dut__DOT__u_core__DOT__three_trace_stall)
           << " causes=" << std::setw(2)
           << static_cast<unsigned>(CORE3P(trace_stall_causes_raw));
    for (unsigned stage = 0; stage < 5; ++stage) {
        stream << " s" << stage << '=' << std::setw(16)
               << wide_bits64(trace_pcs, stage * 64) << '/'
               << std::setw(8)
               << static_cast<uint32_t>(
                      wide_bits64(trace_instrs, stage * 32));
    }
    stream << " branch=" << static_cast<unsigned>(CORE3P(branch_resolved))
           << '/' << static_cast<unsigned>(CORE3P(branch_taken))
           << " redirect="
           << static_cast<unsigned>(CORE3P(control_redirect))
           << " bp_redirect="
           << static_cast<unsigned>(CORE3P(bp_predict_redirect))
           << " fetch=" << static_cast<unsigned>(CORE3P(fetch_decode_valid))
           << " fetchq="
           << static_cast<unsigned>(CORE3P(fetch_pipe_req_valid))
           << '/' << static_cast<unsigned>(CORE3P(fetch_pipe_req_ready))
           << '/' << static_cast<unsigned>(CORE3P(fetch_pipe_resp_valid))
           << " decode=" << static_cast<unsigned>(CORE3P(backend_decode_valid))
           << " alloc=" << static_cast<unsigned>(BACKEND3P(allocation_valid))
           << " complete=" << static_cast<unsigned>(BACKEND3P(complete_valid))
           << " qret=" << static_cast<unsigned>(BACKEND3P(queue_retire_valid))
           << '/' << static_cast<unsigned>(BACKEND3P(queue_retire_accept))
           << std::dec
           << " rq=" << static_cast<unsigned>(RETIRE3P(head_q)) << ':'
           << static_cast<unsigned>(RETIRE3P(tail_q)) << ':'
           << static_cast<unsigned>(RETIRE3P(count_q))
           << " rid=" << static_cast<unsigned>(RETIRE3P(next_retire_id_q))
           << " aid=" << static_cast<unsigned>(RETIRE3P(next_alloc_id_q))
           << std::hex
           << " rv=" << std::setw(4) << retire_valid
           << " rc=" << std::setw(4) << retire_complete
           << " wv=" << std::setw(4) << window_valid
           << " wi=" << std::setw(4) << window_issued;
    stream << " fe{active=" << std::dec
           << static_cast<unsigned>(FETCH3P(active_q))
           << ",pc=" << std::hex << std::setw(16)
           << static_cast<uint64_t>(FETCH3P(consume_pc_q))
           << ",pending=" << std::dec
           << static_cast<unsigned>(FETCH3P(pending_valid_q))
           << '/' << std::hex << std::setw(16)
           << static_cast<uint64_t>(FETCH3P(pending_addr_q))
           << ",line0=" << std::dec
           << static_cast<unsigned>(FETCH3P(line_valid_q)[0])
           << '/' << std::hex << std::setw(16)
           << static_cast<uint64_t>(FETCH3P(line_addr_q)[0])
           << '/' << static_cast<unsigned>(
                      FETCH3P(line_sector_valid_q)[0])
           << ",line1=" << std::dec
           << static_cast<unsigned>(FETCH3P(line_valid_q)[1])
           << '/' << std::hex << std::setw(16)
           << static_cast<uint64_t>(FETCH3P(line_addr_q)[1])
           << '/' << static_cast<unsigned>(
                      FETCH3P(line_sector_valid_q)[1])
           << ",hit=" << static_cast<unsigned>(
                      FETCH3P(consume_line_tag_hit))
           << '/' << static_cast<unsigned>(
                      FETCH3P(following_line_tag_hit))
           << ",lanes=" << static_cast<unsigned>(FETCH3P(lane_found_r))
           << ",reqfire=" << static_cast<unsigned>(FETCH3P(req_fire))
           << ",respmatch=" << static_cast<unsigned>(FETCH3P(resp_match))
           << ",pair=" << static_cast<unsigned>(
                      FETCH3P(pair_predicted_valid_q))
           << '/' << static_cast<unsigned>(
                      FETCH3P(pair_unpredicted_valid_q))
           << '}';
    stream << " bus{fq=" << std::dec
           << static_cast<unsigned>(BUS3P(fetch_head_q)) << ':'
           << static_cast<unsigned>(BUS3P(fetch_tail_q)) << ':'
           << static_cast<unsigned>(BUS3P(fetch_count_q))
           << ",pop=" << static_cast<unsigned>(BUS3P(fetch_pop))
           << ",l1slot="
           << static_cast<unsigned>(BUS3P(l1i_slot_head_q)) << ':'
           << static_cast<unsigned>(BUS3P(l1i_slot_tail_q)) << ':'
           << static_cast<unsigned>(BUS3P(l1i_slot_count_q))
           << ",l1req="
           << static_cast<unsigned>(BUS3P(l1i_req_active_q)) << '/'
           << static_cast<unsigned>(BUS3P(l1i_req_valid)) << '/'
           << static_cast<unsigned>(BUS3P(l1i_req_fire))
           << ",l1resp="
           << static_cast<unsigned>(BUS3P(l1i_resp_valid)) << '/'
           << static_cast<unsigned>(BUS3P(l1i_resp_fire))
           << ",launch="
           << static_cast<unsigned>(BUS3P(fetch_l1i_launch));
    for (unsigned index = 0; index < 4; ++index) {
        stream << ",f" << index << '='
               << static_cast<unsigned>(BUS3P(fetch_state_q)[index])
               << '/' << std::hex << std::setw(16)
               << static_cast<uint64_t>(BUS3P(fetch_vaddr_q)[index])
               << '/' << std::dec
               << static_cast<unsigned>(BUS3P(fetch_stash_q)[index])
               << static_cast<unsigned>(BUS3P(fetch_demand_q)[index])
               << static_cast<unsigned>(BUS3P(fetch_cancelled_q)[index])
               << "/ls" << static_cast<unsigned>(
                      BUS3P(l1i_slot_q)[index]);
    }
    stream << '}';

    for (unsigned index = 0; index < 16; ++index) {
        if (!WINDOW3P(valid_q)[index])
            continue;
        const auto& payload = WINDOW3P(payload_q)[index];
        stream << " w" << std::dec << index
               << "{id=" << static_cast<unsigned>(WINDOW3P(id_q)[index])
               << ",pc=" << std::hex << std::setw(16)
               << wide_bits64(payload, 274)
               << ",insn=" << std::setw(8)
               << static_cast<uint32_t>(wide_bits64(payload, 242))
               << ",i=" << static_cast<unsigned>(WINDOW3P(issued_q)[index])
               << ",r1=" << static_cast<unsigned>(
                      WINDOW3P(src1_ready_q)[index])
               << '/' << static_cast<unsigned>(
                      WINDOW3P(src1_producer_valid_q)[index])
               << '/' << std::dec
               << static_cast<unsigned>(WINDOW3P(src1_tag_q)[index])
               << ",r2=" << static_cast<unsigned>(
                      WINDOW3P(src2_ready_q)[index])
               << '/' << static_cast<unsigned>(
                      WINDOW3P(src2_producer_valid_q)[index])
               << '/' << static_cast<unsigned>(
                      WINDOW3P(src2_tag_q)[index])
               << '}';
    }
    stream << '\n';

#undef RETIRE3P
#undef WINDOW3P
#undef BACKEND3P
#undef FETCH3P
#undef BUS3P
#undef CORE3P
}

}  // namespace

int main(int argc, char** argv, char**) {
    Verilated::debug(0);
    const std::unique_ptr<VerilatedContext> context{new VerilatedContext};
    const char* const verilator_threads_text =
        plusarg_value(argc, argv, "+verilator_threads=");
    const uint32_t verilator_threads =
        verilator_threads_text
            ? parse_cycle(verilator_threads_text, "+verilator_threads")
            : 1;
    if (verilator_threads == 0) {
        std::cerr << "+verilator_threads must be positive\n";
        return EXIT_FAILURE;
    }
    context->threads(verilator_threads);
    context->commandArgs(argc, argv);
    std::cout << "VERILATOR THREADS value=" << verilator_threads << '\n';

    const std::unique_ptr<Vtb_opensbi> top{
        new Vtb_opensbi{context.get(), ""}};

    const char* const restore_path =
        plusarg_value(argc, argv, "+restore=");
    const char* const checkpoint_path =
        plusarg_value(argc, argv, "+checkpoint=");
    const char* const checkpoint_cycles_text =
        plusarg_value(argc, argv, "+checkpoint_cycles=");
    const char* const stop_cycles_text =
        plusarg_value(argc, argv, "+stop_cycles=");
    const char* const max_cycles_override_text =
        plusarg_value(argc, argv, "+max_cycles_override=");
    const char* const pipeline_trace_path =
        plusarg_value(argc, argv, "+pipeline_trace=");
    const bool checkpoint_exit =
        has_plusarg(argc, argv, "+checkpoint_exit");
    const uint32_t checkpoint_cycle =
        checkpoint_path
            ? parse_cycle(checkpoint_cycles_text, "+checkpoint_cycles")
            : 0;
    const uint32_t stop_cycle =
        stop_cycles_text ? parse_cycle(stop_cycles_text, "+stop_cycles") : 0;

    if (restore_path) {
        restore_model(restore_path, context.get(), top.get());
        if (max_cycles_override_text) {
            top->rootp->tb_opensbi__DOT__max_cycles =
                parse_cycle(max_cycles_override_text,
                            "+max_cycles_override");
            std::cout << "MAX CYCLES OVERRIDDEN value="
                      << top->rootp->tb_opensbi__DOT__max_cycles << '\n';
        }
        reopen_restored_traces(argc, argv, top.get());
        std::cout << "CHECKPOINT RESTORED path=" << restore_path
                  << " cycle=" << top->checkpoint_cycle_o
                  << " time=" << context->time() << '\n';
    } else {
        top->checkpoint_clk_i = 0;
        top->eval();
    }

    std::ofstream pipeline_trace;
    if (pipeline_trace_path) {
        pipeline_trace.open(pipeline_trace_path);
        if (!pipeline_trace) {
            std::cerr << "Unable to open pipeline trace: "
                      << pipeline_trace_path << '\n';
            return EXIT_FAILURE;
        }
        std::cout << "TRACE OPENED name=pipeline path="
                  << pipeline_trace_path << '\n';
    }

    bool checkpoint_saved = false;
    while (VL_LIKELY(!context->gotFinish())) {
        context->timeInc(5);
        top->checkpoint_clk_i = !top->checkpoint_clk_i;
        top->eval();
        if (pipeline_trace && top->checkpoint_clk_i)
            write_pipeline_trace(pipeline_trace, top.get());

        if (checkpoint_path && !checkpoint_saved
            && top->checkpoint_cycle_o >= checkpoint_cycle) {
            save_model(checkpoint_path, context.get(), top.get());
            checkpoint_saved = true;
            std::cout << "CHECKPOINT SAVED path=" << checkpoint_path
                      << " cycle=" << top->checkpoint_cycle_o
                      << " time=" << context->time() << '\n';
            if (checkpoint_exit)
                break;
        }

        if (stop_cycles_text && top->checkpoint_cycle_o >= stop_cycle) {
            std::cout << "SIMULATION STOP cycle=" << top->checkpoint_cycle_o
                      << " time=" << context->time() << '\n';
            break;
        }
    }

    if (!context->gotFinish() && !checkpoint_exit) {
        VL_DEBUG_IF(VL_PRINTF(
            "+ Exiting without $finish; no events left\n"););
    }

    top->final();
    context->statsPrintSummary();
    return 0;
}
