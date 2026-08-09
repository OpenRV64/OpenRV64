#include <algorithm>
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

uint64_t parse_u64(const char* text, const char* option) {
    if (!text || !*text) {
        std::cerr << "Missing " << option << " value\n";
        std::exit(EXIT_FAILURE);
    }

    errno = 0;
    char* end = nullptr;
    const unsigned long long value = std::strtoull(text, &end, 0);
    if (errno != 0 || !end || *end != '\0') {
        std::cerr << "Invalid " << option << " value: " << text << '\n';
        std::exit(EXIT_FAILURE);
    }
    return static_cast<uint64_t>(value);
}

uint64_t hart0_pc(const Vtb_4h_3p___024root* root) {
    return static_cast<uint64_t>(root->tb_4h_3p__DOT__dbg_pc[0]) |
           (static_cast<uint64_t>(root->tb_4h_3p__DOT__dbg_pc[1]) << 32);
}

template <std::size_t N>
uint64_t wide_bits(const VlWide<N>& words, unsigned lsb,
                   unsigned width) {
    uint64_t result = 0;
    unsigned copied = 0;
    while (copied < width) {
        const unsigned bit = lsb + copied;
        const unsigned word = bit / 32;
        const unsigned word_bit = bit % 32;
        const unsigned count = std::min(32U - word_bit, width - copied);
        const uint64_t mask = (uint64_t{1} << count) - 1;
        result |= ((static_cast<uint64_t>(words[word]) >> word_bit) & mask)
                  << copied;
        copied += count;
    }
    return result;
}

template <std::size_t N>
void trace_line_words(std::ostream& stream, const VlWide<N>& words,
                      unsigned lsb = 0) {
    stream << " words=";
    for (unsigned word = 0; word < 8; ++word) {
        if (word)
            stream << ',';
        stream << std::hex << std::setw(16) << std::setfill('0')
               << wide_bits(words, lsb + word * 64, 64);
    }
    stream << std::setfill(' ') << std::dec;
}

template <std::size_t N>
bool line_contains_value(const VlWide<N>& words, uint64_t value,
                         unsigned lsb = 0) {
    for (unsigned word = 0; word < 8; ++word) {
        if (wide_bits(words, lsb + word * 64, 64) == value)
            return true;
    }
    return false;
}

class L1dWatch {
  public:
    L1dWatch(std::ostream& stream, uint64_t vaddr,
             const char* paddr_text, const char* value_text,
             bool trace_all_mshrs)
        : stream_{stream}, vaddr_{vaddr},
          trace_all_mshrs_{trace_all_mshrs} {
        if (paddr_text) {
            paddr_line_ = parse_u64(paddr_text, "+l1d_watch_paddr") & ~63ULL;
            have_paddr_ = true;
        }
        if (value_text) {
            watch_value_ = parse_u64(value_text, "+l1d_watch_value");
            have_watch_value_ = true;
        }
        stream_ << "# OpenRV64 hart-0 L1D watch vaddr=0x"
                << std::hex << vaddr_;
        if (have_paddr_)
            stream_ << " paddr_line=0x" << paddr_line_;
        if (have_watch_value_)
            stream_ << " value=0x" << watch_value_;
        stream_ << " trace_all_mshrs=" << std::dec << trace_all_mshrs_;
        stream_ << std::dec << '\n';
    }

