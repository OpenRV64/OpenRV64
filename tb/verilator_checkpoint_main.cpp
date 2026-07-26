#include <array>
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

struct L2TlbProbe {
    static constexpr unsigned kWays = 4;
    static constexpr unsigned kSets = 64;
    static constexpr uint64_t kField52Mask = (UINT64_C(1) << 52) - 1;

    struct EntryOrigin {
        bool known = false;
        uint64_t root_ppn = 0;
        uint64_t vaddr = 0;
        uint16_t asid = 0;
        uint8_t vm_mode = 0;
        bool global = false;
        uint64_t fill_cycle = 0;
    };

    std::ostream& stream;
    std::array<std::array<EntryOrigin, kSets>, kWays> origin{};
    bool walk_known = false;
    uint64_t walk_vaddr = 0;
    uint64_t walk_root_ppn = 0;
    uint16_t walk_asid = 0;
    uint8_t walk_vm_mode = 0;
    unsigned walk_owner = 0;
    uint64_t last_satp = 0;
    bool last_satp_valid = false;
    uint64_t last_tlbi_cycle = 0;
    bool expect_clear = false;
    uint64_t lookups = 0;
    uint64_t hits = 0;
    uint64_t misses = 0;
    uint64_t fills = 0;
    uint64_t walks = 0;
    uint64_t flushes = 0;
    uint64_t satp_changes = 0;
    uint64_t anomalies = 0;
    uint64_t root_mismatches = 0;
    uint64_t fill_owner_mismatches = 0;
    uint64_t lookup_decode_mismatches = 0;
    uint64_t clear_mismatches = 0;

    explicit L2TlbProbe(std::ostream& output) : stream(output) {}

    void anomaly(uint64_t cycle, const char* kind) {
        ++anomalies;
        stream << "L2TLB ANOMALY cycle=" << std::dec << cycle
               << " kind=" << kind << '\n';
        stream.flush();
    }

    void clear_origins() {
        for (auto& way : origin)
            for (auto& entry : way)
                entry = EntryOrigin{};
    }

    void sample_pre_edge(Vtb_opensbi* top) {
        Vtb_opensbi___024root* const root = top->rootp;
        const uint64_t cycle = top->checkpoint_cycle_o;

#define L2P_CORE(name) \
    root->tb_opensbi__DOT__dut__DOT__u_core__DOT__g_backend_3p__DOT__u_core_3p__DOT__##name
#define L2P_BUS(name) \
    L2P_CORE(u_bus__DOT__g_ccx__DOT__u_bus__DOT__##name)
#define L2P_PTW(name) L2P_BUS(u_ptw__DOT__##name)
#define L2P_L2(name) L2P_BUS(u_l2_tlb__DOT__##name)

        const bool tlbi = L2P_CORE(__Vcellinp__u_bus__tlbi_i);
        const uint64_t satp = L2P_CORE(u_csrs__DOT__satp_q);

        if (expect_clear) {
            bool any_valid = false;
            for (unsigned way = 0; way < kWays; ++way)
                any_valid |= L2P_L2(valid_q)[way] != 0;
            if (any_valid) {
                ++clear_mismatches;
                anomaly(cycle, "valid-after-tlbi");
            }
            expect_clear = false;
        }

        if (!last_satp_valid) {
            last_satp = satp;
            last_satp_valid = true;
        } else if (satp != last_satp) {
            ++satp_changes;
            stream << "L2TLB SATP cycle=" << std::dec << cycle
                   << std::hex << std::setfill('0')
                   << " old=" << std::setw(16) << last_satp
                   << " new=" << std::setw(16) << satp
                   << std::dec << " tlbi_age="
                   << (cycle - last_tlbi_cycle) << '\n';
            if ((cycle - last_tlbi_cycle) > 1)
                anomaly(cycle, "satp-change-without-adjacent-tlbi");
            last_satp = satp;
        }

        if (tlbi) {
            ++flushes;
            last_tlbi_cycle = cycle;
            expect_clear = true;
            clear_origins();
            walk_known = false;
            stream << "L2TLB FLUSH cycle=" << std::dec << cycle
                   << std::hex << std::setfill('0')
                   << " satp=" << std::setw(16) << satp << '\n';
        }

        if (L2P_BUS(ptw_req_valid) && L2P_BUS(ptw_req_ready)) {
            ++walks;
            walk_known = true;
            walk_vaddr = L2P_BUS(ptw_req_vaddr);
            walk_vm_mode = L2P_BUS(ptw_req_vm_mode);
            if (L2P_BUS(start_lsu_walk)) {
                walk_owner = 1;
                walk_root_ppn = L2P_BUS(lsu_root_ppn_q);
                walk_asid = L2P_BUS(lsu_asid_q);
            } else if (L2P_BUS(start_fetch_walk)) {
                const unsigned slot = L2P_BUS(fetch_xlate_slot_r);
                walk_owner = 0;
                walk_root_ppn = L2P_BUS(fetch_root_ppn_q)[slot];
                walk_asid = L2P_BUS(fetch_asid_q)[slot];
            } else {
                walk_owner = 2;
                walk_root_ppn = L2P_BUS(prefetch_xlate_root_ppn_q);
                walk_asid = L2P_BUS(prefetch_xlate_asid_q);
            }
            stream << "L2TLB WALK cycle=" << std::dec << cycle
                   << " owner=" << walk_owner
                   << std::hex << std::setfill('0')
                   << " va=" << std::setw(16) << walk_vaddr
                   << " root=" << std::setw(11) << walk_root_ppn
                   << " asid=" << std::setw(4) << walk_asid
                   << " mode=" << std::setw(1)
                   << static_cast<unsigned>(walk_vm_mode) << '\n';
        }

        if (L2P_L2(diag_fill)) {
            ++fills;
            const uint64_t fill_vaddr = L2P_BUS(l2_tlb_fill_vaddr);
            const uint64_t ptw_vaddr = L2P_PTW(vaddr_q);
            const uint64_t fill_paddr = L2P_PTW(resp_paddr_q);
            const unsigned set = (fill_vaddr >> 12) & (kSets - 1);
            const unsigned way = L2P_L2(fill_way_r);
            const auto& fill_entry = L2P_L2(fill_entry);
            const bool global = ((wide_bits64(fill_entry, 6) >> 0) & 1U) != 0;

            stream << "L2TLB FILL cycle=" << std::dec << cycle
                   << " owner=" << walk_owner
                   << " set=" << set << " way=" << way
                   << std::hex << std::setfill('0')
                   << " va=" << std::setw(16) << fill_vaddr
                   << " ptw_va=" << std::setw(16) << ptw_vaddr
                   << " pa=" << std::setw(16) << fill_paddr
                   << " root=" << std::setw(11) << walk_root_ppn
                   << " global=" << global << '\n';

            if (fill_vaddr != ptw_vaddr ||
                (walk_known && fill_vaddr != walk_vaddr)) {
                ++fill_owner_mismatches;
                anomaly(cycle, "fill-va-does-not-match-active-walk");
            }
            if (way >= kWays) {
                ++fill_owner_mismatches;
                anomaly(cycle, "fill-way-out-of-range");
            } else {
                origin[way][set] = EntryOrigin{
                    walk_known,
                    walk_root_ppn,
                    fill_vaddr,
                    walk_asid,
                    walk_vm_mode,
                    global,
                    cycle
                };
            }
        }

        if (L2P_L2(diag_lookup)) {
            ++lookups;
#ifdef OPENRV64_CHECKPOINT_LEGACY_LAYOUT
            // Checkpoints predating the tagged LSU translation port have no
            // independent live xlate lookup in the generated model.
            const bool xlate_select = false;
#else
            const bool xlate_select =
                L2P_BUS(dtlb_lookup_is_xlate) &&
                !L2P_BUS(dtlb_lookup_hit);
#endif
            const bool lsu_select =
                xlate_select ||
                ((L2P_BUS(lsu_state_q) == 1) &&
                 !L2P_BUS(lsu_xlate_bare) &&
                 !L2P_BUS(dtlb_lookup_hit));
            const bool fetch_select =
                !lsu_select && L2P_BUS(fetch_xlate_found_r) &&
                !L2P_BUS(fetch_xlate_bare) &&
                !L2P_BUS(itlb_lookup_hit);
            const bool prefetch_select =
                !lsu_select && !fetch_select;

            uint64_t vaddr = 0;
            uint64_t root_ppn = 0;
            uint16_t asid = 0;
            uint8_t vm_mode = 0;
            unsigned owner = 3;
            if (lsu_select) {
                owner = 1;
                if (xlate_select) {
#ifndef OPENRV64_CHECKPOINT_LEGACY_LAYOUT
                    vaddr = L2P_CORE(backend_mem_xlate_vaddr);
                    root_ppn = satp & ((UINT64_C(1) << 44) - 1);
                    asid = (satp >> 44) & 0xffffU;
                    vm_mode = (satp >> 60) & 0xfU;
#endif
                } else {
                    vaddr = L2P_BUS(lsu_vaddr_q);
                    root_ppn = L2P_BUS(lsu_root_ppn_q);
                    asid = L2P_BUS(lsu_asid_q);
                    vm_mode = L2P_BUS(lsu_vm_mode_q);
                }
            } else if (fetch_select) {
                const unsigned slot = L2P_BUS(fetch_xlate_slot_r);
                owner = 0;
                vaddr = L2P_BUS(fetch_vaddr_q)[slot];
                root_ppn = L2P_BUS(fetch_root_ppn_q)[slot];
                asid = L2P_BUS(fetch_asid_q)[slot];
                vm_mode = L2P_BUS(fetch_vm_mode_q)[slot];
            } else if (prefetch_select) {
                owner = 2;
                vaddr = L2P_BUS(prefetch_xlate_vaddr_q);
                root_ppn = L2P_BUS(prefetch_xlate_root_ppn_q);
                asid = L2P_BUS(prefetch_xlate_asid_q);
                vm_mode = L2P_BUS(prefetch_xlate_vm_mode_q);
            }

            const uint64_t vpn = (vaddr >> 12) & kField52Mask;
            const unsigned set = (vaddr >> 12) & (kSets - 1);
            unsigned matching_ways = 0;
            unsigned matching_way = 0;
            uint64_t decoded_paddr = 0;
            bool decoded_global = false;
            for (unsigned way = 0; way < kWays; ++way) {
                if (((L2P_L2(valid_q)[way] >> set) & 1U) == 0)
                    continue;
                const auto& entry = L2P_L2(lookup_entry)[way];
                const uint64_t entry_vpn =
                    wide_bits64(entry, 79) & kField52Mask;
                const uint64_t entry_ppn =
                    wide_bits64(entry, 27) & kField52Mask;
                const uint8_t entry_mode =
                    wide_bits64(entry, 23) & 0xfU;
                const uint16_t entry_asid =
                    wide_bits64(entry, 7) & 0xffffU;
                const bool entry_global =
                    (wide_bits64(entry, 6) & 1U) != 0;
                if (entry_vpn != vpn || entry_mode != vm_mode ||
                    (!entry_global && entry_asid != asid))
                    continue;
                ++matching_ways;
                matching_way = way;
                decoded_paddr = (entry_ppn << 12) | (vaddr & 0xfffU);
                decoded_global = entry_global;
            }

            const bool rtl_hit = L2P_BUS(l2_tlb_lookup_hit);
            const uint64_t rtl_paddr = L2P_BUS(l2_tlb_lookup_paddr);
            hits += rtl_hit;
            misses += !rtl_hit;
            stream << "L2TLB LOOKUP cycle=" << std::dec << cycle
                   << " owner=" << owner << " set=" << set
                   << " hit=" << rtl_hit
                   << " matches=" << matching_ways
                   << std::hex << std::setfill('0')
                   << " va=" << std::setw(16) << vaddr
                   << " pa=" << std::setw(16) << rtl_paddr
                   << " root=" << std::setw(11) << root_ppn
                   << " asid=" << std::setw(4) << asid
                   << " mode=" << std::setw(1)
                   << static_cast<unsigned>(vm_mode) << '\n';

            if (owner == 3) {
                ++lookup_decode_mismatches;
                anomaly(cycle, "lookup-owner-undecodable");
            }
            if ((rtl_hit && matching_ways != 1) ||
                (!rtl_hit && matching_ways != 0) ||
                (rtl_hit && rtl_paddr != decoded_paddr)) {
                ++lookup_decode_mismatches;
                anomaly(cycle, "rtl-hit-disagrees-with-decoded-array");
            }
            if (rtl_hit && matching_ways == 1) {
                const EntryOrigin& entry_origin =
                    origin[matching_way][set];
                if (entry_origin.known && !decoded_global &&
                    entry_origin.root_ppn != root_ppn) {
                    ++root_mismatches;
                    anomaly(cycle, "nonglobal-hit-from-different-root");
                    stream << "L2TLB ROOT_MISMATCH cycle=" << std::dec
                           << cycle << " way=" << matching_way
                           << std::hex << std::setfill('0')
                           << " fill_root=" << std::setw(11)
                           << entry_origin.root_ppn
                           << " lookup_root=" << std::setw(11)
                           << root_ppn
                           << " fill_va=" << std::setw(16)
                           << entry_origin.vaddr
                           << " lookup_va=" << std::setw(16)
                           << vaddr << '\n';
                }
            }
        }

        if (L2P_BUS(ptw_resp_valid))
            walk_known = false;

#undef L2P_L2
#undef L2P_PTW
#undef L2P_BUS
#undef L2P_CORE
    }

    void report() const {
        std::cout
            << "HOST L2 TLB PROBE lookups=" << lookups
            << " hits=" << hits
            << " misses=" << misses
            << " fills=" << fills
            << " walks=" << walks
            << " flushes=" << flushes
            << " satp_changes=" << satp_changes
            << " anomalies=" << anomalies
            << " root_mismatches=" << root_mismatches
            << " fill_owner_mismatches=" << fill_owner_mismatches
            << " lookup_decode_mismatches=" << lookup_decode_mismatches
            << " clear_mismatches=" << clear_mismatches << '\n';
    }
};

struct L2TlbEntryInvalidator {
    static constexpr unsigned kWays = 4;
    static constexpr unsigned kSets = 64;

