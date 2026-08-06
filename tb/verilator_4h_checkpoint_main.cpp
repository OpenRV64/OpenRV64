#include <array>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>

#include "Vtb_4h_3p.h"
#include "Vtb_4h_3p___024root.h"
#include "verilated.h"
#include "verilated_save.h"

#ifndef OPENRV64_4H_CORE_INSTANCES
#define OPENRV64_4H_CORE_INSTANCES 4
#endif

namespace {

const char* plusarg_value(int argc, char** argv, const char* prefix) {
    const std::size_t prefix_length = std::strlen(prefix);
    for (int index = 1; index < argc; ++index) {
        if (std::strncmp(argv[index], prefix, prefix_length) == 0)
            return argv[index] + prefix_length;
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
                Vtb_4h_3p* top) {
    VerilatedSave stream;
    stream.open(path);
    if (!stream.isOpen()) {
        std::cerr << "Unable to open checkpoint for writing: " << path
                  << '\n';
        std::exit(EXIT_FAILURE);
    }
    stream << context;
    stream << *top;
    stream.close();
}

void restore_model(const char* path, VerilatedContext* context,
                   Vtb_4h_3p* top) {
    VerilatedRestore stream;
    stream.open(path);
    if (!stream.isOpen()) {
        std::cerr << "Unable to open checkpoint for reading: " << path
                  << '\n';
        std::exit(EXIT_FAILURE);
    }
    stream >> context;
    stream >> *top;
    stream.close();
}

struct HartMipSignals {
    bool csr_write;
    uint16_t csr_addr;
    uint64_t csr_wdata;
    uint64_t mip_sw;
};

void trace_l2_bus_request(const Vtb_4h_3p___024root* root,
                          uint32_t cycle) {
    if (!root->tb_4h_3p__DOT__bus_req_valid ||
        !root->tb_4h_3p__DOT__bus_req_ready ||
        root->tb_4h_3p__DOT__bus_req_size == 6)
        return;

    const unsigned mshr =
        root->tb_4h_3p__DOT__u_l2__DOT__bus_candidate_mshr_r;
    const unsigned waiter = mshr * 8;
    std::cout
        << "L2_SCALAR_BUS cycle=" << cycle
        << " write="
        << static_cast<unsigned>(root->tb_4h_3p__DOT__bus_req_write)
        << " addr=0x" << std::hex
        << root->tb_4h_3p__DOT__bus_req_addr
        << " size=" << std::dec
        << static_cast<unsigned>(root->tb_4h_3p__DOT__bus_req_size)
        << " cacheable="
        << static_cast<unsigned>(root->tb_4h_3p__DOT__bus_req_cacheable)
        << " action="
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__u_l2__DOT__bus_candidate_action_r)
        << " mshr=" << mshr
        << " state="
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__u_l2__DOT__mshr_state_q[mshr])
        << " bypass="
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__u_l2__DOT__mshr_bypass_q[mshr])
        << " mshr_cacheable="
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__u_l2__DOT__mshr_bus_cacheable_q[mshr])
        << " waiter=" << waiter
        << " hart="
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__u_l2__DOT__waiter_hart_id_q[waiter])
        << " source="
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__u_l2__DOT__waiter_source_id_q[waiter])
        << " op="
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__u_l2__DOT__waiter_op_q[waiter])
        << " lock="
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__u_l2__DOT__waiter_lock_q[waiter])
        << " waiter_size="
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__u_l2__DOT__waiter_size_q[waiter])
        << " waiter_addr=0x" << std::hex
        << root->tb_4h_3p__DOT__u_l2__DOT__waiter_addr_q[waiter]
        << " wstrb=0x"
        << root->tb_4h_3p__DOT__bus_req_wstrb
        << std::dec << '\n';
    std::cout.flush();
}