    void trace(const Vtb_4h_3p___024root* root, uint32_t cycle) {
#define H0_CORE(name)                                                       \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__##name
#define H0_LSQ(name)                                                        \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_backend__DOT__u_exec__DOT__g_3p__DOT__u_exec__DOT__u_lsu__DOT__u_lsq__DOT__##name
#define H0_BUS(name)                                                        \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__##name
#define H0_L1D(name)                                                        \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__##name
#define H0_L1D_CACHE(name)                                                  \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__u_l1d__DOT__u_l1__DOT__g_cache__DOT__u_cache__DOT__##name
#define H0_L1D_TAG_MEM(way)                                                 \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__u_l1d__DOT__u_l1__DOT__g_cache__DOT__u_cache__DOT__g_sync_tag_storage__DOT__g_tag_ways__BRA__##way##__KET____DOT__tag_q
#define H0_L1D_DATA_MEM(way, bank)                                          \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__u_l1d__DOT__u_l1__DOT__g_cache__DOT__u_cache__DOT__g_data_ways__BRA__##way##__KET____DOT__g_refill_banks__BRA__##bank##__KET____DOT__data_q
        if (H0_LSQ(xlate_req_fire) &&
            H0_CORE(backend_mem_xlate_vaddr) == vaddr_) {
            const unsigned tag = H0_CORE(backend_mem_xlate_tag);
            xlate_pending_[tag] = true;
            stream_ << "XLATE_REQ cycle=" << cycle
                    << " tag=" << tag
                    << " write="
                    << static_cast<unsigned>(H0_CORE(backend_mem_xlate_write))
                    << " vaddr=0x" << std::hex << vaddr_ << std::dec
                    << '\n';
        }

        if (H0_CORE(backend_mem_xlate_resp_valid) &&
            H0_CORE(backend_mem_xlate_resp_ready)) {
            const unsigned tag = H0_CORE(backend_mem_xlate_resp_tag);
            if (xlate_pending_[tag]) {
                const uint64_t paddr =
                    H0_CORE(backend_mem_xlate_resp_paddr);
                paddr_line_ = paddr & ~63ULL;
                have_paddr_ = true;
                xlate_pending_[tag] = false;
                stream_ << "XLATE_RESP cycle=" << cycle
                        << " tag=" << tag
                        << " paddr=0x" << std::hex << paddr
                        << " line=0x" << paddr_line_ << std::dec
                        << " page_fault="
                        << static_cast<unsigned>(
                               H0_CORE(backend_mem_xlate_resp_page_fault))
                        << " access_fault="
                        << static_cast<unsigned>(
                               H0_CORE(backend_mem_xlate_resp_access_fault))
                        << '\n';
                stream_.flush();
            }
        }

        if (!have_paddr_)
            return;

        trace_mshr_path(root, cycle);

        if (H0_BUS(l1d_request_fire) &&
            same_line(H0_BUS(l1d_req_addr))) {
            const unsigned tag = H0_BUS(l1d_req_tag);
            response_pending_[tag] = true;
            stream_ << "L1D_REQ cycle=" << cycle
                    << " tag=" << tag
                    << " write="
                    << static_cast<unsigned>(H0_BUS(l1d_req_write))
                    << " size="
                    << static_cast<unsigned>(H0_BUS(l1d_req_size))
                    << " addr=0x" << std::hex << H0_BUS(l1d_req_addr)
                    << " wdata=0x" << H0_BUS(l1d_req_rdata)
                    << std::dec << '\n';
        }

        const unsigned target_set =
            static_cast<unsigned>((paddr_line_ >> 6) & 0x3fU);
        const std::array<uint64_t, 4> target_set_tags = {
            H0_L1D_TAG_MEM(0)[target_set], H0_L1D_TAG_MEM(1)[target_set],
            H0_L1D_TAG_MEM(2)[target_set], H0_L1D_TAG_MEM(3)[target_set]};
        const std::array<uint64_t, 4> target_set_word7 = {
            H0_L1D_DATA_MEM(0, 7)[target_set],
            H0_L1D_DATA_MEM(1, 7)[target_set],
            H0_L1D_DATA_MEM(2, 7)[target_set],
            H0_L1D_DATA_MEM(3, 7)[target_set]};
        std::array<bool, 4> target_set_valid{};
        for (unsigned way = 0; way < 4; ++way)
            target_set_valid[way] = H0_L1D_CACHE(valid_q)[target_set * 4 + way];
        if (!target_set_state_initialized_ ||
            target_set_tags != target_set_tags_ ||
            target_set_word7 != target_set_word7_ ||
            target_set_valid != target_set_valid_) {
            stream_ << "CACHE_TARGET_SET cycle=" << cycle
                    << " valid=";
            for (unsigned way = 0; way < 4; ++way)
                stream_ << static_cast<unsigned>(target_set_valid[way]);
            stream_ << " tags=" << std::hex
                    << target_set_tags[0] << ',' << target_set_tags[1] << ','
                    << target_set_tags[2] << ',' << target_set_tags[3]
                    << " word7="
                    << target_set_word7[0] << ',' << target_set_word7[1] << ','
                    << target_set_word7[2] << ',' << target_set_word7[3]
                    << " fill_fire=" << std::dec
                    << static_cast<unsigned>(H0_L1D_CACHE(fill_fire))
                    << " fill_addr=0x" << std::hex << H0_L1D(l1_fill_addr)
                    << " fill_way=" << std::dec
                    << static_cast<unsigned>(H0_L1D_CACHE(fill_way))
                    << '\n';
            target_set_state_initialized_ = true;
            target_set_tags_ = target_set_tags;
            target_set_word7_ = target_set_word7;
            target_set_valid_ = target_set_valid;
        }
        const bool l1_access_target = same_line(H0_L1D(l1_mem_addr));
        const bool l1_access_same_set =
            H0_L1D(l1_mem_write) &&
            (static_cast<unsigned>(H0_L1D_CACHE(access_set_q)) ==
             target_set);
        if (H0_L1D(l1_mem_valid) && H0_L1D(l1_mem_ready) &&
            (l1_access_target || l1_access_same_set)) {
            stream_ << (l1_access_target ? "L1D_ACCESS" :
                                             "L1D_SAME_SET_ACCESS")
                    << " cycle=" << cycle
                    << " write="
                    << static_cast<unsigned>(H0_L1D(l1_mem_write))
                    << " addr=0x" << std::hex << H0_L1D(l1_mem_addr)
                    << " wdata=0x" << H0_L1D(l1_mem_wdata)
                    << " wstrb=0x"
                    << static_cast<unsigned>(H0_L1D(l1_mem_wstrb))
                    << std::dec
                    << " cache_state="
                    << static_cast<unsigned>(H0_L1D_CACHE(state_q))
                    << " cache_updates_line="
                    << static_cast<unsigned>(
                           H0_L1D_CACHE(access_updates_line_q))
                    << " cache_way="
                    << static_cast<unsigned>(H0_L1D_CACHE(access_way_q))
                    << " target_set=" << target_set
                    << " sync_lookup_valid="
                    << static_cast<unsigned>(
                           H0_L1D_CACHE(sync_lookup_valid_q))
                    << " sync_lookup_hit="
                    << static_cast<unsigned>(
                           H0_L1D_CACHE(sync_lookup_hit_comb))
                    << " fill_fire="
                    << static_cast<unsigned>(H0_L1D_CACHE(fill_fire));
            trace_line_words(stream_, H0_L1D(l1_mem_rdata));
            stream_ << '\n';
            trace_buffers(root, cycle);
        }

        if (H0_L1D(response_fire) &&
            H0_L1D(demand_mshr_response_match_r)) {
            const unsigned mshr =
                H0_L1D(demand_mshr_response_index_r);
            if (same_line(H0_L1D(demand_mshr_addr_q)[mshr])) {
                stream_ << "MSHR_RESPONSE cycle=" << cycle
                        << " mshr=" << mshr
                        << " addr=0x" << std::hex
                        << H0_L1D(demand_mshr_addr_q)[mshr]
                        << std::dec << " incoming";
                trace_line_words(stream_, root->tb_4h_3p__DOT__hart_resp_rdata);
                stream_ << " prior";
                trace_line_words(stream_, H0_L1D(demand_mshr_data_q)[mshr]);
                stream_ << '\n';
                trace_buffers(root, cycle);
            }
        }

        if (H0_L1D(prefetch_response_fire)) {
            const unsigned prefetch =
                H0_L1D(prefetch_mshr_response_index_r);
            if (same_line(H0_L1D(prefetch_mshr_addr_q)[prefetch])) {
                stream_ << "PREFETCH_RESPONSE cycle=" << cycle
                        << " index=" << prefetch
                        << " addr=0x" << std::hex
                        << H0_L1D(prefetch_mshr_addr_q)[prefetch]
                        << std::dec
                        << " claim_existing="
                        << static_cast<unsigned>(
                               H0_L1D(prefetch_response_claim_existing))
                        << " claim_new="
                        << static_cast<unsigned>(
                               H0_L1D(prefetch_response_claim_new))
                        << " demand_match="
                        << static_cast<unsigned>(
                               H0_L1D(demand_mshr_prefetch_response_match_r))
                        << " incoming";
                trace_line_words(stream_,
                                 root->tb_4h_3p__DOT__hart_resp_rdata);
                stream_ << '\n';
                trace_buffers(root, cycle);
                stream_.flush();
            }
        }

        if (H0_L1D(demand_mshr_fill_found_r)) {
            const unsigned mshr = H0_L1D(demand_mshr_fill_index_r);
            if (same_line(H0_L1D(demand_mshr_addr_q)[mshr])) {
                stream_ << "MSHR_FILL cycle=" << cycle
                        << " mshr=" << mshr
                        << " addr=0x" << std::hex
                        << H0_L1D(demand_mshr_addr_q)[mshr]
                        << " store_strb=0x"
                        << H0_L1D(demand_mshr_store_strb_q)[mshr]
                        << std::dec << " incoming";
                trace_line_words(stream_, H0_L1D(demand_mshr_data_q)[mshr]);
                stream_ << " overlay";
                trace_line_words(stream_,
                                 H0_L1D(demand_mshr_store_data_q)[mshr]);
                stream_ << " installed";
                trace_line_words(stream_, H0_L1D(demand_fill_data_r));
                stream_ << '\n';
                trace_buffers(root, cycle);
            }
        }

        if (H0_L1D_CACHE(fill_fire) &&
            same_line(H0_L1D(l1_fill_addr))) {
            stream_ << "CACHE_FILL cycle=" << cycle
                    << " addr=0x" << std::hex << H0_L1D(l1_fill_addr)
                    << std::dec
                    << " set="
                    << static_cast<unsigned>(H0_L1D_CACHE(fill_set))
                    << " way="
                    << static_cast<unsigned>(H0_L1D_CACHE(fill_way))
                    << " banks=0x" << std::hex
                    << static_cast<unsigned>(H0_L1D_CACHE(fill_line))
                    << std::dec << " data";
            trace_line_words(stream_, H0_L1D(demand_fill_data_r));
            stream_ << '\n';
            stream_.flush();
        }

        if (H0_L1D_CACHE(fill_fire) &&
            (static_cast<unsigned>(H0_L1D_CACHE(fill_set)) == target_set) &&
            !same_line(H0_L1D(l1_fill_addr))) {
            stream_ << "CACHE_SAME_SET_FILL cycle=" << cycle
                    << " addr=0x" << std::hex << H0_L1D(l1_fill_addr)
                    << std::dec
                    << " set="
                    << static_cast<unsigned>(H0_L1D_CACHE(fill_set))
                    << " way="
                    << static_cast<unsigned>(H0_L1D_CACHE(fill_way))
                    << " target_line=0x" << std::hex << paddr_line_
                    << std::dec << " data";
            trace_line_words(stream_, H0_L1D(demand_fill_data_r));
            stream_ << '\n';
        }

        if (H0_L1D(l1_response_fire) &&
            same_line(H0_L1D(request_addr_q))) {
            stream_ << "L1D_RESPONSE cycle=" << cycle
                    << " addr=0x" << std::hex << H0_L1D(request_addr_q)
                    << " data=0x" << H0_L1D(normal_response_merged_data_r)
                    << std::dec
                    << " write="
                    << static_cast<unsigned>(H0_L1D(request_write_q))
                    << " demand="
                    << static_cast<unsigned>(H0_L1D(request_demand_q))
                    << '\n';
        }

        if (H0_CORE(backend_mem_resp_valid) &&
            H0_CORE(backend_mem_resp_ready)) {
            const unsigned tag = H0_CORE(backend_mem_resp_tag);
            if (response_pending_[tag]) {
                stream_ << "BACKEND_RESPONSE cycle=" << cycle
                        << " tag=" << tag
                        << " rdata=0x" << std::hex
                        << H0_CORE(backend_mem_rdata);
                const unsigned response_identity =
                    static_cast<unsigned>(H0_L1D(l1_resp_identity));
                const unsigned overlay_tag = response_identity & 0x7U;
                const unsigned response_epoch = response_identity >> 3;
                if (H0_L1D(demand_response_valid)) {
                    const unsigned demand_tag = static_cast<unsigned>(
                        H0_L1D(demand_waiter_response_tag_r));
                    const unsigned demand_word = static_cast<unsigned>(
                        H0_L1D(tag_overlay_word_q)[demand_tag]);
                    stream_ << " source=demand"
                            << " demand_tag=" << std::dec << demand_tag
                            << " demand_mshr="
                            << static_cast<unsigned>(
                                   H0_L1D(demand_waiter_response_mshr_r))
                            << " demand_word=" << demand_word
                            << " demand_data=0x" << std::hex
                            << wide_bits(H0_L1D(demand_response_data_r),
                                         demand_word * 64, 64)
                            << std::dec;
                } else if (H0_L1D(normal_response_valid)) {
                    stream_ << " source=normal"
                            << " resident_tag=" << std::dec << overlay_tag
                            << " sync_hit_response="
                            << static_cast<unsigned>(
                                   H0_L1D_CACHE(sync_lookup_hit_response))
                            << " sync_hit="
                            << static_cast<unsigned>(
                                   H0_L1D_CACHE(sync_lookup_hit_comb))
                            << " sync_way="
                            << static_cast<unsigned>(
                                   H0_L1D_CACHE(sync_lookup_way_comb))
                            << " sync_set="
                            << static_cast<unsigned>(
                                   H0_L1D_CACHE(sync_lookup_set_q))
                            << " sync_valid=0x" << std::hex
                            << static_cast<unsigned>(
                                   H0_L1D_CACHE(sync_lookup_valid_bits_q))
                            << " sync_tag=0x"
                            << H0_L1D_CACHE(sync_lookup_tag_q)
                            << " sync_tags=0x"
                            << H0_L1D_CACHE(sync_tag_read_q)[0] << ",0x"
                            << H0_L1D_CACHE(sync_tag_read_q)[1] << ",0x"
                            << H0_L1D_CACHE(sync_tag_read_q)[2] << ",0x"
                            << H0_L1D_CACHE(sync_tag_read_q)[3]
                            << " sync_hit_data=0x"
                            << H0_L1D_CACHE(sync_lookup_hit_data)
                            << " raw=0x"
                            << H0_L1D_CACHE(response_data_q)
                            << " merged=0x"
                            << H0_L1D(normal_response_merged_data_r)
                            << std::dec
                            << " overlay_needed="
                            << static_cast<unsigned>(
                                   H0_L1D(normal_overlay_needed))
                            << " overlay_owner_match="
                            << static_cast<unsigned>(
                                   H0_L1D(normal_overlay_owner_match))
                            << " overlay_ready="
                            << static_cast<unsigned>(
                                   H0_L1D(normal_overlay_ready))
                            << " overlay_read_match="
                            << static_cast<unsigned>(
                                   H0_L1D(normal_overlay_read_match))
                            << " overlay_bypass_match="
                            << static_cast<unsigned>(
                                   H0_L1D(normal_overlay_bypass_match))
                            << " word="
                            << static_cast<unsigned>(
                                   H0_L1D(tag_overlay_word_q)[overlay_tag])
                            << " response_epoch="
                            << response_epoch
                            << " current_epoch="
                            << static_cast<unsigned>(
                                   H0_L1D(tag_overlay_epoch_q))
                            << " owner_epoch="
                            << static_cast<unsigned>(
                                   H0_L1D(tag_overlay_owner_epoch_q)[
                                       overlay_tag])
                            << " mem_epoch="
                            << static_cast<unsigned>(
                                   H0_L1D(tag_overlay_mem_epoch_q)[
                                       overlay_tag])
                            << " read_tag="
                            << static_cast<unsigned>(
                                   H0_L1D(tag_overlay_read_tag_q))
                            << " read_epoch="
                            << static_cast<unsigned>(
                                   H0_L1D(tag_overlay_read_epoch_q))
                            << " read_mem_epoch="
                            << static_cast<unsigned>(
                                   H0_L1D(tag_overlay_read_mem_epoch_q))
                            << " cache_response_way="
                            << static_cast<unsigned>(
                                   H0_L1D_CACHE(response_way_q))
                            << " cache_response_hit="
                            << static_cast<unsigned>(
                                   H0_L1D_CACHE(response_hit_q))
                            << " cache_response_data=0x" << std::hex
                            << H0_L1D_CACHE(response_data_q)
                            << " overlay_strb=0x"
                            << wide_bits(H0_L1D(normal_overlay_data), 0, 64)
                            << std::dec;
                } else {
                    stream_ << " source=freeloader"
                            << " valid=" << std::dec
                            << static_cast<unsigned>(
                                   H0_L1D(freeloader_valid_q)[0])
                            << " freeloader_tag="
                            << static_cast<unsigned>(
                                   H0_L1D(freeloader_tag_q)[0])
                            << " freeloader_data=0x" << std::hex
                            << H0_L1D(freeloader_data_q)[0]
                            << std::dec;
                }
                stream_ << '\n';
                response_pending_[tag] = false;
                stream_.flush();
            }
        }

        if (H0_CORE(trap_enter)) {
            stream_ << "TRAP cycle=" << cycle
                    << " cause="
                    << static_cast<unsigned>(H0_CORE(trap_cause))
                    << " epc=0x" << std::hex << H0_CORE(trap_pc)
                    << std::dec << '\n';
            stream_.flush();
        }
#undef H0_L1D_CACHE
#undef H0_L1D_DATA_MEM
#undef H0_L1D_TAG_MEM
#undef H0_L1D
#undef H0_BUS
#undef H0_LSQ
#undef H0_CORE
    }