    unsigned target_way;
    unsigned target_set;
    bool fired = false;

    L2TlbEntryInvalidator(unsigned way, unsigned set)
        : target_way(way), target_set(set) {}

    void invalidate_now(Vtb_opensbi* top) {
        if (fired)
            return;

        Vtb_opensbi___024root* const root = top->rootp;

#define L2I_CORE(name) \
    root->tb_opensbi__DOT__dut__DOT__u_core__DOT__g_backend_3p__DOT__u_core_3p__DOT__##name
#define L2I_BUS(name) \
    L2I_CORE(u_bus__DOT__g_ccx__DOT__u_bus__DOT__##name)
#define L2I_L2(name) L2I_BUS(u_l2_tlb__DOT__##name)
#define L2I_ENTRY(way) \
    L2I_L2(g_way_storage__BRA__##way##__KET____DOT__entry_q)

        if (target_way >= kWays || target_set >= kSets) {
            std::cerr << "L2 TLB ENTRY INVALIDATE out of range way="
                      << target_way << " set=" << target_set << '\n';
            std::exit(EXIT_FAILURE);
        }

        auto& valid = L2I_L2(valid_q);
        if (((valid[target_way] >> target_set) & 1U) == 0) {
            std::cerr << "L2 TLB ENTRY INVALIDATE target is not valid way="
                      << target_way << " set=" << target_set << '\n';
            std::exit(EXIT_FAILURE);
        }

        const VlWide<5>* entry = nullptr;
        switch (target_way) {
        case 0:
            entry = &L2I_ENTRY(0)[target_set];
            break;
        case 1:
            entry = &L2I_ENTRY(1)[target_set];
            break;
        case 2:
            entry = &L2I_ENTRY(2)[target_set];
            break;
        case 3:
            entry = &L2I_ENTRY(3)[target_set];
            break;
        default:
            break;
        }

        const uint64_t vpn = wide_bits64(*entry, 79) &
            ((UINT64_C(1) << 52) - 1);
        const uint64_t ppn = wide_bits64(*entry, 27) &
            ((UINT64_C(1) << 52) - 1);
        const uint8_t vm_mode = wide_bits64(*entry, 23) & 0xfU;
        const uint16_t asid = wide_bits64(*entry, 7) & 0xffffU;
        const bool global = (wide_bits64(*entry, 6) & 1U) != 0;
        const bool active_lookup =
            L2I_L2(diag_lookup) && L2I_BUS(l2_tlb_lookup_hit);

        valid[target_way] &= ~(UINT64_C(1) << target_set);
        top->eval();
        fired = true;

        std::cout << "L2 TLB ENTRY INVALIDATED cycle=" << std::dec
                  << top->checkpoint_cycle_o
                  << " way=" << target_way
                  << " set=" << target_set
                  << " active_lookup=" << active_lookup
                  << std::hex << std::setfill('0')
                  << " vpn=" << std::setw(13) << vpn
                  << " ppn=" << std::setw(13) << ppn
                  << " asid=" << std::setw(4) << asid
                  << " mode=" << static_cast<unsigned>(vm_mode)
                  << " global=" << global
                  << std::dec << '\n';

#undef L2I_ENTRY
#undef L2I_L2
#undef L2I_BUS
#undef L2I_CORE
    }

    void report() const {
        std::cout << "HOST L2 TLB ENTRY INVALIDATE way="
                  << target_way << " set=" << target_set
                  << " fired=" << fired << '\n';
    }
};

struct L1dProbe {
    std::ostream& stream;

    explicit L1dProbe(std::ostream& output) : stream(output) {}

    void sample_pre_edge(Vtb_opensbi* top) {
        Vtb_opensbi___024root* const root = top->rootp;

#define L1DP_CORE(name) \
    root->tb_opensbi__DOT__dut__DOT__u_core__DOT__g_backend_3p__DOT__u_core_3p__DOT__##name
#define L1DP_BUS(name) \
    L1DP_CORE(u_bus__DOT__g_ccx__DOT__u_bus__DOT__##name)
#define L1DP(name) L1DP_BUS(u_l1d__DOT__##name)
#define L1DP_CACHE(name) \
    L1DP(u_l1d__DOT__u_l1__DOT__g_cache__DOT__u_cache__DOT__##name)

        const uint64_t cycle = top->checkpoint_cycle_o;
        stream << std::dec
               << "cycle=" << cycle
               << " cache_state=" << static_cast<unsigned>(L1DP_CACHE(state_q))
               << " req_fire=" << static_cast<unsigned>(L1DP_CACHE(request_fire))
               << " lookup_hit=" << static_cast<unsigned>(L1DP_CACHE(lookup_hit))
               << " req_write=" << static_cast<unsigned>(L1DP_CACHE(request_write_q))
               << " access_update="
               << static_cast<unsigned>(L1DP_CACHE(access_updates_line_q))
               << " access_set="
               << static_cast<unsigned>(L1DP_CACHE(access_set_q))
               << " access_way="
               << static_cast<unsigned>(L1DP_CACHE(access_way_q))
               << std::hex << std::setfill('0')
               << " req_pa=" << std::setw(16)
               << static_cast<uint64_t>(L1DP_CACHE(request_phys_addr_q))
               << " req_data=" << std::setw(16)
               << static_cast<uint64_t>(L1DP_CACHE(request_wdata_q))
               << " req_strb=" << std::setw(2)
               << static_cast<unsigned>(L1DP_CACHE(request_wstrb_q))
               << std::dec
               << " resp_valid="
               << static_cast<unsigned>(L1DP_CACHE(response_valid_q))
               << " resp_hit="
               << static_cast<unsigned>(L1DP_CACHE(response_hit_q))
               << std::hex << std::setfill('0')
               << " resp_data=" << std::setw(16)
               << static_cast<uint64_t>(L1DP_CACHE(response_data_q))
               << std::dec
               << " fill_fire="
               << static_cast<unsigned>(L1DP_CACHE(fill_fire))
               << std::hex << std::setfill('0')
               << " fill_addr=" << std::setw(16)
               << static_cast<uint64_t>(L1DP(l1_fill_addr))
               << " fill_data0=" << std::setw(16)
               << wide_bits64(L1DP(demand_fill_data_r), 0)
               << std::dec
               << " mem_valid=" << static_cast<unsigned>(L1DP(l1_mem_valid))
               << " mem_ready=" << static_cast<unsigned>(L1DP(l1_mem_ready))
               << " mem_write=" << static_cast<unsigned>(L1DP(l1_mem_write))
               << std::hex << std::setfill('0')
               << " mem_addr=" << std::setw(16)
               << static_cast<uint64_t>(L1DP(l1_mem_addr))
               << " mem_data=" << std::setw(16)
               << static_cast<uint64_t>(L1DP(l1_mem_wdata))
               << " mem_strb=" << std::setw(2)
               << static_cast<unsigned>(L1DP(l1_mem_wstrb))
               << std::dec
               << " backend_state="
               << static_cast<unsigned>(L1DP(backend_state_q))
               << " sb_count="
               << static_cast<unsigned>(L1DP(store_buffer_count_q))
               << " sb_head="
               << static_cast<unsigned>(L1DP(store_buffer_head_q))
               << " sb_tail="
               << static_cast<unsigned>(L1DP(store_buffer_tail_q))
               << " sb_accept="
               << static_cast<unsigned>(L1DP(store_buffer_accept))
               << " sb_merge="
               << static_cast<unsigned>(L1DP(store_buffer_merge))
               << " sb_allocate="
               << static_cast<unsigned>(L1DP(store_buffer_allocate))
               << " sb_issue_found="
               << static_cast<unsigned>(L1DP(store_buffer_issue_found_r))
               << " sb_issue_index="
               << static_cast<unsigned>(L1DP(store_buffer_issue_index_r))
               << " sb_resp_match="
               << static_cast<unsigned>(L1DP(store_response_match_r))
               << " sb_resp_index="
               << static_cast<unsigned>(L1DP(store_response_index_r))
               << " sb_resp_fire="
               << static_cast<unsigned>(L1DP(store_response_fire))
               << " cmd_fire="
               << static_cast<unsigned>(L1DP(command_fire))
               << " wdata_fire="
               << static_cast<unsigned>(L1DP(wdata_fire))
               << " main_resp_fire="
               << static_cast<unsigned>(L1DP(main_response_fire))
               << " normal_resp="
               << static_cast<unsigned>(L1DP(normal_response_valid))
               << std::hex << std::setfill('0')
               << " normal_data=" << std::setw(16)
               << static_cast<uint64_t>(L1DP(normal_response_merged_data_r))
               << " outer_req_addr=" << std::setw(16)
               << static_cast<uint64_t>(L1DP(request_addr_q))
               << " outer_req_strb=" << std::setw(16)
               << static_cast<uint64_t>(L1DP(request_wstrb_q))
               << std::dec
               << " outer_req_write="
               << static_cast<unsigned>(L1DP(request_write_q))
               << " outer_req_buffered="
               << static_cast<unsigned>(L1DP(request_buffered_store_q))
               << " pf_launch="
               << static_cast<unsigned>(L1DP(prefetch_launch))
               << " pf_launch_found="
               << static_cast<unsigned>(L1DP(prefetch_launch_found_r))
               << std::hex << std::setfill('0')
               << " pf_launch_addr=" << std::setw(16)
               << static_cast<uint64_t>(L1DP(prefetch_launch_addr_r))
               << std::dec
               << " pf_command="
               << static_cast<unsigned>(L1DP(prefetch_command_inflight))
               << " req_prefetch="
               << static_cast<unsigned>(L1DP(request_prefetch_q));

        for (unsigned index = 0; index < 3; ++index) {
            if (!L1DP(demand_mshr_valid_q)[index])
                continue;
            stream << " mshr[" << index << "]={"
                   << std::hex << std::setfill('0')
                   << "addr=" << std::setw(16)
                   << static_cast<uint64_t>(L1DP(demand_mshr_addr_q)[index])
                   << ",data0=" << std::setw(16)
                   << wide_bits64(L1DP(demand_mshr_data_q)[index], 0)
                   << ",store_data0=" << std::setw(16)
                   << wide_bits64(L1DP(demand_mshr_store_data_q)[index], 0)
                   << ",store_strb=" << std::setw(16)
                   << static_cast<uint64_t>(
                          L1DP(demand_mshr_store_strb_q)[index])
                   << std::dec
                   << ",issued="
                   << static_cast<unsigned>(L1DP(demand_mshr_issued_q)[index])
                   << ",complete="
                   << static_cast<unsigned>(L1DP(demand_mshr_complete_q)[index])
                   << ",fill_done="
                   << static_cast<unsigned>(L1DP(demand_mshr_fill_done_q)[index])
                   << '}';
        }
        for (unsigned index = 0; index < 4; ++index) {
            if (!L1DP(prefetch_mshr_valid_q)[index])
                continue;
            stream << " pf_mshr[" << index << "]={"
                   << std::hex << std::setfill('0')
                   << "addr=" << std::setw(16)
                   << static_cast<uint64_t>(L1DP(prefetch_mshr_addr_q)[index])
                   << std::dec
                   << ",discard="
                   << static_cast<unsigned>(
                          L1DP(prefetch_mshr_discard_q)[index])
                   << '}';
        }
        for (unsigned index = 0; index < 8; ++index) {
            if (!L1DP(store_buffer_valid_q)[index])
                continue;
            stream << " sb[" << index << "]={"
                   << std::hex << std::setfill('0')
                   << "addr=" << std::setw(16)
                   << static_cast<uint64_t>(L1DP(store_buffer_addr_q)[index])
                   << ",data0=" << std::setw(16)
                   << wide_bits64(L1DP(store_buffer_data_q)[index], 0)
                   << ",strb=" << std::setw(16)
                   << static_cast<uint64_t>(L1DP(store_buffer_strb_q)[index])
                   << std::dec
                   << ",issued="
                   << static_cast<unsigned>(L1DP(store_buffer_issued_q)[index])
                   << ",complete="
                   << static_cast<unsigned>(L1DP(store_buffer_completed_q)[index])
                   << ",txn="
                   << static_cast<unsigned>(L1DP(store_buffer_txn_id_q)[index])
                   << '}';
        }
        stream << '\n';

#undef L1DP_CACHE
#undef L1DP
#undef L1DP_BUS
#undef L1DP_CORE
    }
};

static void suppress_l1d_prefetch_launch(Vtb_opensbi* top) {
    Vtb_opensbi___024root* const root = top->rootp;

#define L1DS_CORE(name) \
    root->tb_opensbi__DOT__dut__DOT__u_core__DOT__g_backend_3p__DOT__u_core_3p__DOT__##name
#define L1DS_BUS(name) \
    L1DS_CORE(u_bus__DOT__g_ccx__DOT__u_bus__DOT__##name)
#define L1DS(name) L1DS_BUS(u_l1d__DOT__##name)

    if (!L1DS(prefetch_launch_found_r)) {
        std::cerr << "L1D PREFETCH SUPPRESS requested without candidate"
                  << " cycle=" << top->checkpoint_cycle_o << '\n';
        std::exit(EXIT_FAILURE);
    }

    const unsigned index = L1DS(prefetch_launch_index_r);
    const uint64_t addr = L1DS(prefetch_launch_addr_r);
    L1DS(prefetch_candidate_valid_q)[index] = 0;
    top->eval();
    std::cout << "L1D PREFETCH SUPPRESSED cycle="
              << top->checkpoint_cycle_o
              << " index=" << index
              << std::hex << std::setfill('0')
              << " addr=" << std::setw(16) << addr
              << std::dec << '\n';

#undef L1DS
#undef L1DS_BUS
#undef L1DS_CORE
}

struct FullRetireTrace {
    std::ostream& stream;

    explicit FullRetireTrace(std::ostream& output) : stream(output) {}

    void sample_pre_edge(Vtb_opensbi* top) {
        Vtb_opensbi___024root* const root = top->rootp;

#define R3P_BACKEND(name) \
    root->tb_opensbi__DOT__dut__DOT__u_core__DOT__g_backend_3p__DOT__u_core_3p__DOT__u_backend__DOT__##name
#define R3P_QUEUE(name) R3P_BACKEND(u_retire_queue__DOT__##name)
#define R3P_RETIRE(name) R3P_BACKEND(u_retire__DOT__##name)
#define R3P_CORE(name) \
    root->tb_opensbi__DOT__dut__DOT__u_core__DOT__g_backend_3p__DOT__u_core_3p__DOT__##name

        const std::array<bool, 3> arch = {
            static_cast<bool>(R3P_RETIRE(arch0)),
            static_cast<bool>(R3P_RETIRE(arch1)),
            static_cast<bool>(R3P_RETIRE(arch2))
        };
        const unsigned head = R3P_QUEUE(head_q);
        const unsigned privilege = R3P_CORE(u_csrs__DOT__priv_mode_q);
        for (unsigned lane = 0; lane < arch.size(); ++lane) {
            if (!arch[lane])
                continue;
            const unsigned slot = (head + lane) & 15U;
            const auto& result = R3P_QUEUE(result_q)[slot];
            const uint64_t pc = wide_bits64(result, 329);
            const uint64_t next_pc = wide_bits64(result, 265);
            const uint32_t instr =
                static_cast<uint32_t>(wide_bits64(result, 233));
            const bool result_reg_write =
                (wide_bits64(result, 153) & 1U) != 0;
            const unsigned rd =
                static_cast<unsigned>(wide_bits64(result, 154) & 0x1fU);
            const uint64_t wdata = wide_bits64(result, 169);
            const uint64_t trace_id = wide_bits64(result, 393);

            stream << "cycle=" << std::dec << top->checkpoint_cycle_o
                   << " lane=" << lane
                   << " id=" << trace_id
                   << std::hex << std::setfill('0')
                   << " pc=" << std::setw(16) << pc
                   << " instr=" << std::setw(8) << instr
                   << std::dec << " priv=" << privilege
                   << std::hex << std::setfill('0')
                   << " next=" << std::setw(16) << next_pc
                   << std::dec
                   << " rd_write=" << (result_reg_write && rd != 0)
                   << " rd=" << rd
                   << std::hex << std::setfill('0')
                   << " wdata=" << std::setw(16) << wdata << '\n';
        }

#undef R3P_CORE
#undef R3P_RETIRE
#undef R3P_QUEUE
#undef R3P_BACKEND
    }
};

struct FrontendBreakdown {
    enum class Recovery : uint8_t {
        None,
        PredictedRedirect,
        DirectionRedirect,
        ControlFlush,
    };

    enum class TargetSource : uint8_t {
        ResidentFetchLine,
        AlternateFal,
        L1iHit,
        L1iMiss,
        TranslationPtw,
        ChainedRedirect,
        Count,
    };

    static constexpr unsigned kTargetLatencyBuckets = 6;
    static constexpr unsigned kTargetSourceCount =
        static_cast<unsigned>(TargetSource::Count);

    struct PendingTarget {
        bool valid = false;
        bool chained = false;
        bool resident = false;
        bool l1_probe_pending = false;
        bool l1_miss = false;
        bool translation_delay = false;
        bool fetch_request_fire_valid = false;
        bool translation_complete_valid = false;
        bool l1i_request_fire_valid = false;
        bool l1i_response_valid = false;
        bool target_decode_valid = false;
        bool redirect_pending_valid = false;
        bool redirect_pending_target_line = false;
        bool redirect_pending_fallthrough_line = false;
        bool fetch_slot_valid = false;
        unsigned fetch_slot = 0;
        uint64_t event_id = 0;
        uint64_t target = 0;
        uint64_t branch_pc = 0;
        uint64_t start_cycle = 0;
        uint64_t fetch_request_fire_cycle = 0;
        uint64_t translation_complete_cycle = 0;
        uint64_t l1i_request_fire_cycle = 0;
        uint64_t l1i_response_cycle = 0;
        uint64_t target_decode_cycle = 0;
    };

    uint64_t sampled_cycles = 0;
    uint64_t frontend_empty = 0;

    // Mutually exclusive empty-cycle buckets, in priority order.
    uint64_t empty_recovery_predicted = 0;
    uint64_t empty_recovery_direction = 0;
    uint64_t empty_recovery_flush = 0;
    uint64_t empty_translation_barrier = 0;
    uint64_t empty_fetch_ptw = 0;
    uint64_t empty_fetch_l1i = 0;
    uint64_t empty_fetch_uncached = 0;
    uint64_t empty_fetch_translate = 0;
    uint64_t empty_request_backpressure = 0;
    uint64_t empty_response_complete = 0;
    uint64_t empty_outstanding_other = 0;
    uint64_t empty_no_current_sector = 0;
    uint64_t empty_current_sector_no_lane = 0;
    uint64_t empty_inactive = 0;
    uint64_t empty_other = 0;

    // Orthogonal observations.  These deliberately overlap.
    uint64_t overlap_current_sector_missing = 0;
    uint64_t overlap_following_sector_missing = 0;
    uint64_t overlap_l1i_busy = 0;
    uint64_t overlap_fetch_queue_nonempty = 0;
    uint64_t overlap_pending_request = 0;
    uint64_t overlap_pair_pending = 0;
    uint64_t overlap_bp_fetch_stall = 0;
    uint64_t overlap_request_fire = 0;
    uint64_t overlap_response_match = 0;

    uint64_t predicted_redirects = 0;
    uint64_t direction_redirects = 0;
    uint64_t control_flushes = 0;
    uint64_t branch_resolutions = 0;
    uint64_t conditional_resolutions = 0;
    uint64_t jump_resolutions = 0;
    uint64_t conditional_direction_misses = 0;
    uint64_t jump_direction_misses = 0;
    uint64_t conditional_target_misses = 0;
    uint64_t jump_target_misses = 0;

    std::array<uint64_t, kTargetLatencyBuckets> target_latency{};
    std::array<std::array<uint64_t, kTargetLatencyBuckets>,
               kTargetSourceCount>
        target_latency_by_source{};
    std::array<uint64_t, 9> l1i_hit_exact_latency{};
    uint64_t target_deliveries = 0;
    uint64_t target_superseded_control = 0;
    uint64_t target_superseded_prediction = 0;
    uint64_t redirect_pending_valid = 0;
    uint64_t redirect_pending_target_line = 0;
    uint64_t redirect_pending_fallthrough_line = 0;
    uint64_t next_target_event_id = 0;
    PendingTarget pending_target{};
    std::ostream* target_trace = nullptr;

    Recovery recovery = Recovery::None;

    explicit FrontendBreakdown(std::ostream* trace = nullptr)
        : target_trace(trace) {
        if (target_trace) {
            *target_trace
                << "event_id,target,branch_pc,outcome,source,"
                   "redirect,fetch_request_fire,translation_complete,"
                   "l1i_request_fire,l1i_response,target_decode_valid,"
                   "redirect_pending_valid,"
                   "redirect_pending_target_line,"
                   "redirect_pending_fallthrough_line\n";
        }
    }

    static unsigned target_latency_bucket(uint64_t bubble_cycles) {
        if (bubble_cycles <= 3)
            return static_cast<unsigned>(bubble_cycles);
        if (bubble_cycles <= 7)
            return 4;
        return 5;
    }

    static const char* target_source_name(TargetSource source) {
        switch (source) {
        case TargetSource::ChainedRedirect:
            return "chained_redirect";
        case TargetSource::ResidentFetchLine:
            return "resident_fetch_line";
        case TargetSource::AlternateFal:
            return "alternate_fal";
        case TargetSource::TranslationPtw:
            return "translation_ptw";
        case TargetSource::L1iHit:
            return "l1i_hit";
        case TargetSource::L1iMiss:
            return "l1i_miss";
        default:
            return "invalid";
        }
    }

    static void write_optional_cycle(std::ostream& stream, bool valid,
                                     uint64_t cycle) {
        if (valid)
            stream << cycle;
    }

    void write_target_trace(const PendingTarget& event,
                            const char* outcome,
                            const char* source) {
        if (!target_trace)
            return;
        *target_trace
            << std::dec << event.event_id
            << ",0x" << std::hex << event.target
            << ",0x" << event.branch_pc
            << std::dec << ',' << outcome << ',' << source << ','
            << event.start_cycle << ',';
        write_optional_cycle(*target_trace,
                             event.fetch_request_fire_valid,
                             event.fetch_request_fire_cycle);
        *target_trace << ',';
        write_optional_cycle(*target_trace,
                             event.translation_complete_valid,
                             event.translation_complete_cycle);
        *target_trace << ',';
        write_optional_cycle(*target_trace,
                             event.l1i_request_fire_valid,
                             event.l1i_request_fire_cycle);
        *target_trace << ',';
        write_optional_cycle(*target_trace,
                             event.l1i_response_valid,
                             event.l1i_response_cycle);
        *target_trace << ',';
        write_optional_cycle(*target_trace,
                             event.target_decode_valid,
                             event.target_decode_cycle);
        *target_trace
            << ',' << event.redirect_pending_valid
            << ',' << event.redirect_pending_target_line
            << ',' << event.redirect_pending_fallthrough_line
            << '\n';
    }

    void sample(Vtb_opensbi* top) {
        Vtb_opensbi___024root* const root = top->rootp;

#define FE_CORE(name) \
    root->tb_opensbi__DOT__dut__DOT__u_core__DOT__g_backend_3p__DOT__u_core_3p__DOT__##name
#define FE_FETCH(name) \
    FE_CORE(g_fetch_axi__DOT__u_fetch__DOT__##name)
#define FE_BUS(name) \
    FE_CORE(u_bus__DOT__g_ccx__DOT__u_bus__DOT__##name)
#define FE_L1I(name) \
    FE_BUS(u_l1i__DOT__##name)

        ++sampled_cycles;

        const bool predicted_redirect =
            FE_CORE(bp_branch_allocate) && FE_CORE(bp_prediction_taken);
        const bool direction_redirect = FE_CORE(backend_redirect);
        const bool control_flush = FE_CORE(control_flush);
        const bool control_redirect = FE_CORE(control_redirect);
        const bool branch_resolved = FE_CORE(branch_resolved);
        const bool branch_conditional = FE_CORE(branch_conditional);
        const bool target_miss = FE_CORE(bp_target_mispredict);
        const uint64_t cycle = top->checkpoint_cycle_o;
        const bool fetch_carousel =
            FE_FETCH(measurement_carousel_enabled);
        const unsigned fetch_line_depth = fetch_carousel ? 4U : 2U;
        const auto fetch_pending_slot_valid =
            [&](unsigned slot) {
                return fetch_carousel
                    ? FE_FETCH(carousel_pending_valid_q)[slot] != 0
                    : slot == 0 && FE_FETCH(pending_valid_q);
            };
        const auto fetch_pending_slot_addr =
            [&](unsigned slot) {
                return fetch_carousel
                    ? static_cast<uint64_t>(
                          FE_FETCH(carousel_pending_addr_q)[slot])
                    : static_cast<uint64_t>(FE_FETCH(pending_addr_q));
            };
        const auto fetch_pending_line =
            [&](uint64_t line) {
                for (unsigned slot = 0; slot < fetch_line_depth; ++slot) {
                    if (fetch_pending_slot_valid(slot) &&
                        (fetch_pending_slot_addr(slot) >> 5) == line)
                        return true;
                }
                if (FE_FETCH(ras_line_pending_q) &&
                    (FE_FETCH(ras_line_addr_q) >> 5) == line)
                    return true;
                if (FE_FETCH(fal_line_pending_q) &&
                    (FE_FETCH(fal_line_addr_q) >> 5) == line)
                    return true;
                return false;
            };
        bool fetch_pending_any =
            FE_FETCH(ras_line_pending_q) ||
            FE_FETCH(fal_line_pending_q);
        for (unsigned slot = 0; slot < fetch_line_depth; ++slot)
            fetch_pending_any |= fetch_pending_slot_valid(slot);

        predicted_redirects += predicted_redirect;
        direction_redirects += direction_redirect;
        control_flushes += control_flush;
        branch_resolutions += branch_resolved;
        conditional_resolutions += branch_resolved && branch_conditional;
        jump_resolutions += branch_resolved && !branch_conditional;
        conditional_direction_misses +=
            direction_redirect && branch_conditional;
        jump_direction_misses += direction_redirect && !branch_conditional;
        conditional_target_misses += target_miss && branch_conditional;
        jump_target_misses += target_miss && !branch_conditional;

        bool target_delivered_now = false;
        if (pending_target.valid) {
            const uint64_t target_line = pending_target.target >> 5;

            if (!pending_target.fetch_request_fire_valid &&
                FE_CORE(fetch_pipe_req_valid) &&
                FE_CORE(fetch_pipe_req_ready) &&
                FE_CORE(fetch_pipe_req_demand) &&
                ((FE_CORE(fetch_pipe_req_addr) >> 5) == target_line)) {
                pending_target.fetch_request_fire_valid = true;
                pending_target.fetch_request_fire_cycle = cycle;
                pending_target.fetch_slot_valid = true;
                pending_target.fetch_slot = FE_BUS(fetch_tail_q);
            }

            bool target_translate = false;
            bool target_ptw = false;
            for (unsigned index = 0; index < 4; ++index) {
                const bool target_slot =
                    pending_target.fetch_slot_valid &&
                    index == pending_target.fetch_slot &&
                    FE_BUS(fetch_state_q)[index] != 0 &&
                    FE_BUS(fetch_demand_q)[index] &&
                    !FE_BUS(fetch_cancelled_q)[index] &&
                    ((FE_BUS(fetch_vaddr_q)[index] >> 5) ==
                     (pending_target.target >> 5));
                if (!target_slot)
                    continue;
                target_ptw |= FE_BUS(fetch_state_q)[index] == 2;
            }
            if (pending_target.fetch_slot_valid &&
                FE_BUS(fetch_xlate_found_r) &&
                FE_BUS(fetch_xlate_slot_r) ==
                    pending_target.fetch_slot) {
                const unsigned xlate_slot =
                    FE_BUS(fetch_xlate_slot_r);
                target_translate =
                    FE_BUS(fetch_demand_q)[xlate_slot] &&
                    !FE_BUS(fetch_cancelled_q)[xlate_slot] &&
                    FE_BUS(fetch_vm_mode_q)[xlate_slot] != 0 &&
                    !FE_BUS(itlb_lookup_hit) &&
                    ((FE_BUS(fetch_vaddr_q)[xlate_slot] >> 5) ==
                     target_line);
                if (!pending_target.translation_complete_valid &&
                    FE_BUS(fetch_lookup_ready) &&
                    FE_BUS(fetch_demand_q)[xlate_slot] &&
                    !FE_BUS(fetch_cancelled_q)[xlate_slot] &&
                    ((FE_BUS(fetch_vaddr_q)[xlate_slot] >> 5) ==
                     target_line)) {
                    pending_target.translation_complete_valid = true;
                    pending_target.translation_complete_cycle = cycle;
                }
            }
            pending_target.translation_delay |=
                target_translate || target_ptw;

            const unsigned l1i_request_slot =
                FE_BUS(l1i_req_active_q)
                    ? FE_BUS(l1i_req_slot_q)
                    : FE_BUS(fetch_xlate_slot_r);
            if (pending_target.fetch_slot_valid &&
                FE_BUS(l1i_req_fire) &&
                l1i_request_slot == pending_target.fetch_slot &&
                ((FE_BUS(l1i_req_vaddr) >> 5) == target_line)) {
                // Detached L1I misses are identified on the request
                // handshake.  They no longer occupy a blocking memory FSM.
                pending_target.l1_miss |= FE_L1I(l1_miss_fire);
                if (!pending_target.l1i_request_fire_valid) {
                    pending_target.l1i_request_fire_valid = true;
                    pending_target.l1i_request_fire_cycle = cycle;
                }
            }

            if (!pending_target.l1i_response_valid &&
                FE_BUS(l1i_resp_valid)) {
                const unsigned response_slot = FE_BUS(l1i_resp_tag);
                if (pending_target.fetch_slot_valid &&
                    response_slot == pending_target.fetch_slot &&
                    FE_BUS(fetch_demand_q)[response_slot] &&
                    !FE_BUS(fetch_cancelled_q)[response_slot] &&
                    ((FE_BUS(fetch_vaddr_q)[response_slot] >> 5) ==
                     target_line)) {
                    pending_target.l1i_response_valid = true;
                    pending_target.l1i_response_cycle = cycle;
                }
            }

            const bool target_valid =
                (FE_CORE(fetch_decode_valid) & 1U) != 0 &&
                FE_FETCH(consume_pc_q) == pending_target.target;
            if (target_valid) {
                TargetSource source;
                const unsigned target_sector =
                    (pending_target.target >> 4) & 1U;
                const bool alternate =
                    ((FE_FETCH(consume_fetch_select) >> target_sector) &
                     1U) != 0;
                if (pending_target.chained)
                    source = TargetSource::ChainedRedirect;
                else if (pending_target.resident)
                    source = TargetSource::ResidentFetchLine;
                else if (alternate)
                    source = TargetSource::AlternateFal;
                else if (pending_target.translation_delay)
                    source = TargetSource::TranslationPtw;
                else if (pending_target.l1_miss)
                    source = TargetSource::L1iMiss;
                else
                    source = TargetSource::L1iHit;

                // Count empty slots between the redirecting instruction and
                // target output.  Delivery in the immediately following
                // cycle is therefore the zero-bubble bucket.
                const uint64_t elapsed =
                    cycle >= pending_target.start_cycle
                        ? cycle - pending_target.start_cycle
                        : 0;
                const uint64_t bubble_cycles =
                    elapsed == 0 ? 0 : elapsed - 1;
                const unsigned bucket =
                    target_latency_bucket(bubble_cycles);
                ++target_latency[bucket];
                ++target_latency_by_source[
                    static_cast<unsigned>(source)][bucket];
                if (source == TargetSource::L1iHit) {
                    const unsigned exact_bucket =
                        bubble_cycles <= 7
                            ? static_cast<unsigned>(bubble_cycles)
                            : 8;
                    ++l1i_hit_exact_latency[exact_bucket];
                }
                ++target_deliveries;
                pending_target.target_decode_valid = true;
                pending_target.target_decode_cycle = cycle;
                write_target_trace(pending_target, "delivered",
                                   target_source_name(source));
                pending_target.valid = false;
                target_delivered_now = true;
            } else if (control_flush || control_redirect) {
                ++target_superseded_control;
                write_target_trace(pending_target,
                                   "superseded_control",
                                   "undelivered");
                pending_target.valid = false;
            }
        }

        if (predicted_redirect) {
            bool chained = target_delivered_now;
            if (pending_target.valid) {
                // This should only occur if a new redirect is generated from
                // a bundle other than the requested target.  Keep accounting
                // explicit rather than allowing the old target to match later.
                ++target_superseded_prediction;
                write_target_trace(pending_target,
                                   "superseded_prediction",
                                   "undelivered");
                pending_target.valid = false;
                chained = true;
            }

            const uint64_t target =
                FE_CORE(bp_prediction_target_valid)
                    ? FE_CORE(bp_prediction_target)
                    : FE_CORE(bp_direct_target);
            const uint64_t branch_pc = FE_CORE(bp_selected_pc);
            const uint64_t fallthrough = branch_pc + 4;
            const bool pending_valid = fetch_pending_any;
            const bool pending_target_line =
                fetch_pending_line(target >> 5);
            const bool pending_fallthrough_line =
                fetch_pending_line(fallthrough >> 5);
            const unsigned line_slot =
                (target >> 5) & (fetch_line_depth - 1U);
            const unsigned target_sector = (target >> 4) & 1U;
            const bool resident =
                FE_FETCH(line_valid_q)[line_slot] &&
                ((FE_FETCH(line_addr_q)[line_slot] >> 5) ==
                 (target >> 5)) &&
                (((FE_FETCH(line_sector_valid_q)[line_slot] >>
                   target_sector) & 1U) != 0);

            pending_target = PendingTarget{};
            pending_target.valid = true;
            pending_target.chained = chained;
            pending_target.resident = resident;
            pending_target.redirect_pending_valid = pending_valid;
            pending_target.redirect_pending_target_line =
                pending_target_line;
            pending_target.redirect_pending_fallthrough_line =
                pending_fallthrough_line;
            pending_target.event_id = next_target_event_id++;
            pending_target.target = target;
            pending_target.branch_pc = branch_pc;
            pending_target.start_cycle = cycle;
            redirect_pending_valid += pending_valid;
            redirect_pending_target_line += pending_target_line;
            redirect_pending_fallthrough_line +=
                pending_fallthrough_line;
        }

        if (control_flush)
            recovery = Recovery::ControlFlush;
        else if (direction_redirect)
            recovery = Recovery::DirectionRedirect;
        else if (predicted_redirect)
            recovery = Recovery::PredictedRedirect;

        const bool empty = FE_CORE(fetch_decode_valid) == 0;
        if (!empty) {
            if (!control_flush && !direction_redirect &&
                !predicted_redirect)
                recovery = Recovery::None;
            return;
        }
        ++frontend_empty;

        bool fetch_translate = false;
        bool fetch_ptw = false;
        bool fetch_uncached = false;
        bool fetch_complete = false;
        bool fetch_l1i = false;
        for (unsigned index = 0; index < 4; ++index) {
            const unsigned state = FE_BUS(fetch_state_q)[index];
            fetch_translate |= state == 1;
            fetch_ptw |= state == 2;
            fetch_uncached |= state == 3;
            fetch_complete |= state == 4;
            fetch_l1i |= state == 5;
        }

        const uint64_t consume_pc = FE_FETCH(consume_pc_q);
        const unsigned current_sector = (consume_pc >> 4) & 1U;
        const bool current_sector_valid =
            ((FE_FETCH(consume_sector_valid) >> current_sector) & 1U) != 0;
        const bool following_sector_valid =
            (FE_FETCH(following_sector_valid) & 1U) != 0;
        const bool request_backpressure =
            FE_CORE(fetch_pipe_req_valid) && !FE_CORE(fetch_pipe_req_ready);
        const bool fetch_queue_nonempty =
            fetch_translate || fetch_ptw || fetch_uncached ||
            fetch_complete || fetch_l1i;
        const bool pair_pending = FE_FETCH(pair_predicted_valid_q) ||
                                  FE_FETCH(pair_unpredicted_valid_q);

        overlap_current_sector_missing += !current_sector_valid;
        overlap_following_sector_missing += !following_sector_valid;
        overlap_l1i_busy +=
            FE_BUS(u_l1i__DOT__demand_mshr_any_valid_r) != 0;
        overlap_fetch_queue_nonempty += fetch_queue_nonempty;
        overlap_pending_request += fetch_pending_any;
        overlap_pair_pending += pair_pending;
        overlap_bp_fetch_stall += FE_CORE(bp_fetch_stall);
        overlap_request_fire += FE_FETCH(req_fire);
        overlap_response_match += FE_FETCH(resp_match);

        if (recovery == Recovery::ControlFlush)
            ++empty_recovery_flush;
        else if (recovery == Recovery::DirectionRedirect)
            ++empty_recovery_direction;
        else if (recovery == Recovery::PredictedRedirect)
            ++empty_recovery_predicted;
        else if (FE_CORE(translation_barrier_busy))
            ++empty_translation_barrier;
        else if (fetch_ptw)
            ++empty_fetch_ptw;
        else if (fetch_l1i)
            ++empty_fetch_l1i;
        else if (fetch_uncached)
            ++empty_fetch_uncached;
        else if (fetch_translate)
            ++empty_fetch_translate;
        else if (request_backpressure)
            ++empty_request_backpressure;
        else if (fetch_complete)
            ++empty_response_complete;
        else if (fetch_queue_nonempty || fetch_pending_any)
            ++empty_outstanding_other;
        else if (!current_sector_valid)
            ++empty_no_current_sector;
        else if (FE_FETCH(lane_found_r) == 0)
            ++empty_current_sector_no_lane;
        else if (!FE_FETCH(active_q))
            ++empty_inactive;
        else
            ++empty_other;

#undef FE_L1I
#undef FE_BUS
#undef FE_FETCH
#undef FE_CORE
    }

    void report() {
        const uint64_t exclusive_sum =
            empty_recovery_predicted + empty_recovery_direction +
            empty_recovery_flush + empty_translation_barrier +
            empty_fetch_ptw + empty_fetch_l1i + empty_fetch_uncached +
            empty_fetch_translate + empty_request_backpressure +
            empty_response_complete + empty_outstanding_other +
            empty_no_current_sector + empty_current_sector_no_lane +
            empty_inactive + empty_other;

        std::cout
            << "HOST FRONTEND BREAKDOWN sampled_cycles=" << sampled_cycles
            << " empty=" << frontend_empty
            << " exclusive_sum=" << exclusive_sum
            << " recovery_predicted=" << empty_recovery_predicted
            << " recovery_direction=" << empty_recovery_direction
            << " recovery_flush=" << empty_recovery_flush
            << " translation_barrier=" << empty_translation_barrier
            << " fetch_ptw=" << empty_fetch_ptw
            << " fetch_l1i=" << empty_fetch_l1i
            << " fetch_uncached=" << empty_fetch_uncached
            << " fetch_translate=" << empty_fetch_translate
            << " request_backpressure=" << empty_request_backpressure
            << " response_complete=" << empty_response_complete
            << " outstanding_other=" << empty_outstanding_other
            << " no_current_sector=" << empty_no_current_sector
            << " current_sector_no_lane=" << empty_current_sector_no_lane
            << " inactive=" << empty_inactive
            << " other=" << empty_other << '\n';
        std::cout
            << "HOST FRONTEND OVERLAP empty=" << frontend_empty
            << " current_sector_missing=" << overlap_current_sector_missing
            << " following_sector_missing="
            << overlap_following_sector_missing
            << " l1i_busy=" << overlap_l1i_busy
            << " fetch_queue_nonempty=" << overlap_fetch_queue_nonempty
            << " pending_request=" << overlap_pending_request
            << " pair_pending=" << overlap_pair_pending
            << " bp_fetch_stall=" << overlap_bp_fetch_stall
            << " request_fire=" << overlap_request_fire
            << " response_match=" << overlap_response_match << '\n';
        std::cout
            << "HOST BRANCH BREAKDOWN resolutions=" << branch_resolutions
            << " conditional=" << conditional_resolutions
            << " jumps=" << jump_resolutions
            << " direction_misses_conditional="
            << conditional_direction_misses
            << " direction_misses_jump=" << jump_direction_misses
            << " target_misses_conditional=" << conditional_target_misses
            << " target_misses_jump=" << jump_target_misses
            << " predicted_redirects=" << predicted_redirects
            << " direction_redirects=" << direction_redirects
            << " control_flushes=" << control_flushes << '\n';
        std::cout
            << "HOST TARGET DELIVERY semantics=zero_bubble_to_fetch_valid"
            << " source_precedence=chained_redirect,resident_fetch_line,"
               "alternate_fal,translation_ptw,l1i_miss,l1i_hit"
            << " translation=itlb_miss_or_fetch_ptw"
            << " predictions=" << predicted_redirects
            << " delivered=" << target_deliveries
            << " superseded_control=" << target_superseded_control
            << " superseded_prediction=" << target_superseded_prediction
            << " pending=" << pending_target.valid
            << " accounted="
            << target_deliveries + target_superseded_control +
                   target_superseded_prediction + pending_target.valid
            << " 0=" << target_latency[0]
            << " 1=" << target_latency[1]
            << " 2=" << target_latency[2]
            << " 3=" << target_latency[3]
            << " 4-7=" << target_latency[4]
            << " 8+=" << target_latency[5] << '\n';
        for (unsigned source_index = 0;
             source_index < kTargetSourceCount; ++source_index) {
            const auto source =
                static_cast<TargetSource>(source_index);
            const auto& histogram =
                target_latency_by_source[source_index];
            const uint64_t total =
                histogram[0] + histogram[1] + histogram[2] +
                histogram[3] + histogram[4] + histogram[5];
            std::cout
                << "HOST TARGET DELIVERY SOURCE source="
                << target_source_name(source)
                << " total=" << total
                << " 0=" << histogram[0]
                << " 1=" << histogram[1]
                << " 2=" << histogram[2]
                << " 3=" << histogram[3]
                << " 4-7=" << histogram[4]
                << " 8+=" << histogram[5] << '\n';
        }
        uint64_t l1i_hit_exact_total = 0;
        for (const uint64_t count : l1i_hit_exact_latency)
            l1i_hit_exact_total += count;
        std::cout
            << "HOST TARGET DELIVERY L1I HIT EXACT"
            << " total=" << l1i_hit_exact_total
            << " 0=" << l1i_hit_exact_latency[0]
            << " 1=" << l1i_hit_exact_latency[1]
            << " 2=" << l1i_hit_exact_latency[2]
            << " 3=" << l1i_hit_exact_latency[3]
            << " 4=" << l1i_hit_exact_latency[4]
            << " 5=" << l1i_hit_exact_latency[5]
            << " 6=" << l1i_hit_exact_latency[6]
            << " 7=" << l1i_hit_exact_latency[7]
            << " 8+=" << l1i_hit_exact_latency[8] << '\n';
        std::cout
            << "HOST TARGET DELIVERY REDIRECT PENDING"
            << " redirects=" << predicted_redirects
            << " pending_valid=" << redirect_pending_valid
            << " target_line=" << redirect_pending_target_line
            << " fallthrough_line="
            << redirect_pending_fallthrough_line
            << " line_bytes=32 observations=orthogonal\n";
        if (pending_target.valid)
            write_target_trace(pending_target, "pending",
                               "undelivered");
        if (target_trace)
            target_trace->flush();
    }
};

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

    const bool fetch_carousel =
        FETCH3P(measurement_carousel_enabled);
    const unsigned fetch_line_depth = fetch_carousel ? 4U : 2U;
    bool fetch_pending_valid = false;
    uint64_t fetch_pending_addr = 0;
    for (unsigned slot = 0; slot < fetch_line_depth; ++slot) {
        const bool slot_valid = fetch_carousel
            ? FETCH3P(carousel_pending_valid_q)[slot] != 0
            : slot == 0 && FETCH3P(pending_valid_q);
        if (slot_valid && !fetch_pending_valid) {
            fetch_pending_valid = true;
            fetch_pending_addr = fetch_carousel
                ? FETCH3P(carousel_pending_addr_q)[slot]
                : FETCH3P(pending_addr_q);
        }
    }

    const auto& trace_pcs =
        root->tb_opensbi__DOT__dut__DOT__u_core__DOT__three_trace_pcs;
    const auto& trace_instrs =
        root->tb_opensbi__DOT__dut__DOT__u_core__DOT__three_trace_instrs;
    unsigned retire_valid = 0;
    unsigned retire_complete = 0;
    unsigned window_valid = 0;
    unsigned window_issued = 0;
    unsigned fetch_queue_count = 0;
    for (unsigned index = 0; index < 4; ++index)
        fetch_queue_count += BUS3P(fetch_state_q)[index] != 0;
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
           << static_cast<unsigned>(CORE3P(bp_branch_allocate) &&
                                    CORE3P(bp_prediction_taken))
           << " fetch=" << static_cast<unsigned>(CORE3P(fetch_decode_valid))
           << " fetchq="
           << static_cast<unsigned>(CORE3P(fetch_pipe_req_valid))
           << '/' << static_cast<unsigned>(CORE3P(fetch_pipe_req_ready))
           << '/' << static_cast<unsigned>(BUS3P(l1i_resp_valid))
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
           << static_cast<unsigned>(fetch_pending_valid)
           << '/' << std::hex << std::setw(16)
           << fetch_pending_addr
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
           << ",slots=";
    for (unsigned slot = 0; slot < fetch_line_depth; ++slot) {
        if (slot != 0)
            stream << ':';
        stream << std::dec
               << static_cast<unsigned>(FETCH3P(line_valid_q)[slot])
               << '/' << std::hex << std::setw(16)
               << static_cast<uint64_t>(FETCH3P(line_addr_q)[slot])
               << '/' << std::dec
               << static_cast<unsigned>(
                      FETCH3P(line_sector_valid_q)[slot])
               << '/'
               << static_cast<unsigned>(
                      fetch_carousel
                          ? FETCH3P(carousel_pending_valid_q)[slot]
                          : slot == 0 && FETCH3P(pending_valid_q))
               << '/' << std::hex << std::setw(16)
               << static_cast<uint64_t>(
                      fetch_carousel
                          ? FETCH3P(carousel_pending_addr_q)[slot]
                          : FETCH3P(pending_addr_q));
    }
    stream
           << ",hit=" << static_cast<unsigned>(
                      FETCH3P(consume_sector_valid) & 1U)
           << '/' << static_cast<unsigned>(
                      FETCH3P(following_sector_valid) & 1U)
           << ",lanes=" << static_cast<unsigned>(FETCH3P(lane_found_r))
           << ",reqfire=" << static_cast<unsigned>(FETCH3P(req_fire))
           << '/' << static_cast<unsigned>(FETCH3P(ras_req_fire))
           << '/' << static_cast<unsigned>(FETCH3P(pair_req_fire))
           << ",need=" << static_cast<unsigned>(
                      FETCH3P(demand_request_needed))
           << '/' << static_cast<unsigned>(FETCH3P(request_line_hit))
           << '/' << static_cast<unsigned>(
                      FETCH3P(request_line_pending))
           << ",respmatch=" << static_cast<unsigned>(FETCH3P(resp_match))
           << '/' << static_cast<unsigned>(
                      FETCH3P(carousel_resp_match))
           << '/' << static_cast<unsigned>(
                      FETCH3P(carousel_resp_in_window))
           << ",pair=" << static_cast<unsigned>(
                      FETCH3P(pair_predicted_valid_q))
           << '/' << static_cast<unsigned>(
                      FETCH3P(pair_unpredicted_valid_q))
           << ",next=" << std::hex << std::setw(16)
           << static_cast<uint64_t>(FETCH3P(next_req_addr_q))
           << ",ras=" << std::dec
           << static_cast<unsigned>(FETCH3P(ras_line_valid_q))
           << '/' << static_cast<unsigned>(FETCH3P(ras_line_pending_q))
           << '/' << std::hex << std::setw(16)
           << static_cast<uint64_t>(FETCH3P(ras_line_addr_q))
           << ",fal=" << std::dec
           << static_cast<unsigned>(FETCH3P(fal_line_valid_q))
           << '/' << static_cast<unsigned>(FETCH3P(fal_line_pending_q))
           << '/' << std::hex << std::setw(16)
           << static_cast<uint64_t>(FETCH3P(fal_line_addr_q))
           << '}';
    stream << " bus{fq=" << std::dec
           << static_cast<unsigned>(BUS3P(fetch_head_q)) << ':'
           << static_cast<unsigned>(BUS3P(fetch_tail_q)) << ':'
           << fetch_queue_count
           << ",pop=" << static_cast<unsigned>(BUS3P(fetch_pop))
           << ",l1req="
           << static_cast<unsigned>(BUS3P(l1i_req_active_q)) << '/'
           << static_cast<unsigned>(BUS3P(l1i_req_valid)) << '/'
           << static_cast<unsigned>(BUS3P(l1i_req_fire))
           << ",l1resp="
           << static_cast<unsigned>(BUS3P(l1i_resp_valid)) << '/'
           << static_cast<unsigned>(BUS3P(l1i_resp_valid)) << '/'
           << static_cast<unsigned>(BUS3P(l1i_resp_tag))
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
               << static_cast<unsigned>(BUS3P(fetch_cancelled_q)[index]);
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
    const char* const mtimecmp_subtract_text =
        plusarg_value(argc, argv, "+mtimecmp_subtract=");
    const char* const mtimecmp_add_text =
        plusarg_value(argc, argv, "+mtimecmp_add=");
    const char* const pipeline_trace_path =
        plusarg_value(argc, argv, "+pipeline_trace=");
    const char* const target_delivery_trace_path =
        plusarg_value(argc, argv, "+target_delivery_trace=");
    const char* const l2_tlb_probe_path =
        plusarg_value(argc, argv, "+l2_tlb_probe=");
    const char* const l1d_probe_path =
        plusarg_value(argc, argv, "+l1d_probe=");
    const char* const suppress_l1d_prefetch_cycle_text =
        plusarg_value(argc, argv, "+suppress_l1d_prefetch_cycle=");
    const char* const retire3_trace_path =
        plusarg_value(argc, argv, "+retire3_trace=");
    const char* const l2_tlb_invalidate_way_text =
        plusarg_value(argc, argv, "+l2_tlb_invalidate_way=");
    const char* const l2_tlb_invalidate_set_text =
        plusarg_value(argc, argv, "+l2_tlb_invalidate_set=");
    const bool checkpoint_exit =
        has_plusarg(argc, argv, "+checkpoint_exit");
    const bool frontend_breakdown_enabled =
        has_plusarg(argc, argv, "+frontend_breakdown") ||
        target_delivery_trace_path;
    const bool l2_tlb_disable =
        has_plusarg(argc, argv, "+l2_tlb_disable");
    if ((l2_tlb_invalidate_way_text == nullptr) !=
        (l2_tlb_invalidate_set_text == nullptr)) {
        std::cerr << "+l2_tlb_invalidate_way and "
                     "+l2_tlb_invalidate_set must be used together\n";
        return EXIT_FAILURE;
    }
    if (mtimecmp_subtract_text && mtimecmp_add_text) {
        std::cerr << "+mtimecmp_subtract and +mtimecmp_add are mutually "
                     "exclusive\n";
        return EXIT_FAILURE;
    }
    const uint32_t checkpoint_cycle =
        checkpoint_path
            ? parse_cycle(checkpoint_cycles_text, "+checkpoint_cycles")
            : 0;
    const uint32_t stop_cycle =
        stop_cycles_text ? parse_cycle(stop_cycles_text, "+stop_cycles") : 0;
    const uint32_t suppress_l1d_prefetch_cycle =
        suppress_l1d_prefetch_cycle_text
            ? parse_cycle(suppress_l1d_prefetch_cycle_text,
                          "+suppress_l1d_prefetch_cycle")
            : 0;

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
        if (mtimecmp_subtract_text) {
            const uint32_t delta =
                parse_cycle(mtimecmp_subtract_text,
                            "+mtimecmp_subtract");
            auto& mtimecmp =
                top->rootp->
                    tb_opensbi__DOT__dut__DOT__u_clint__DOT__mtimecmp_q;
            const uint64_t old_mtimecmp = mtimecmp;
            mtimecmp -= delta;
            top->eval();
            std::cout << "MTIMECMP ADJUST old=" << old_mtimecmp
                      << " new=" << mtimecmp
                      << " mtime="
                      << top->rootp->
                             tb_opensbi__DOT__dut__DOT__u_clint__DOT__mtime_q
                      << " subtract=" << delta << '\n';
        }
        if (mtimecmp_add_text) {
            const uint32_t delta =
                parse_cycle(mtimecmp_add_text, "+mtimecmp_add");
            auto& mtimecmp =
                top->rootp->
                    tb_opensbi__DOT__dut__DOT__u_clint__DOT__mtimecmp_q;
            const uint64_t old_mtimecmp = mtimecmp;
            mtimecmp += delta;
            top->eval();
            std::cout << "MTIMECMP ADJUST old=" << old_mtimecmp
                      << " new=" << mtimecmp
                      << " mtime="
                      << top->rootp->
                             tb_opensbi__DOT__dut__DOT__u_clint__DOT__mtime_q
                      << " add=" << delta << '\n';
        }
    } else {
        if (mtimecmp_subtract_text || mtimecmp_add_text) {
            std::cerr << "+mtimecmp_subtract and +mtimecmp_add require "
                         "+restore\n";
            return EXIT_FAILURE;
        }
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

    std::ofstream target_delivery_trace;
    if (target_delivery_trace_path) {
        target_delivery_trace.open(target_delivery_trace_path);
        if (!target_delivery_trace) {
            std::cerr << "Unable to open target delivery trace: "
                      << target_delivery_trace_path << '\n';
            return EXIT_FAILURE;
        }
        std::cout << "TRACE OPENED name=target_delivery path="
                  << target_delivery_trace_path << '\n';
    }

    std::ofstream l2_tlb_probe_stream;
    std::unique_ptr<L2TlbProbe> l2_tlb_probe;
    if (l2_tlb_probe_path) {
        l2_tlb_probe_stream.open(l2_tlb_probe_path);
        if (!l2_tlb_probe_stream) {
            std::cerr << "Unable to open L2 TLB probe: "
                      << l2_tlb_probe_path << '\n';
            return EXIT_FAILURE;
        }
        l2_tlb_probe =
            std::make_unique<L2TlbProbe>(l2_tlb_probe_stream);
        std::cout << "TRACE OPENED name=l2_tlb path="
                  << l2_tlb_probe_path << '\n';
    }
    if (l2_tlb_disable)
        std::cout << "L2 TLB DIAGNOSTIC DISABLE enabled\n";
    std::unique_ptr<L2TlbEntryInvalidator> l2_tlb_entry_invalidator;
    if (l2_tlb_invalidate_way_text) {
        l2_tlb_entry_invalidator =
            std::make_unique<L2TlbEntryInvalidator>(
                parse_cycle(l2_tlb_invalidate_way_text,
                            "+l2_tlb_invalidate_way"),
                parse_cycle(l2_tlb_invalidate_set_text,
                            "+l2_tlb_invalidate_set"));
        l2_tlb_entry_invalidator->invalidate_now(top.get());
    }

    std::ofstream l1d_probe_stream;
    std::unique_ptr<L1dProbe> l1d_probe;
    if (l1d_probe_path) {
        l1d_probe_stream.open(l1d_probe_path);
        if (!l1d_probe_stream) {
            std::cerr << "Unable to open L1D probe: "
                      << l1d_probe_path << '\n';
            return EXIT_FAILURE;
        }
        l1d_probe = std::make_unique<L1dProbe>(l1d_probe_stream);
        std::cout << "TRACE OPENED name=l1d path="
                  << l1d_probe_path << '\n';
    }

    std::ofstream retire3_trace_stream;
    std::unique_ptr<FullRetireTrace> retire3_trace;
    if (retire3_trace_path) {
        retire3_trace_stream.open(retire3_trace_path);
        if (!retire3_trace_stream) {
            std::cerr << "Unable to open full retire trace: "
                      << retire3_trace_path << '\n';
            return EXIT_FAILURE;
        }
        retire3_trace =
            std::make_unique<FullRetireTrace>(retire3_trace_stream);
        std::cout << "TRACE OPENED name=retire3 path="
                  << retire3_trace_path << '\n';
    }

    bool checkpoint_saved = false;
    bool l1d_prefetch_suppressed = false;
    FrontendBreakdown frontend_breakdown{
        target_delivery_trace_path ? &target_delivery_trace : nullptr};
    while (VL_LIKELY(!context->gotFinish())) {
        context->timeInc(5);
        top->checkpoint_clk_i = !top->checkpoint_clk_i;
        top->eval();
        if (!top->checkpoint_clk_i && l2_tlb_disable) {
            auto& valid =
                top->rootp->
                    tb_opensbi__DOT__dut__DOT__u_core__DOT__g_backend_3p__DOT__u_core_3p__DOT__u_bus__DOT__g_ccx__DOT__u_bus__DOT__u_l2_tlb__DOT__valid_q;
            for (unsigned way = 0; way < 4; ++way)
                valid[way] = 0;
            top->eval();
        }
        if (!top->checkpoint_clk_i && suppress_l1d_prefetch_cycle_text
            && !l1d_prefetch_suppressed
            && top->checkpoint_cycle_o >= suppress_l1d_prefetch_cycle) {
            suppress_l1d_prefetch_launch(top.get());
            l1d_prefetch_suppressed = true;
        }
        if (!top->checkpoint_clk_i && l2_tlb_probe)
            l2_tlb_probe->sample_pre_edge(top.get());
        if (!top->checkpoint_clk_i && l1d_probe)
            l1d_probe->sample_pre_edge(top.get());
        if (!top->checkpoint_clk_i && retire3_trace)
            retire3_trace->sample_pre_edge(top.get());
        if (top->checkpoint_clk_i) {
            if (pipeline_trace)
                write_pipeline_trace(pipeline_trace, top.get());
            if (frontend_breakdown_enabled)
                frontend_breakdown.sample(top.get());
        }

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

    if (frontend_breakdown_enabled)
        frontend_breakdown.report();
    if (l2_tlb_probe)
        l2_tlb_probe->report();
    if (l2_tlb_entry_invalidator)
        l2_tlb_entry_invalidator->report();

    top->final();
    context->statsPrintSummary();
    return 0;
}