void trace_coherence_state(const Vtb_4h_3p___024root* root,
                           uint32_t cycle) {
#if OPENRV64_4H_CORE_INSTANCES == 1
    // The one-core specialization removes the coherent-home/probe cluster and
    // every hart-1 hierarchy.  Keep the optional four-hart replay trace out of
    // that generated model rather than referencing optimized-away symbols.
    (void)root;
    (void)cycle;
#else
    const uint64_t fetch_pc0 =
        static_cast<uint64_t>(root->tb_4h_3p__DOT__dbg_pc[0]) |
        (static_cast<uint64_t>(root->tb_4h_3p__DOT__dbg_pc[1]) << 32);
    const uint64_t fetch_pc1 =
        static_cast<uint64_t>(root->tb_4h_3p__DOT__dbg_pc[2]) |
        (static_cast<uint64_t>(root->tb_4h_3p__DOT__dbg_pc[3]) << 32);
    std::cout
        << "COHERENCE_REPLAY cycle=" << cycle
        << " retired="
        << root->tb_4h_3p__DOT__retired[0] << ','
        << root->tb_4h_3p__DOT__retired[1]
        << " pc=0x" << std::hex
        << root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__backend_retire_pc
        << ",0x"
        << root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__backend_retire_pc
        << " fetch=0x" << fetch_pc0 << ':'
        << root->tb_4h_3p__DOT__dbg_instr[0]
        << ",0x" << fetch_pc1 << ':'
        << root->tb_4h_3p__DOT__dbg_instr[1]
        << " hart_req=0x"
        << static_cast<unsigned>(root->tb_4h_3p__DOT__hart_req_valid)
        << "/0x"
        << static_cast<unsigned>(root->tb_4h_3p__DOT__hart_req_ready)
        << " hart_resp=0x"
        << static_cast<unsigned>(root->tb_4h_3p__DOT__hart_resp_valid)
        << " inv=0x"
        << static_cast<unsigned>(root->tb_4h_3p__DOT__l1d_invalidate_valid)
        << "/0x"
        << static_cast<unsigned>(root->tb_4h_3p__DOT__l1d_invalidate_ready)
        << " probe_pending=0x"
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__u_l2__DOT__g_coherent_home__DOT__u_probe_tracker__DOT__issue_pending_q)
        << "/0x"
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__u_l2__DOT__g_coherent_home__DOT__u_probe_tracker__DOT__ack_pending_q)
        << ":" << static_cast<unsigned>(
               root->tb_4h_3p__DOT__u_l2__DOT__g_coherent_home__DOT__u_probe_tracker__DOT__probe_id_q)
        << ':' << static_cast<unsigned>(
               root->tb_4h_3p__DOT__u_l2__DOT__g_coherent_home__DOT__u_probe_tracker__DOT__command_q)
        << ':' << static_cast<unsigned>(
               root->tb_4h_3p__DOT__u_l2__DOT__g_coherent_home__DOT__u_probe_tracker__DOT__cache_mask_q)
        << ":0x" << std::hex
        << root->tb_4h_3p__DOT__u_l2__DOT__g_coherent_home__DOT__u_probe_tracker__DOT__line_addr_q
        << " probe_resp=0x"
        << static_cast<unsigned>(root->tb_4h_3p__DOT__probe_resp_valid)
        << " endpoint=" << std::dec
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__u_probe_cluster__DOT__g_endpoint__BRA__0__KET____DOT__u_endpoint__DOT__invalidate_pending_q)
        << ':' << static_cast<unsigned>(
               root->tb_4h_3p__DOT__u_probe_cluster__DOT__g_endpoint__BRA__0__KET____DOT__u_endpoint__DOT__response_valid_q)
        << ':' << static_cast<unsigned>(
               root->tb_4h_3p__DOT__u_probe_cluster__DOT__g_endpoint__BRA__0__KET____DOT__u_endpoint__DOT__response_id_q)
        << ':' << root->tb_4h_3p__DOT__u_probe_cluster__DOT__g_endpoint__BRA__0__KET____DOT__u_endpoint__DOT__timeout_q
        << ','
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__u_probe_cluster__DOT__g_endpoint__BRA__1__KET____DOT__u_endpoint__DOT__invalidate_pending_q)
        << ':' << static_cast<unsigned>(
               root->tb_4h_3p__DOT__u_probe_cluster__DOT__g_endpoint__BRA__1__KET____DOT__u_endpoint__DOT__response_valid_q)
        << ':' << static_cast<unsigned>(
               root->tb_4h_3p__DOT__u_probe_cluster__DOT__g_endpoint__BRA__1__KET____DOT__u_endpoint__DOT__response_id_q)
        << ':' << root->tb_4h_3p__DOT__u_probe_cluster__DOT__g_endpoint__BRA__1__KET____DOT__u_endpoint__DOT__timeout_q
        << " l1d0=" << std::dec
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__backend_state_q)
        << ':'
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__store_buffer_count_q)
        << ":0x" << std::hex
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__demand_mshr_valid_vec)
        << ":0x"
        << root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__request_addr_q
        << " l1d1=" << std::dec
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__backend_state_q)
        << ':'
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__store_buffer_count_q)
        << ":0x" << std::hex
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__demand_mshr_valid_vec)
        << ":0x"
        << root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__request_addr_q
        << " l1i0=" << std::dec
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1i__DOT__u_l1i__DOT__u_l1__DOT__g_cache__DOT__u_cache__DOT__state_q)
        << ":0x" << std::hex
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1i__DOT__demand_mshr_valid_vec)
        << ':' << std::dec
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1i__DOT__response_count_q)
        << " l1i1="
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1i__DOT__u_l1i__DOT__u_l1__DOT__g_cache__DOT__u_cache__DOT__state_q)
        << ":0x" << std::hex
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1i__DOT__demand_mshr_valid_vec)
        << ':' << std::dec
        << static_cast<unsigned>(
               root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1i__DOT__response_count_q)
        << " l2=" << std::dec
        << static_cast<unsigned>(root->tb_4h_3p__DOT__u_l2__DOT__lookup_action_r)
        << ':'
        << static_cast<unsigned>(root->tb_4h_3p__DOT__u_l2__DOT__lookup_op_q)
        << ":0x" << std::hex
        << root->tb_4h_3p__DOT__u_l2__DOT__lookup_addr_q
        << " active_probe=" << std::dec
        << static_cast<unsigned>(root->tb_4h_3p__DOT__u_l2__DOT__active_probe_mshr_q)
        << " queues="
        << static_cast<unsigned>(root->tb_4h_3p__DOT__u_l2__DOT__cmd_count_q)
        << '/'
        << static_cast<unsigned>(root->tb_4h_3p__DOT__u_l2__DOT__response_count_q)
        << " mshr=";
    for (unsigned mshr = 0; mshr < 8; ++mshr) {
        if (mshr)
            std::cout << ',';
        std::cout
            << static_cast<unsigned>(
                   root->tb_4h_3p__DOT__u_l2__DOT__mshr_valid_q[mshr])
            << ':'
            << static_cast<unsigned>(
                   root->tb_4h_3p__DOT__u_l2__DOT__mshr_state_q[mshr])
            << ':'
            << static_cast<unsigned>(
                   root->tb_4h_3p__DOT__u_l2__DOT__mshr_post_probe_state_q[mshr])
            << ':'
            << static_cast<unsigned>(
                   root->tb_4h_3p__DOT__u_l2__DOT__mshr_coh_action_q[mshr])
            << ":0x" << std::hex
            << root->tb_4h_3p__DOT__u_l2__DOT__mshr_line_addr_q[mshr]
            << ":0x" << std::hex
            << static_cast<unsigned>(
                   root->tb_4h_3p__DOT__u_l2__DOT__mshr_probe_target_q[mshr])
            << "/0x"
            << static_cast<unsigned>(
                   root->tb_4h_3p__DOT__u_l2__DOT__mshr_probe_cache_mask_q[mshr])
            << std::dec;
    }
    std::cout
        << " bus="
        << static_cast<unsigned>(root->tb_4h_3p__DOT__bus_req_valid)
        << '/'
        << static_cast<unsigned>(root->tb_4h_3p__DOT__bus_req_ready)
        << '/'
        << static_cast<unsigned>(root->tb_4h_3p__DOT__bus_resp_valid)
        << " memory="
        << static_cast<unsigned>(root->tb_4h_3p__DOT__memory_pending)
        << ':' << root->tb_4h_3p__DOT__memory_delay
        << " ddr="
        << static_cast<unsigned>(root->tb_4h_3p__DOT__ddr_outstanding)
        << '\n';
    std::cout.flush();