  private:
    struct OutstandingMshr {
        bool valid = false;
        bool prefetch = false;
        uint64_t addr = 0;
        uint32_t issue_cycle = 0;
        unsigned index = 0;
    };

    bool same_line(uint64_t addr) const {
        return (addr & ~63ULL) == paddr_line_;
    }

    template <std::size_t N>
    bool contains_watch_value(const VlWide<N>& words,
                              unsigned lsb = 0) const {
        return have_watch_value_ &&
               line_contains_value(words, watch_value_, lsb);
    }

    void trace_mshr_path(const Vtb_4h_3p___024root* root,
                         uint32_t cycle) {
#define H0_L1D(name)                                                        \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__##name
#define L2(name) root->tb_4h_3p__DOT__u_l2__DOT__##name
        if (H0_L1D(command_fire) &&
            (H0_L1D(request_demand_q) ||
             H0_L1D(request_prefetch_q))) {
            const unsigned txn = H0_L1D(request_txn_id_q);
            const bool prefetch = H0_L1D(request_prefetch_q);
            const unsigned index = prefetch ?
                H0_L1D(request_prefetch_mshr_q) :
                H0_L1D(request_demand_mshr_q);
            if (l1_outstanding_[txn].valid) {
                stream_ << "L1_MSHR_TXN_REUSE cycle=" << cycle
                        << " txn=" << txn
                        << " old_addr=0x" << std::hex
                        << l1_outstanding_[txn].addr
                        << " new_addr=0x" << H0_L1D(request_addr_q)
                        << std::dec << '\n';
            }
            l1_outstanding_[txn] = {
                true, prefetch, H0_L1D(request_addr_q), cycle, index};
            if (trace_all_mshrs_ || same_line(H0_L1D(request_addr_q))) {
                stream_ << "L1_MSHR_OUT cycle=" << cycle
                        << " type=" << (prefetch ? "prefetch" : "demand")
                        << " index=" << index
                        << " txn=" << txn
                        << " addr=0x" << std::hex
                        << H0_L1D(request_addr_q)
                        << std::dec
                        << " target="
                        << same_line(H0_L1D(request_addr_q)) << '\n';
            }
        }

        if (H0_L1D(response_fire)) {
            const unsigned txn =
                root->tb_4h_3p__DOT__hart_resp_txn_id & 0xfU;
            const bool value_match = contains_watch_value(
                root->tb_4h_3p__DOT__hart_resp_rdata);
            const bool target = l1_outstanding_[txn].valid &&
                same_line(l1_outstanding_[txn].addr);
            if (trace_all_mshrs_ || target || value_match) {
                stream_ << "L1_MSHR_IN cycle=" << cycle
                        << " txn=" << txn
                        << " tracked=" << l1_outstanding_[txn].valid;
                if (l1_outstanding_[txn].valid) {
                    stream_ << " type="
                            << (l1_outstanding_[txn].prefetch ?
                                "prefetch" : "demand")
                            << " index=" << l1_outstanding_[txn].index
                            << " issue_cycle="
                            << l1_outstanding_[txn].issue_cycle
                            << " addr=0x" << std::hex
                            << l1_outstanding_[txn].addr << std::dec;
                }
                stream_ << " target=" << target
                        << " value_match=" << value_match;
                if (target || value_match)
                    trace_line_words(
                        stream_, root->tb_4h_3p__DOT__hart_resp_rdata);
                stream_ << '\n';
            }
            l1_outstanding_[txn].valid = false;
        }

        if (root->tb_4h_3p__DOT__l2_req_valid &&
            (root->tb_4h_3p__DOT__hart_req_ready & 1U) &&
            (trace_all_mshrs_ ||
             same_line(root->tb_4h_3p__DOT__l2_req_addr))) {
            stream_ << "L2_REQ_IN cycle=" << cycle
                    << " txn="
                    << static_cast<unsigned>(
                           root->tb_4h_3p__DOT__icx_req_txn_id)
                    << " source="
                    << static_cast<unsigned>(
                           root->tb_4h_3p__DOT__icx_req_source_id)
                    << " op="
                    << static_cast<unsigned>(
                           root->tb_4h_3p__DOT__icx_req_op)
                    << " size="
                    << static_cast<unsigned>(
                           root->tb_4h_3p__DOT__icx_req_size)
                    << " addr=0x" << std::hex
                    << root->tb_4h_3p__DOT__l2_req_addr << std::dec
                    << " target="
                    << same_line(root->tb_4h_3p__DOT__l2_req_addr)
                    << '\n';
        }

        if (L2(lookup_dispatch_r) && L2(lookup_valid_q)) {
            const bool target = same_line(L2(lookup_addr_q));
            const bool value_match = L2(lookup_hit_r) &&
                contains_watch_value(L2(lookup_hit_payload));
            if (target || value_match) {
                stream_ << "L2_LOOKUP cycle=" << cycle
                        << " txn="
                        << static_cast<unsigned>(L2(lookup_txn_id_q))
                        << " source="
                        << static_cast<unsigned>(L2(lookup_source_id_q))
                        << " op="
                        << static_cast<unsigned>(L2(lookup_op_q))
                        << " addr=0x" << std::hex << L2(lookup_addr_q)
                        << std::dec
                        << " action="
                        << static_cast<unsigned>(L2(lookup_action_r))
                        << " hit="
                        << static_cast<unsigned>(L2(lookup_hit_r))
                        << " hit_way="
                        << static_cast<unsigned>(L2(lookup_hit_way_r))
                        << " mshr_match="
                        << static_cast<unsigned>(L2(lookup_mshr_match_r))
                        << " mshr_index="
                        << static_cast<unsigned>(L2(lookup_mshr_index_r))
                        << " free_index="
                        << static_cast<unsigned>(L2(mshr_free_index_r))
                        << " value_match=" << value_match;
                if (L2(lookup_hit_r)) {
                    stream_ << " hit_data";
                    trace_line_words(stream_, L2(lookup_hit_payload));
                }
                stream_ << '\n';
            }
        }

        if (L2(bus_request_fire)) {
            const unsigned mshr = L2(bus_candidate_mshr_r);
            const bool target = same_line(L2(mshr_line_addr_q)[mshr]) ||
                same_line(root->tb_4h_3p__DOT__bus_req_addr);
            const bool value_match =
                root->tb_4h_3p__DOT__bus_req_write &&
                contains_watch_value(
                    root->tb_4h_3p__DOT__bus_req_wdata);
            stream_ << "L2_MSHR_BUS_OUT cycle=" << cycle
                    << " mshr=" << mshr
                    << " action="
                    << static_cast<unsigned>(L2(bus_candidate_action_r))
                    << " state="
                    << static_cast<unsigned>(L2(mshr_state_q)[mshr])
                    << " line=0x" << std::hex
                    << L2(mshr_line_addr_q)[mshr]
                    << " bus_addr=0x"
                    << root->tb_4h_3p__DOT__bus_req_addr
                    << std::dec
                    << " write="
                    << static_cast<unsigned>(
                           root->tb_4h_3p__DOT__bus_req_write)
                    << " target=" << target
                    << " value_match=" << value_match;
            if (target || value_match) {
                stream_ << " wdata";
                trace_line_words(stream_,
                                 root->tb_4h_3p__DOT__bus_req_wdata);
            }
            stream_ << '\n';
        }

        if (L2(bus_response_fire)) {
            const unsigned track = L2(bus_track_head_q);
            const unsigned mshr = L2(bus_track_mshr_q)[track];
            const unsigned action = L2(bus_track_action_q)[track];
            const bool target = same_line(L2(mshr_line_addr_q)[mshr]);
            const bool value_match = contains_watch_value(
                root->tb_4h_3p__DOT__bus_resp_rdata);
            stream_ << "L2_MSHR_BUS_IN cycle=" << cycle
                    << " track=" << track
                    << " mshr=" << mshr
                    << " action=" << action
                    << " line=0x" << std::hex
                    << L2(mshr_line_addr_q)[mshr] << std::dec
                    << " target=" << target
                    << " value_match=" << value_match;
            if (target || value_match) {
                stream_ << " rdata";
                trace_line_words(stream_,
                                 root->tb_4h_3p__DOT__bus_resp_rdata);
            }
            stream_ << '\n';
        }

        if (L2(response_enqueue)) {
            const unsigned replay_mshr = L2(replay_candidate_mshr_r);
            const auto& data = L2(hit_enqueue) ? L2(hit_data_q) :
                L2(mshr_replay_data_q)[replay_mshr];
            const bool target = same_line(L2(enqueue_addr));
            const bool value_match = contains_watch_value(data);
            if (target || value_match) {
                stream_ << "L2_RESPONSE_ENQUEUE cycle=" << cycle
                        << " source="
                        << (L2(hit_enqueue) ? "hit" : "mshr")
                        << " replay_mshr=" << replay_mshr
                        << " addr=0x" << std::hex << L2(enqueue_addr)
                        << std::dec
                        << " target=" << target
                        << " value_match=" << value_match
                        << " data";
                trace_line_words(stream_, data);
                stream_ << '\n';
            }
        }

        for (unsigned mshr = 0; mshr < 8; ++mshr) {
            const bool valid = L2(mshr_valid_q)[mshr];
            const unsigned state = L2(mshr_state_q)[mshr];
            const uint64_t line = L2(mshr_line_addr_q)[mshr];
            if (l2_state_initialized_ &&
                (valid != l2_valid_[mshr] ||
                 state != l2_state_[mshr] ||
                 line != l2_line_[mshr]) &&
                (same_line(line) || same_line(l2_line_[mshr]))) {
                stream_ << "L2_MSHR_STATE cycle=" << cycle
                        << " mshr=" << mshr
                        << " old=" << l2_valid_[mshr] << ':'
                        << l2_state_[mshr] << ":0x" << std::hex
                        << l2_line_[mshr]
                        << " new=" << std::dec << valid << ':' << state
                        << ":0x" << std::hex << line << std::dec << '\n';
            }
            l2_valid_[mshr] = valid;
            l2_state_[mshr] = state;
            l2_line_[mshr] = line;
        }
        l2_state_initialized_ = true;

        if ((cycle & 0x3fffU) == 0)
            stream_.flush();
#undef L2
#undef H0_L1D
    }

