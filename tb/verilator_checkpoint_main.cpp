#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
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

}  // namespace

int main(int argc, char** argv, char**) {
    Verilated::debug(0);
    const std::unique_ptr<VerilatedContext> context{new VerilatedContext};
    context->threads(1);
    context->commandArgs(argc, argv);

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
        reopen_restored_traces(argc, argv, top.get());
        std::cout << "CHECKPOINT RESTORED path=" << restore_path
                  << " cycle=" << top->checkpoint_cycle_o
                  << " time=" << context->time() << '\n';
    } else {
        top->checkpoint_clk_i = 0;
        top->eval();
    }

    bool checkpoint_saved = false;
    while (VL_LIKELY(!context->gotFinish())) {
        context->timeInc(5);
        top->checkpoint_clk_i = !top->checkpoint_clk_i;
        top->eval();

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