#endif
}

void trace_hart0_l1i_state(const Vtb_4h_3p___024root* root,
                           uint32_t cycle) {
#define H0_BUS(name)                                                        \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__##name
#define H0_L1I(name)                                                       \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1i__DOT__##name
#define H0_CACHE(name)                                                     \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1i__DOT__u_l1i__DOT__u_l1__DOT__g_cache__DOT__u_cache__DOT__##name
    std::cout
        << "L1I_REPLAY cycle=" << cycle
        << " arb="
        << static_cast<unsigned>(H0_BUS(icx_cmd_grant_valid_q)) << ':'
        << static_cast<unsigned>(H0_BUS(icx_cmd_grant_client_q)) << ':'
        << static_cast<unsigned>(H0_BUS(icx_cmd_last_client_q))
        << ":req=" << static_cast<unsigned>(H0_BUS(l1d_icx_req_valid))
        << static_cast<unsigned>(H0_BUS(ptw_icx_req_valid))
        << static_cast<unsigned>(H0_BUS(l1i_icx_req_valid))
        << " bus="
        << static_cast<unsigned>(H0_BUS(fetch_head_q)) << ':'
        << static_cast<unsigned>(H0_BUS(fetch_tail_q))
        << ":state=";
    for (unsigned slot = 0; slot < 4; ++slot) {
        if (slot)
            std::cout << ',';
        std::cout
            << static_cast<unsigned>(H0_BUS(fetch_state_q)[slot])
            << ':' << static_cast<unsigned>(H0_BUS(fetch_cancelled_q)[slot])
            << ":0x" << std::hex << H0_BUS(fetch_vaddr_q)[slot]
            << std::dec;
    }
    std::cout
        << " bus_l1i="
        << static_cast<unsigned>(H0_BUS(l1i_req_active_q)) << ':'
        << static_cast<unsigned>(H0_BUS(fetch_l1i_launch)) << ':'
        << static_cast<unsigned>(H0_BUS(l1i_req_valid)) << ':'
        << static_cast<unsigned>(H0_BUS(l1i_req_fire)) << ':'
        << static_cast<unsigned>(H0_BUS(l1i_resp_valid)) << ':'
        << static_cast<unsigned>(H0_BUS(l1i_resp_tag))
        << " table=0x" << std::hex
        << static_cast<unsigned>(H0_L1I(response_valid_vec))
        << "/0x" << static_cast<unsigned>(H0_L1I(response_complete_vec))
        << "/0x" << static_cast<unsigned>(H0_L1I(response_prefetch_vec))
        << std::dec << ':'
        << static_cast<unsigned>(H0_L1I(response_count_q))
        << ":free=" << static_cast<unsigned>(H0_L1I(response_free_found_r))
        << ':' << static_cast<unsigned>(H0_L1I(response_free_index_r))
        << ":complete="
        << static_cast<unsigned>(H0_L1I(response_complete_found_r))
        << ':' << static_cast<unsigned>(H0_L1I(response_complete_index_r))
        << ":pop=" << static_cast<unsigned>(H0_L1I(response_pop))
        << ':' << static_cast<unsigned>(H0_L1I(response_pop_index))
        << " entries=";
    for (unsigned entry = 0; entry < 8; ++entry) {
        if (entry)
            std::cout << ',';
        std::cout
            << static_cast<unsigned>(H0_L1I(response_valid_q)[entry])
            << static_cast<unsigned>(H0_L1I(response_complete_q)[entry])
            << static_cast<unsigned>(H0_L1I(response_prefetch_q)[entry])
            << static_cast<unsigned>(H0_L1I(response_wait_mshr_q)[entry])
            << ':' << static_cast<unsigned>(H0_L1I(response_mshr_q)[entry])
            << ':' << static_cast<unsigned>(H0_L1I(response_tag_q)[entry])
            << ":0x" << std::hex << H0_L1I(response_vaddr_q)[entry]
            << std::dec;
    }
    std::cout
        << " mshr=0x" << std::hex
        << static_cast<unsigned>(H0_L1I(demand_mshr_valid_vec))
        << "/0x" << static_cast<unsigned>(H0_L1I(demand_mshr_issued_vec))
        << "/0x" << static_cast<unsigned>(H0_L1I(demand_mshr_complete_vec))
        << "/0x" << static_cast<unsigned>(H0_L1I(demand_mshr_fill_done_vec))
        << std::dec
        << ":issue=" << static_cast<unsigned>(H0_L1I(issue_active_q))
        << ':' << static_cast<unsigned>(H0_L1I(issue_mshr_q))
        << ':' << static_cast<unsigned>(H0_L1I(issue_index))
        << ":found="
        << static_cast<unsigned>(H0_L1I(demand_mshr_issue_found_r))
        << ':' << static_cast<unsigned>(H0_L1I(demand_mshr_issue_index_r))
        << ":fire=" << static_cast<unsigned>(H0_L1I(icx_issue_fire))
        << ":icx=" << static_cast<unsigned>(H0_BUS(l1i_icx_req_valid))
        << ":input=" << static_cast<unsigned>(H0_L1I(l1_input_valid))
        << ":miss=" << static_cast<unsigned>(H0_L1I(l1_miss_fire))
        << ":cache=" << static_cast<unsigned>(H0_CACHE(state_q))
        << ':' << static_cast<unsigned>(H0_CACHE(request_fire))
        << ':' << static_cast<unsigned>(H0_CACHE(response_valid_q))
        << ':' << static_cast<unsigned>(H0_CACHE(response_tag_q))
        << " lines=";
    for (unsigned mshr = 0; mshr < 4; ++mshr) {
        if (mshr)
            std::cout << ',';
        std::cout
            << static_cast<unsigned>(H0_L1I(demand_mshr_valid_q)[mshr])
            << static_cast<unsigned>(H0_L1I(demand_mshr_issued_q)[mshr])
            << static_cast<unsigned>(H0_L1I(demand_mshr_complete_q)[mshr])
            << static_cast<unsigned>(H0_L1I(demand_mshr_fill_done_q)[mshr])
            << static_cast<unsigned>(H0_L1I(demand_mshr_aged_q)[mshr])
            << ":0x" << std::hex << H0_L1I(demand_mshr_addr_q)[mshr]
            << std::dec;
    }
    std::cout << '\n';
    std::cout.flush();
#undef H0_CACHE
#undef H0_L1I
#undef H0_BUS
}