    void trace_buffers(const Vtb_4h_3p___024root* root,
                       uint32_t cycle) {
#define H0_L1D(name)                                                        \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__##name
        for (unsigned mshr = 0; mshr < 3; ++mshr) {
            if (!H0_L1D(demand_mshr_valid_q)[mshr] ||
                !same_line(H0_L1D(demand_mshr_addr_q)[mshr]))
                continue;
            stream_ << "MSHR_STATE cycle=" << cycle
                    << " index=" << mshr
                    << " issued="
                    << static_cast<unsigned>(
                           H0_L1D(demand_mshr_issued_q)[mshr])
                    << " complete="
                    << static_cast<unsigned>(
                           H0_L1D(demand_mshr_complete_q)[mshr])
                    << " fill_done="
                    << static_cast<unsigned>(
                           H0_L1D(demand_mshr_fill_done_q)[mshr])
                    << " strb=0x" << std::hex
                    << H0_L1D(demand_mshr_store_strb_q)[mshr]
                    << std::dec << " data";
            trace_line_words(stream_, H0_L1D(demand_mshr_data_q)[mshr]);
            stream_ << '\n';
        }
        for (unsigned index = 0; index < 8; ++index) {
            if (H0_L1D(fill_buffer_valid_q)[index] &&
                same_line(H0_L1D(fill_buffer_addr_q)[index])) {
                stream_ << "FILL_BUFFER cycle=" << cycle
                        << " index=" << index << " data";
                trace_line_words(stream_, H0_L1D(fill_buffer_data_q)[index]);
                stream_ << '\n';
            }
            if (H0_L1D(store_buffer_valid_q)[index] &&
                same_line(H0_L1D(store_buffer_addr_q)[index])) {
                stream_ << "STORE_BUFFER cycle=" << cycle
                        << " index=" << index
                        << " strb=0x" << std::hex
                        << H0_L1D(store_buffer_strb_q)[index]
                        << std::dec << " data";
                trace_line_words(stream_, H0_L1D(store_buffer_data_q)[index]);
                stream_ << '\n';
            }
        }
#undef H0_L1D
    }

    std::ostream& stream_;
    uint64_t vaddr_ = 0;
    uint64_t paddr_line_ = 0;
    uint64_t watch_value_ = 0;
    bool have_paddr_ = false;
    bool have_watch_value_ = false;
    bool trace_all_mshrs_ = false;
    std::array<bool, 8> xlate_pending_{};
    std::array<bool, 8> response_pending_{};
    bool target_set_state_initialized_ = false;
    std::array<bool, 4> target_set_valid_{};
    std::array<uint64_t, 4> target_set_tags_{};
    std::array<uint64_t, 4> target_set_word7_{};
    std::array<OutstandingMshr, 16> l1_outstanding_{};
    bool l2_state_initialized_ = false;
    std::array<bool, 8> l2_valid_{};
    std::array<unsigned, 8> l2_state_{};
    std::array<uint64_t, 8> l2_line_{};
};

void trace_hart0_pc(std::ostream& stream,
                    const Vtb_4h_3p___024root* root,
                    uint32_t cycle) {
    constexpr unsigned result_width = 457;
    constexpr unsigned instr_lsb = 233;
    constexpr unsigned pc_lsb = 329;
    const uint8_t retire =
        root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__backend_retire_arch;
    const auto& results =
        root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_backend__DOT__queue_retire_result;
    const unsigned priv =
        root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_csrs__DOT__priv_mode_q;
    for (unsigned lane = 0; lane < 3; ++lane) {
        if ((retire & (1U << lane)) == 0)
            continue;
        stream << "RET cycle=" << cycle
               << " hart=0 lane=" << lane
               << " priv=" << priv
               << " pc=" << std::hex << std::setw(16)
               << std::setfill('0')
               << wide_bits(results, lane * result_width + pc_lsb, 64)
               << " instr=" << std::setw(8)
               << wide_bits(results, lane * result_width + instr_lsb, 32)
               << std::setfill(' ') << std::dec << '\n';
    }

    if (root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__trap_enter) {
        stream << "TRAP cycle=" << cycle
               << " hart=0 from_priv=" << priv
               << " to_s="
               << static_cast<unsigned>(
                      root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__csr_trap_to_s)
               << " interrupt="
               << static_cast<unsigned>(
                      root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__trap_interrupt)
               << " cause="
               << static_cast<unsigned>(
                      root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__trap_cause)
               << " epc=" << std::hex << std::setw(16)
               << std::setfill('0')
               << root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__trap_pc
               << " vector=" << std::setw(16)
               << root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__csr_trap_vector
               << std::setfill(' ') << std::dec << '\n';
        stream.flush();
    }
}