HartMipSignals hart_mip_signals(const Vtb_4h_3p___024root* root,
                                unsigned hart) {
    switch (hart) {
    case 0:
        return {
            static_cast<bool>(
                root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__backend_csr_write),
            root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__backend_csr_write_addr,
            root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__backend_csr_wdata,
            root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_csrs__DOT__mip_sw_q,
        };
#if OPENRV64_4H_CORE_INSTANCES >= 2
    case 1:
        return {
            static_cast<bool>(
                root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__backend_csr_write),
            root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__backend_csr_write_addr,
            root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__backend_csr_wdata,
            root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__u_csrs__DOT__mip_sw_q,
        };
#endif
    default:
        return {};
    }
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::debug(0);
    const std::unique_ptr<VerilatedContext> context{
        new VerilatedContext};
    const char* const verilator_threads_text =
        plusarg_value(argc, argv, "+verilator_threads=");
    const uint32_t verilator_threads = verilator_threads_text
        ? parse_cycle(verilator_threads_text, "+verilator_threads")
        : 1;
    if (verilator_threads == 0) {
        std::cerr << "+verilator_threads must be positive\n";
        return EXIT_FAILURE;
    }
    context->threads(verilator_threads);
    context->commandArgs(argc, argv);

    const std::unique_ptr<Vtb_4h_3p> top{
        new Vtb_4h_3p{context.get(), ""}};
    Vtb_4h_3p___024root* const rootp = top->rootp;
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
    const bool checkpoint_exit =
        has_plusarg(argc, argv, "+checkpoint_exit");
    const bool mip_trace = has_plusarg(argc, argv, "+mip_trace");
    const bool l2_bus_trace =
        has_plusarg(argc, argv, "+l2_bus_trace");
    const bool coherence_trace =
        has_plusarg(argc, argv, "+coherence_trace");
    const bool coherence_atomic_debug =
        has_plusarg(argc, argv, "+coherence_atomic_debug");
    const char* const coherence_trace_start_text =
        plusarg_value(argc, argv, "+coherence_trace_start=");
    const char* const coherence_trace_end_text =
        plusarg_value(argc, argv, "+coherence_trace_end=");
    const char* const coherence_trace_period_text =
        plusarg_value(argc, argv, "+coherence_trace_period=");

    if (checkpoint_cycles_text && !checkpoint_path) {
        std::cerr << "+checkpoint_cycles requires +checkpoint\n";
        return EXIT_FAILURE;
    }
    if (checkpoint_path && !checkpoint_cycles_text) {
        std::cerr << "+checkpoint requires +checkpoint_cycles\n";
        return EXIT_FAILURE;
    }

    const uint32_t checkpoint_cycle = checkpoint_path
        ? parse_cycle(checkpoint_cycles_text, "+checkpoint_cycles")
        : 0;
    const uint32_t stop_cycle = stop_cycles_text
        ? parse_cycle(stop_cycles_text, "+stop_cycles")
        : 0;
    const uint32_t coherence_trace_start = coherence_trace_start_text
        ? parse_cycle(coherence_trace_start_text,
                      "+coherence_trace_start")
        : 0;
    const uint32_t coherence_trace_end = coherence_trace_end_text
        ? parse_cycle(coherence_trace_end_text,
                      "+coherence_trace_end")
        : 0;
    const uint32_t coherence_trace_period = coherence_trace_period_text
        ? parse_cycle(coherence_trace_period_text,
                      "+coherence_trace_period")
        : 500;
    bool checkpoint_saved = false;

    if (coherence_trace && coherence_trace_period == 0) {
        std::cerr << "+coherence_trace_period must be positive\n";
        return EXIT_FAILURE;
    }

    if (restore_path) {
        restore_model(restore_path, context.get(), top.get());
        if (max_cycles_override_text) {
            top->rootp->tb_4h_3p__DOT__max_cycles =
                parse_cycle(max_cycles_override_text,
                            "+max_cycles_override");
            std::cout << "MAX CYCLES OVERRIDDEN value="
                      << top->rootp->tb_4h_3p__DOT__max_cycles << '\n';
        }
        std::cout << "CHECKPOINT RESTORED path=" << restore_path
                  << " cycle=" << top->checkpoint_cycle_o
                  << " time=" << context->time() << '\n';
    } else {
        top->checkpoint_clk_i = 0;
        top->eval();
    }

    uint8_t previous_clint_msip =
        top->rootp->tb_4h_3p__DOT__u_clint__DOT__msip_q;
    std::array<uint64_t, 2> previous_mip_sw{
        hart_mip_signals(top->rootp, 0).mip_sw,
        hart_mip_signals(top->rootp, 1).mip_sw,
    };
    if (mip_trace) {
        std::cout << "MIP_REPLAY_START cycle=" << top->checkpoint_cycle_o
                  << " clint_msip=0x" << std::hex
                  << static_cast<unsigned>(previous_clint_msip)
                  << " mip_sw0=0x" << previous_mip_sw[0]
                  << " mip_sw1=0x" << previous_mip_sw[1]
                  << std::dec << '\n';
    }

    while (VL_LIKELY(!context->gotFinish())) {
        if (l2_bus_trace && !top->checkpoint_clk_i)
            trace_l2_bus_request(top->rootp, top->checkpoint_cycle_o);
        context->timeInc(5);
        top->checkpoint_clk_i = !top->checkpoint_clk_i;
        top->eval();

        const uint32_t cycle = top->checkpoint_cycle_o;
        const bool coherence_trace_active = coherence_trace
            && cycle >= coherence_trace_start
            && (coherence_trace_end == 0 || cycle <= coherence_trace_end);
        rootp->tb_4h_3p__DOT__atomic_debug =
            coherence_trace_active && coherence_atomic_debug;
        if (coherence_trace_active && top->checkpoint_clk_i
            && (cycle % coherence_trace_period) == 0) {
            trace_coherence_state(rootp, cycle);
            trace_hart0_l1i_state(rootp, cycle);
        }
        if (mip_trace && top->checkpoint_clk_i) {
            const uint8_t clint_msip =
                top->rootp->tb_4h_3p__DOT__u_clint__DOT__msip_q;
            for (unsigned hart = 0;
                 hart < 2 && hart < OPENRV64_4H_CORE_INSTANCES;
                 ++hart) {
                const HartMipSignals signals =
                    hart_mip_signals(top->rootp, hart);
                const bool clint_changed =
                    ((clint_msip ^ previous_clint_msip) & (1U << hart)) != 0;
                const bool mip_sw_changed =
                    signals.mip_sw != previous_mip_sw[hart];
                const bool mip_write =
                    signals.csr_write && signals.csr_addr == 0x344;
                if (clint_changed || mip_sw_changed || mip_write) {
                    std::cout
                        << "MIP_REPLAY cycle=" << cycle
                        << " hart=" << hart
                        << " clint_msip="
                        << ((clint_msip >> hart) & 1U)
                        << " csr_write=" << mip_write
                        << " csr_addr=0x" << std::hex << signals.csr_addr
                        << " csr_wdata=0x" << signals.csr_wdata
                        << " mip_sw=0x" << signals.mip_sw
                        << " previous_mip_sw=0x" << previous_mip_sw[hart]
                        << std::dec << '\n';
                }
                previous_mip_sw[hart] = signals.mip_sw;
            }
            previous_clint_msip = clint_msip;
        }
        if (checkpoint_path && !checkpoint_saved
            && cycle >= checkpoint_cycle) {
            save_model(checkpoint_path, context.get(), top.get());
            checkpoint_saved = true;
            std::cout << "CHECKPOINT SAVED path=" << checkpoint_path
                      << " cycle=" << cycle
                      << " time=" << context->time() << '\n';
            std::cout.flush();
            if (checkpoint_exit)
                break;
        }

        if (stop_cycles_text && cycle >= stop_cycle) {
            std::cout << "SIMULATION STOP cycle=" << cycle
                      << " time=" << context->time() << '\n';
            break;
        }

    }

    if (checkpoint_path && !checkpoint_saved) {
        std::cerr << "Checkpoint cycle was not reached: target="
                  << checkpoint_cycle << " final="
                  << top->checkpoint_cycle_o << '\n';
        top->final();
        return EXIT_FAILURE;
    }

    top->final();
    context->statsPrintSummary();
    return EXIT_SUCCESS;
}