std::string periodic_checkpoint_path(const char* prefix, uint32_t cycle) {
    return std::string{prefix} + '-' + std::to_string(cycle) + ".vls";
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
        !root->tb_4h_3p__DOT__bus_req_ready)
        return;

    const unsigned mshr =
        root->tb_4h_3p__DOT__u_l2__DOT__bus_candidate_mshr_r;
    const unsigned waiter = mshr * 8;
    std::cout
        << "L2_BUS cycle=" << cycle
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

void trace_hart0_fetch_path(const Vtb_4h_3p___024root* root,
                            uint32_t cycle, char phase) {
#define H0_CORE(name)                                                      \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__##name
#define H0_FETCH(name)                                                     \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__g_fetch_axi__DOT__u_fetch__DOT__##name
#define H0_BUS(name)                                                       \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__##name
#define H0_RAS(name)                                                       \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bp__DOT__g_ras__DOT__u_ras__DOT__##name
#define H0_CSR(name)                                                       \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_csrs__DOT__##name
    const unsigned ras_top_index = H0_RAS(top_index);
    const uint64_t satp = H0_CSR(satp_q);

    std::cout
        << "FETCH_PATH cycle=" << cycle << " phase=" << phase
        << " core=0x" << std::hex << H0_CORE(pc_q)
        << ":priv=" << std::dec << static_cast<unsigned>(H0_CSR(priv_mode_q))
        << ":vm=" << static_cast<unsigned>((satp >> 60) & 0xfU)
        << " control="
        << static_cast<unsigned>(H0_CORE(control_flush))
        << static_cast<unsigned>(H0_CORE(control_redirect))
        << static_cast<unsigned>(H0_CORE(fetch3_restart))
        << static_cast<unsigned>(H0_CORE(fetch3_invalidate))
        << ':' << static_cast<unsigned>(H0_CORE(backend_redirect))
        << ":0x" << std::hex << H0_CORE(fetch3_restart_pc)
        << ":0x" << H0_CORE(backend_redirect_target)
        << " bp=" << std::dec
        << static_cast<unsigned>(H0_CORE(bp_branch_present))
        << static_cast<unsigned>(H0_CORE(bp_branch_allocate))
        << ':' << static_cast<unsigned>(H0_CORE(bp_lane))
        << ":0x" << std::hex << H0_CORE(bp_selected_pc)
        << ":0x" << H0_CORE(bp_selected_instr)
        << ':' << std::dec
        << static_cast<unsigned>(H0_CORE(bp_lookup_indirect))
        << static_cast<unsigned>(H0_CORE(bp_lookup_rd_link))
        << ':' << static_cast<unsigned>(H0_CORE(bp_prediction_taken))
        << static_cast<unsigned>(H0_CORE(bp_prediction_target_valid))
        << ":0x" << std::hex << H0_CORE(bp_prediction_target)
        << ':' << std::dec
        << static_cast<unsigned>(H0_CORE(bp_predict_redirect))
        << ":0x" << std::hex << H0_CORE(bp_predict_target)
        << ':' << std::dec
        << static_cast<unsigned>(H0_CORE(bp_target_mispredict))
        << " ras="
        << static_cast<unsigned>(H0_RAS(sp_q))
        << ':' << static_cast<unsigned>(H0_RAS(count_q))
        << ':' << static_cast<unsigned>(H0_RAS(pending_calls_q))
        << ':' << ras_top_index
        << ":0x" << std::hex << H0_RAS(stack_q)[ras_top_index]
        << ':' << std::dec
        << static_cast<unsigned>(H0_RAS(resolve_push))
        << static_cast<unsigned>(H0_RAS(resolve_pop))
        << static_cast<unsigned>(H0_RAS(pending_call_allocate))
        << static_cast<unsigned>(H0_RAS(pending_call_resolve))
        << " fetch=0x" << std::hex << H0_FETCH(consume_pc_q)
        << ":next=0x" << H0_FETCH(next_req_addr_q)
        << ":pending=" << std::dec
        << static_cast<unsigned>(H0_FETCH(pending_valid_q))
        << ":0x" << std::hex << H0_FETCH(pending_addr_q)
        << ":req=0x" << H0_CORE(fetch_pipe_req_addr)
        << ':' << std::dec
        << static_cast<unsigned>(H0_CORE(fetch_pipe_req_ready))
        << static_cast<unsigned>(H0_CORE(fetch_pipe_req_stash))
        << static_cast<unsigned>(H0_CORE(fetch_pipe_req_demand))
        << ":select="
        << static_cast<unsigned>(H0_FETCH(pair_request_select))
        << static_cast<unsigned>(H0_FETCH(demand_request_needed))
        << static_cast<unsigned>(H0_FETCH(request_line_hit))
        << static_cast<unsigned>(H0_FETCH(request_line_pending))
        << ':' << static_cast<unsigned>(H0_FETCH(ras_req_fire))
        << static_cast<unsigned>(H0_FETCH(pair_req_fire))
        << " side="
        << static_cast<unsigned>(H0_FETCH(ras_line_pending_q))
        << ":0x" << std::hex << H0_FETCH(ras_line_addr_q)
        << ':' << std::dec
        << static_cast<unsigned>(H0_FETCH(fal_line_pending_q))
        << ":0x" << std::hex << H0_FETCH(fal_line_addr_q)
        << " pair=" << std::dec
        << static_cast<unsigned>(H0_FETCH(pair_predicted_valid_q))
        << ":0x" << std::hex << H0_FETCH(pair_predicted_addr_q)
        << ':' << std::dec
        << static_cast<unsigned>(H0_FETCH(pair_unpredicted_valid_q))
        << ":0x" << std::hex << H0_FETCH(pair_unpredicted_addr_q)
        << " icx=" << std::dec
        << static_cast<unsigned>(H0_BUS(fetch_head_q))
        << ':' << static_cast<unsigned>(H0_BUS(fetch_tail_q))
        << ":free=" << static_cast<unsigned>(H0_BUS(fetch_free_found_r))
        << ':' << static_cast<unsigned>(H0_BUS(fetch_free_slot_r))
        << ":xlate=" << static_cast<unsigned>(H0_BUS(fetch_xlate_found_r))
        << ':' << static_cast<unsigned>(H0_BUS(fetch_xlate_slot_r))
        << ":l1i=" << static_cast<unsigned>(H0_BUS(l1i_req_active_q))
        << static_cast<unsigned>(H0_BUS(fetch_l1i_launch))
        << static_cast<unsigned>(H0_BUS(l1i_req_valid))
        << static_cast<unsigned>(H0_BUS(l1i_req_fire))
        << ":0x" << std::hex << H0_BUS(l1i_req_vaddr)
        << ":0x" << H0_BUS(l1i_req_paddr_q)
        << std::dec << '\n';

    std::cout << "FETCH_STORAGE cycle=" << cycle << " phase=" << phase
              << " carousel=";
    for (unsigned slot = 0; slot < 4; ++slot) {
        if (slot)
            std::cout << ',';
        std::cout
            << static_cast<unsigned>(H0_FETCH(line_valid_q)[slot])
            << ':' << static_cast<unsigned>(H0_FETCH(line_sector_valid_q)[slot])
            << ":0x" << std::hex << H0_FETCH(line_addr_q)[slot]
            << ':' << std::dec
            << static_cast<unsigned>(H0_FETCH(carousel_pending_valid_q)[slot])
            << ":0x" << std::hex << H0_FETCH(carousel_pending_addr_q)[slot];
    }
    std::cout << " ingress=";
    for (unsigned slot = 0; slot < 4; ++slot) {
        if (slot)
            std::cout << ',';
        std::cout
            << std::dec << static_cast<unsigned>(H0_FETCH(ingress_valid_q)[slot])
            << ':' << static_cast<unsigned>(H0_FETCH(ingress_origin_q)[slot])
            << ":0x" << std::hex << H0_FETCH(ingress_addr_q)[slot];
    }
    std::cout << " slots=";
    for (unsigned slot = 0; slot < 4; ++slot) {
        if (slot)
            std::cout << ',';
        std::cout
            << std::dec << static_cast<unsigned>(H0_BUS(fetch_state_q)[slot])
            << static_cast<unsigned>(H0_BUS(fetch_cancelled_q)[slot])
            << static_cast<unsigned>(H0_BUS(fetch_stash_q)[slot])
            << static_cast<unsigned>(H0_BUS(fetch_demand_q)[slot])
            << ':' << static_cast<unsigned>(H0_BUS(fetch_priv_q)[slot])
            << ':' << static_cast<unsigned>(H0_BUS(fetch_vm_mode_q)[slot])
            << ":0x" << std::hex << H0_BUS(fetch_vaddr_q)[slot];
    }
    std::cout << std::dec << '\n';
    std::cout.flush();
#undef H0_CSR
#undef H0_RAS
#undef H0_BUS
#undef H0_FETCH
#undef H0_CORE
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
    const char* const checkpoint_interval_text =
        plusarg_value(argc, argv, "+checkpoint_interval=");
    const char* const checkpoint_prefix =
        plusarg_value(argc, argv, "+checkpoint_prefix=");
    const char* const checkpoint_stop_pc_text =
        plusarg_value(argc, argv, "+checkpoint_stop_pc=");
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
    const bool fetch_path_trace =
        has_plusarg(argc, argv, "+fetch_path_trace");
    const char* const coherence_trace_start_text =
        plusarg_value(argc, argv, "+coherence_trace_start=");
    const char* const coherence_trace_end_text =
        plusarg_value(argc, argv, "+coherence_trace_end=");
    const char* const coherence_trace_period_text =
        plusarg_value(argc, argv, "+coherence_trace_period=");
    const char* const fetch_path_trace_start_text =
        plusarg_value(argc, argv, "+fetch_path_trace_start=");
    const char* const fetch_path_trace_end_text =
        plusarg_value(argc, argv, "+fetch_path_trace_end=");
    const char* const fetch_path_trace_period_text =
        plusarg_value(argc, argv, "+fetch_path_trace_period=");
    const char* const host_pc_trace_path =
        plusarg_value(argc, argv, "+host_pc_trace=");
    const char* const l1d_watch_trace_path =
        plusarg_value(argc, argv, "+l1d_watch_trace=");
    const char* const l1d_watch_vaddr_text =
        plusarg_value(argc, argv, "+l1d_watch_vaddr=");
    const char* const l1d_watch_paddr_text =
        plusarg_value(argc, argv, "+l1d_watch_paddr=");
    const char* const l1d_watch_value_text =
        plusarg_value(argc, argv, "+l1d_watch_value=");
    const bool l1d_watch_all_mshrs =
        has_plusarg(argc, argv, "+l1d_watch_all_mshrs");

    if ((l1d_watch_trace_path == nullptr) !=
        (l1d_watch_vaddr_text == nullptr)) {
        std::cerr << "+l1d_watch_trace and +l1d_watch_vaddr are required together\n";
        return EXIT_FAILURE;
    }

    if (checkpoint_cycles_text && !checkpoint_path) {
        std::cerr << "+checkpoint_cycles requires +checkpoint\n";
        return EXIT_FAILURE;
    }
    if (checkpoint_path && !checkpoint_cycles_text) {
        std::cerr << "+checkpoint requires +checkpoint_cycles\n";
        return EXIT_FAILURE;
    }
    if (checkpoint_interval_text && !checkpoint_prefix) {
        std::cerr << "+checkpoint_interval requires +checkpoint_prefix\n";
        return EXIT_FAILURE;
    }
    if (checkpoint_prefix && !checkpoint_interval_text) {
        std::cerr << "+checkpoint_prefix requires +checkpoint_interval\n";
        return EXIT_FAILURE;
    }
    if (checkpoint_stop_pc_text && !checkpoint_interval_text) {
        std::cerr << "+checkpoint_stop_pc requires +checkpoint_interval\n";
        return EXIT_FAILURE;
    }

    const uint32_t checkpoint_cycle = checkpoint_path
        ? parse_cycle(checkpoint_cycles_text, "+checkpoint_cycles")
        : 0;
    const uint32_t checkpoint_interval = checkpoint_interval_text
        ? parse_cycle(checkpoint_interval_text, "+checkpoint_interval")
        : 0;
    const uint64_t checkpoint_stop_pc = checkpoint_stop_pc_text
        ? parse_u64(checkpoint_stop_pc_text, "+checkpoint_stop_pc")
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
    const uint32_t fetch_path_trace_start = fetch_path_trace_start_text
        ? parse_cycle(fetch_path_trace_start_text,
                      "+fetch_path_trace_start")
        : 0;
    const uint32_t fetch_path_trace_end = fetch_path_trace_end_text
        ? parse_cycle(fetch_path_trace_end_text,
                      "+fetch_path_trace_end")
        : 0;
    const uint32_t fetch_path_trace_period = fetch_path_trace_period_text
        ? parse_cycle(fetch_path_trace_period_text,
                      "+fetch_path_trace_period")
        : 1;
    bool checkpoint_saved = false;
    uint64_t next_periodic_checkpoint = checkpoint_interval;

    if (checkpoint_interval_text && checkpoint_interval == 0) {
        std::cerr << "+checkpoint_interval must be positive\n";
        return EXIT_FAILURE;
    }

    if (coherence_trace && coherence_trace_period == 0) {
        std::cerr << "+coherence_trace_period must be positive\n";
        return EXIT_FAILURE;
    }
    if (fetch_path_trace && fetch_path_trace_period == 0) {
        std::cerr << "+fetch_path_trace_period must be positive\n";
        return EXIT_FAILURE;
    }

    if (restore_path) {
        restore_model(restore_path, context.get(), top.get());
        if (checkpoint_interval != 0) {
            next_periodic_checkpoint =
                ((static_cast<uint64_t>(top->checkpoint_cycle_o) /
                  checkpoint_interval) + 1) * checkpoint_interval;
        }
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

    std::ofstream host_pc_trace;
    if (host_pc_trace_path) {
        host_pc_trace.open(host_pc_trace_path,
                           std::ios::out | std::ios::trunc);
        if (!host_pc_trace.is_open()) {
            std::cerr << "Unable to open host PC trace: "
                      << host_pc_trace_path << '\n';
            return EXIT_FAILURE;
        }
        host_pc_trace
            << "# OpenRV64 hart-0 host retirement and trap PC trace"
            << " start_cycle=" << top->checkpoint_cycle_o << '\n';
    }

    std::ofstream l1d_watch_trace;
    std::unique_ptr<L1dWatch> l1d_watch;
    if (l1d_watch_trace_path) {
        l1d_watch_trace.open(l1d_watch_trace_path,
                             std::ios::out | std::ios::trunc);
        if (!l1d_watch_trace.is_open()) {
            std::cerr << "Unable to open L1D watch trace: "
                      << l1d_watch_trace_path << '\n';
            return EXIT_FAILURE;
        }
        l1d_watch = std::make_unique<L1dWatch>(
            l1d_watch_trace,
            parse_u64(l1d_watch_vaddr_text, "+l1d_watch_vaddr"),
            l1d_watch_paddr_text, l1d_watch_value_text,
            l1d_watch_all_mshrs);
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
        if (host_pc_trace.is_open() && !top->checkpoint_clk_i) {
            trace_hart0_pc(host_pc_trace, top->rootp,
                           top->checkpoint_cycle_o);
            if ((top->checkpoint_cycle_o & 0x3fffU) == 0)
                host_pc_trace.flush();
        }
        if (l1d_watch && !top->checkpoint_clk_i)
            l1d_watch->trace(top->rootp, top->checkpoint_cycle_o);
        if (l2_bus_trace && !top->checkpoint_clk_i)
            trace_l2_bus_request(top->rootp, top->checkpoint_cycle_o);
        context->timeInc(5);
        top->checkpoint_clk_i = !top->checkpoint_clk_i;
        top->eval();

        const uint32_t cycle = top->checkpoint_cycle_o;
        const bool fetch_path_trace_active = fetch_path_trace
            && cycle >= fetch_path_trace_start
            && (fetch_path_trace_end == 0 || cycle <= fetch_path_trace_end);
        if (fetch_path_trace_active
            && (cycle % fetch_path_trace_period) == 0) {
            trace_hart0_fetch_path(rootp, cycle,
                                   top->checkpoint_clk_i ? 'H' : 'L');
        }
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
                      << " pc=0x" << std::hex << hart0_pc(rootp)
                      << std::dec
                      << " time=" << context->time() << '\n';
            std::cout.flush();
            if (checkpoint_exit)
                break;
        }

        if (checkpoint_interval != 0
            && static_cast<uint64_t>(cycle) >= next_periodic_checkpoint) {
            const std::string path =
                periodic_checkpoint_path(checkpoint_prefix, cycle);
            save_model(path.c_str(), context.get(), top.get());
            const uint64_t pc = hart0_pc(rootp);
            std::cout << "PERIODIC CHECKPOINT SAVED path=" << path
                      << " cycle=" << cycle
                      << " pc=0x" << std::hex << pc << std::dec
                      << " time=" << context->time() << '\n';
            std::cout.flush();
            do {
                next_periodic_checkpoint += checkpoint_interval;
            } while (next_periodic_checkpoint <= cycle);

            if (checkpoint_stop_pc_text && pc == checkpoint_stop_pc) {
                std::cout << "PERIODIC CHECKPOINT STOP PC cycle=" << cycle
                          << " pc=0x" << std::hex << pc << std::dec
                          << " path=" << path << '\n';
                std::cout.flush();
                break;
            }
        }

        if (stop_cycles_text && cycle >= stop_cycle) {
            std::cout << "SIMULATION STOP cycle=" << cycle
                      << " pc=0x" << std::hex << hart0_pc(rootp)
                      << std::dec
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
    if (host_pc_trace.is_open())
        host_pc_trace.flush();
    if (l1d_watch_trace.is_open())
        l1d_watch_trace.flush();
    context->statsPrintSummary();
    return EXIT_SUCCESS;
}
