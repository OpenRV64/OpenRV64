#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <limits>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

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

struct SymbolEntry {
    uint64_t address;
    std::string name;
};

class SymbolTable {
public:
    bool load(const char* path, const char* label) {
        if (!path)
            return true;

        std::ifstream input{path};
        if (!input.is_open()) {
            std::cerr << "Unable to open " << label
                      << " symbol map: " << path << '\n';
            return false;
        }

        label_ = label;
        std::string line;
        std::size_t line_number = 0;
        while (std::getline(input, line)) {
            ++line_number;
            std::istringstream fields{line};
            std::string address_text;
            std::string type;
            std::string name;
            if (!(fields >> address_text >> type >> name))
                continue;

            errno = 0;
            char* end = nullptr;
            const unsigned long long address =
                std::strtoull(address_text.c_str(), &end, 16);
            if (errno != 0 || !end || *end != '\0') {
                std::cerr << "Invalid " << label << " symbol address at "
                          << path << ':' << line_number << ": "
                          << address_text << '\n';
                return false;
            }
            entries_.push_back(
                {static_cast<uint64_t>(address), std::move(name)});
        }

        std::stable_sort(entries_.begin(), entries_.end(),
                         [](const SymbolEntry& left,
                            const SymbolEntry& right) {
                             return left.address < right.address;
                         });
        std::vector<SymbolEntry> unique;
        unique.reserve(entries_.size());
        for (SymbolEntry& entry : entries_) {
            // System.map and nm commonly emit aliases at one address. Keep
            // the final alias, which selects public weak names such as memcpy
            // over their internal implementation aliases.
            if (!unique.empty() &&
                unique.back().address == entry.address) {
                unique.back().name = std::move(entry.name);
            } else {
                unique.push_back(std::move(entry));
            }
        }
        entries_ = std::move(unique);
        if (entries_.empty()) {
            std::cerr << "No symbols found in " << label
                      << " symbol map: " << path << '\n';
            return false;
        }
        std::cout << "PC_SYMBOL_MAP label=" << label
                  << " path=" << path
                  << " entries=" << entries_.size() << '\n';
        return true;
    }

    std::string resolve(uint64_t pc) const {
        if (entries_.empty() || pc < entries_.front().address ||
            pc > entries_.back().address)
            return {};
        const auto after = std::upper_bound(
            entries_.begin(), entries_.end(), pc,
            [](uint64_t address, const SymbolEntry& entry) {
                return address < entry.address;
            });
        if (after == entries_.begin())
            return {};
        const SymbolEntry& entry = *std::prev(after);
        std::ostringstream result;
        result << label_ << ':' << entry.name;
        if (pc != entry.address)
            result << "+0x" << std::hex << (pc - entry.address);
        return result.str();
    }

private:
    std::string label_;
    std::vector<SymbolEntry> entries_;
};

class PcSymbolizer {
public:
    bool load(const char* linux_path, const char* opensbi_path) {
        enabled_ = linux_path || opensbi_path;
        return linux_.load(linux_path, "linux") &&
               opensbi_.load(opensbi_path, "opensbi");
    }

    bool enabled() const { return enabled_; }

    std::string resolve(uint64_t pc) const {
        std::string result = linux_.resolve(pc);
        if (result.empty())
            result = opensbi_.resolve(pc);
        return result.empty() ? std::string{"<unknown>"} : result;
    }

private:
    bool enabled_ = false;
    SymbolTable linux_;
    SymbolTable opensbi_;
};

uint64_t hart_pc(const Vtb_4h_3p___024root* root, unsigned hart) {
    return static_cast<uint64_t>(
               root->tb_4h_3p__DOT__dbg_pc[hart * 2]) |
           (static_cast<uint64_t>(
                root->tb_4h_3p__DOT__dbg_pc[hart * 2 + 1]) << 32);
}

uint64_t hart0_pc(const Vtb_4h_3p___024root* root) {
    return hart_pc(root, 0);
}

void trace_pc_symbols(const Vtb_4h_3p___024root* root, uint32_t cycle,
                      const PcSymbolizer& symbols) {
    const uint8_t active =
        root->tb_4h_3p__DOT__opensbi_active_hart_mask;
    std::cout << "OPENSBI_4H_PC_SYMBOLS cycles=" << cycle << " harts=";
    for (unsigned hart = 0; hart < 4; ++hart) {
        if (hart)
            std::cout << ',';
        if ((active & (1U << hart)) == 0) {
            std::cout << "<reset>";
        } else {
            std::cout << symbols.resolve(hart_pc(root, hart));
        }
    }
    std::cout << '\n';
    std::cout.flush();
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
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_debug__DOT__##name
#define H0_DEBUG(name)                                                      \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_debug__DOT__##name
#define H0_BUS(name)                                                        \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_debug__DOT__##name
#define H0_L1D(name)                                                        \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__u_debug__DOT__##name
#define H0_L1D_CACHE(name)                                                  \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__u_l1d__DOT__u_l1__DOT__g_cache__DOT__u_cache__DOT__u_debug__DOT__##name
#define H0_L1D_TAG_MEM(way)                                                 \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__u_l1d__DOT__u_l1__DOT__g_cache__DOT__u_cache__DOT__u_debug__DOT__tag_mem[way]
#define H0_L1D_DATA_MEM(way, bank)                                          \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__u_l1d__DOT__u_l1__DOT__g_cache__DOT__u_cache__DOT__u_debug__DOT__data_mem[way][bank]
        if (H0_DEBUG(xlate_req_fire) &&
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

        if (H0_L1D(fast_store_fire) &&
            same_line(H0_BUS(l1d_req_addr))) {
            stream_ << "FAST_STORE cycle=" << cycle
                    << " tag="
                    << static_cast<unsigned>(H0_BUS(l1d_req_tag))
                    << " addr=0x" << std::hex << H0_BUS(l1d_req_addr)
                    << std::dec << '\n';
            trace_buffers(root, cycle);
            stream_.flush();
        }

        const unsigned target_set =
            static_cast<unsigned>((paddr_line_ >> 6) & 0x3fU);
        const std::array<uint64_t, 4> target_set_tags = {
            H0_L1D_TAG_MEM(0)[target_set], H0_L1D_TAG_MEM(1)[target_set],
            H0_L1D_TAG_MEM(2)[target_set], H0_L1D_TAG_MEM(3)[target_set]};
        const unsigned target_bank =
            static_cast<unsigned>((paddr_line_ >> 3) & 0x7U);
        const std::array<uint64_t, 4> target_set_bank_data = {
            H0_L1D_DATA_MEM(0, target_bank)[target_set],
            H0_L1D_DATA_MEM(1, target_bank)[target_set],
            H0_L1D_DATA_MEM(2, target_bank)[target_set],
            H0_L1D_DATA_MEM(3, target_bank)[target_set]};
        std::array<bool, 4> target_set_valid{};
        for (unsigned way = 0; way < 4; ++way)
            target_set_valid[way] = H0_L1D_CACHE(valid_q)[target_set * 4 + way];
        if (!target_set_state_initialized_ ||
            target_set_tags != target_set_tags_ ||
            target_set_bank_data != target_set_bank_data_ ||
            target_set_valid != target_set_valid_) {
            stream_ << "CACHE_TARGET_SET cycle=" << cycle
                    << " valid=";
            for (unsigned way = 0; way < 4; ++way)
                stream_ << static_cast<unsigned>(target_set_valid[way]);
            stream_ << " tags=" << std::hex
                    << target_set_tags[0] << ',' << target_set_tags[1] << ','
                    << target_set_tags[2] << ',' << target_set_tags[3]
                    << " bank=" << std::dec << target_bank
                    << " bank_data=" << std::hex
                    << target_set_bank_data[0] << ','
                    << target_set_bank_data[1] << ','
                    << target_set_bank_data[2] << ','
                    << target_set_bank_data[3]
                    << " fill_fire=" << std::dec
                    << static_cast<unsigned>(H0_L1D_CACHE(fill_fire))
                    << " fill_addr=0x" << std::hex << H0_L1D(l1_fill_addr)
                    << " fill_way=" << std::dec
                    << static_cast<unsigned>(H0_L1D_CACHE(fill_way))
                    << '\n';
            target_set_state_initialized_ = true;
            target_set_tags_ = target_set_tags;
            target_set_bank_data_ = target_set_bank_data;
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
            H0_DEBUG(backend_mem_resp_ready)) {
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

        if (H0_DEBUG(trap_enter)) {
            stream_ << "TRAP cycle=" << cycle
                    << " cause="
                    << static_cast<unsigned>(H0_DEBUG(trap_cause))
                    << " epc=0x" << std::hex << H0_DEBUG(trap_pc)
                    << std::dec << '\n';
            stream_.flush();
        }
#undef H0_L1D_CACHE
#undef H0_L1D_DATA_MEM
#undef H0_L1D_TAG_MEM
#undef H0_L1D
#undef H0_BUS
#undef H0_DEBUG
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
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__u_debug__DOT__##name
#define L2(name) root->tb_4h_3p__DOT__u_l2__DOT__u_debug__DOT__##name
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
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__u_debug__DOT__##name
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
    std::array<uint64_t, 4> target_set_bank_data_{};
    std::array<OutstandingMshr, 16> l1_outstanding_{};
    bool l2_state_initialized_ = false;
    std::array<bool, 8> l2_valid_{};
    std::array<unsigned, 8> l2_state_{};
    std::array<uint64_t, 8> l2_line_{};
};

class TicketLockTrace {
  public:
    TicketLockTrace(std::ostream& stream, uint16_t ticket,
                    bool fixed_watch_addr, uint64_t watch_addr,
                    uint32_t retire_start, uint32_t retire_end)
        : stream_{stream}, ticket_{ticket},
          retire_start_{retire_start}, retire_end_{retire_end},
          have_watch_addr_{fixed_watch_addr}, watch_addr_{watch_addr},
          fixed_watch_addr_{fixed_watch_addr} {
        stream_ << "# OpenRV64 ticket-lock trace ticket=0x" << std::hex
                << ticket_;
        if (fixed_watch_addr_)
            stream_ << " paddr=0x" << watch_addr_;
        stream_ << std::dec << '\n';
    }

    void trace(const Vtb_4h_3p___024root* root, uint32_t cycle) {
#if OPENRV64_4H_CORE_INSTANCES >= 2
        trace_hart(root, cycle, 0, hart0(root));
        trace_hart(root, cycle, 1, hart1(root));

        if (!have_watch_addr_ && candidate_valid_[1]) {
            provisional_addr_ = candidate_addr_[1];
            have_provisional_addr_ = true;
        }
        if (!have_watch_addr_ && !have_provisional_addr_)
            return;

        const uint64_t addr = have_watch_addr_ ? watch_addr_ :
                                                   provisional_addr_;
        const uint64_t line = addr & ~63ULL;
        trace_l1(root, cycle, 0, line, addr);
        trace_l1(root, cycle, 1, line, addr);
        trace_l2(root, cycle, line, addr);
        trace_cache_state(root, cycle, line, addr);

        if ((cycle & 0x3fffU) == 0)
            stream_.flush();
#else
        (void)root;
        (void)cycle;
#endif
    }

    bool found() const { return have_watch_addr_; }
    uint64_t watch_addr() const { return watch_addr_; }
    uint32_t discovery_cycle() const { return discovery_cycle_; }

  private:
    static constexpr unsigned kResultWidth = 457;
    static constexpr unsigned kDataLsb = 169;
    static constexpr unsigned kInstrLsb = 233;
    static constexpr unsigned kPcLsb = 329;
    static constexpr uint64_t kAcquirePc = 0xffffffff80297e98ULL;

    struct HartView {
        uint8_t retire = 0;
        const VlWide<43>* results = nullptr;
        bool atomic_active = false;
        bool atomic_irrevocable = false;
        bool atomic_inflight = false;
        uint8_t atomic_state = 0;
        uint8_t atomic_op = 0;
        uint64_t atomic_addr = 0;
        bool request_fire = false;
        uint64_t request_addr = 0;
        uint8_t request_tag = 0;
        uint8_t request_size = 0;
        bool request_write = false;
        bool backend_resp_fire = false;
        uint8_t backend_resp_tag = 0;
        uint64_t backend_rdata = 0;
        bool l1_mem_fire = false;
        bool l1_mem_write = false;
        uint64_t l1_mem_addr = 0;
        uint64_t l1_mem_wdata = 0;
        uint8_t l1_mem_wstrb = 0;
        const VlWide<16>* l1_mem_rdata = nullptr;
        bool command_fire = false;
        uint64_t command_addr = 0;
        uint8_t command_txn = 0;
        bool command_write = false;
        bool response_fire = false;
    };

    static uint32_t word_at(uint64_t data, uint64_t addr) {
        return static_cast<uint32_t>(
            (data >> ((addr & 4ULL) ? 32 : 0)) & 0xffffffffULL);
    }

    template <std::size_t N>
    static uint32_t line_word_at(const VlWide<N>& data, uint64_t addr,
                                 unsigned lsb = 0) {
        return static_cast<uint32_t>(wide_bits(
            data, lsb + static_cast<unsigned>(addr & 63ULL) * 8, 32));
    }

    static bool same_line(uint64_t lhs, uint64_t rhs) {
        return (lhs & ~63ULL) == (rhs & ~63ULL);
    }

    HartView hart0(const Vtb_4h_3p___024root* root) const {
#define CORE(name)                                                          \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_debug__DOT__##name
#define BUS(name)                                                           \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_debug__DOT__##name
#define L1D(name)                                                           \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__u_debug__DOT__##name
        HartView view;
        view.retire = CORE(backend_retire_arch);
        view.results = &CORE(queue_retire_result);
        view.atomic_active = CORE(atomic_active);
        view.atomic_irrevocable = CORE(atomic_irrevocable);
        view.atomic_inflight = CORE(atomic_req_inflight);
        view.atomic_state = CORE(atomic_state);
        view.atomic_op = CORE(atomic_op);
        view.atomic_addr = CORE(atomic_addr);
        view.request_fire = BUS(l1d_request_fire);
        view.request_addr = BUS(l1d_req_addr);
        view.request_tag = BUS(l1d_req_tag);
        view.request_size = BUS(l1d_req_size);
        view.request_write = BUS(l1d_req_write);
        view.backend_resp_fire =
            CORE(backend_mem_resp_valid) && CORE(backend_mem_resp_ready);
        view.backend_resp_tag = CORE(backend_mem_resp_tag);
        view.backend_rdata = CORE(backend_mem_rdata);
        view.l1_mem_fire = L1D(l1_mem_valid) && L1D(l1_mem_ready);
        view.l1_mem_write = L1D(l1_mem_write);
        view.l1_mem_addr = L1D(l1_mem_addr);
        view.l1_mem_wdata = L1D(l1_mem_wdata);
        view.l1_mem_wstrb = L1D(l1_mem_wstrb);
        view.l1_mem_rdata = &L1D(l1_mem_rdata);
        view.command_fire = L1D(command_fire);
        view.command_addr = L1D(request_addr_q);
        view.command_txn = L1D(request_txn_id_q);
        view.command_write = L1D(request_write_q);
        view.response_fire = L1D(response_fire);
#undef L1D
#undef BUS
#undef CORE
        return view;
    }

#if OPENRV64_4H_CORE_INSTANCES >= 2
    HartView hart1(const Vtb_4h_3p___024root* root) const {
#define CORE(name)                                                          \
    root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__u_debug__DOT__##name
#define BUS(name)                                                           \
    root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_debug__DOT__##name
#define L1D(name)                                                           \
    root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__u_debug__DOT__##name
        HartView view;
        view.retire = CORE(backend_retire_arch);
        view.results = &CORE(queue_retire_result);
        view.atomic_active = CORE(atomic_active);
        view.atomic_irrevocable = CORE(atomic_irrevocable);
        view.atomic_inflight = CORE(atomic_req_inflight);
        view.atomic_state = CORE(atomic_state);
        view.atomic_op = CORE(atomic_op);
        view.atomic_addr = CORE(atomic_addr);
        view.request_fire = BUS(l1d_request_fire);
        view.request_addr = BUS(l1d_req_addr);
        view.request_tag = BUS(l1d_req_tag);
        view.request_size = BUS(l1d_req_size);
        view.request_write = BUS(l1d_req_write);
        view.backend_resp_fire =
            CORE(backend_mem_resp_valid) && CORE(backend_mem_resp_ready);
        view.backend_resp_tag = CORE(backend_mem_resp_tag);
        view.backend_rdata = CORE(backend_mem_rdata);
        view.l1_mem_fire = L1D(l1_mem_valid) && L1D(l1_mem_ready);
        view.l1_mem_write = L1D(l1_mem_write);
        view.l1_mem_addr = L1D(l1_mem_addr);
        view.l1_mem_wdata = L1D(l1_mem_wdata);
        view.l1_mem_wstrb = L1D(l1_mem_wstrb);
        view.l1_mem_rdata = &L1D(l1_mem_rdata);
        view.command_fire = L1D(command_fire);
        view.command_addr = L1D(request_addr_q);
        view.command_txn = L1D(request_txn_id_q);
        view.command_write = L1D(request_write_q);
        view.response_fire = L1D(response_fire);
#undef L1D
#undef BUS
#undef CORE
        return view;
    }
#endif

    void trace_hart(const Vtb_4h_3p___024root*, uint32_t cycle,
                    unsigned hart, const HartView& view) {
        if (view.atomic_active &&
            (!previous_atomic_active_[hart] ||
             view.atomic_state != previous_atomic_state_[hart] ||
             view.atomic_inflight != previous_atomic_inflight_[hart])) {
            stream_ << "ATOMIC_STATE cycle=" << cycle
                    << " hart=" << hart
                    << " active=" << view.atomic_active
                    << " irrev=" << view.atomic_irrevocable
                    << " inflight=" << view.atomic_inflight
                    << " state=" << static_cast<unsigned>(view.atomic_state)
                    << " op=" << static_cast<unsigned>(view.atomic_op)
                    << " vaddr=0x" << std::hex << view.atomic_addr
                    << std::dec << '\n';
        }

        if (view.atomic_active && view.atomic_op == 15 &&
            view.request_fire) {
            candidate_valid_[hart] = true;
            candidate_addr_[hart] = view.request_addr;
            stream_ << "AMO_L1_REQUEST cycle=" << cycle
                    << " hart=" << hart
                    << " phase=" << (view.atomic_state == 1 ? "read" :
                                      view.atomic_state == 2 ? "write" :
                                                               "other")
                    << " state=" << static_cast<unsigned>(view.atomic_state)
                    << " tag=" << static_cast<unsigned>(view.request_tag)
                    << " write=" << view.request_write
                    << " size=" << static_cast<unsigned>(view.request_size)
                    << " vaddr=0x" << std::hex << view.atomic_addr
                    << " paddr=0x" << view.request_addr << std::dec << '\n';
        }

        if (view.atomic_active && view.atomic_op == 15 &&
            view.backend_resp_fire) {
            const uint32_t old_word = word_at(view.backend_rdata,
                                              view.atomic_addr);
            stream_ << "AMO_RESPONSE cycle=" << cycle
                    << " hart=" << hart
                    << " phase=" << (view.atomic_state == 1 ? "read" :
                                      view.atomic_state == 2 ? "write" :
                                                               "other")
                    << " state=" << static_cast<unsigned>(view.atomic_state)
                    << " tag=" << static_cast<unsigned>(view.backend_resp_tag)
                    << " rdata=0x" << std::hex << view.backend_rdata
                    << " word=0x" << old_word
                    << " owner=0x" << (old_word & 0xffffU)
                    << " next=0x" << ((old_word >> 16) & 0xffffU)
                    << std::dec << '\n';
            if (hart == 1 && view.atomic_state == 1 &&
                ((old_word >> 16) & 0xffffU) == ticket_ &&
                candidate_valid_[hart]) {
                if (!fixed_watch_addr_) {
                    have_watch_addr_ = true;
                    watch_addr_ = candidate_addr_[hart];
                }
                discovery_cycle_ = cycle;
                stream_ << (fixed_watch_addr_ ? "TICKET_MATCH cycle=" :
                                              "TICKET_TARGET cycle=")
                        << cycle
                        << " hart=" << hart
                        << " ticket=0x" << std::hex << ticket_
                        << " old_word=0x" << old_word
                        << " vaddr=0x" << view.atomic_addr
                        << " paddr=0x" << watch_addr_
                        << " line=0x" << (watch_addr_ & ~63ULL)
                        << std::dec << '\n';
                stream_.flush();
            }
        }

        for (unsigned lane = 0; lane < 3; ++lane) {
            if ((view.retire & (1U << lane)) == 0)
                continue;
            const uint64_t pc = wide_bits(
                *view.results, lane * kResultWidth + kPcLsb, 64);
            if (retire_start_ != 0 && cycle >= retire_start_ &&
                (retire_end_ == 0 || cycle <= retire_end_)) {
                stream_ << "RETIRE cycle=" << cycle
                        << " hart=" << hart
                        << " lane=" << lane
                        << " pc=0x" << std::hex << pc
                        << " instr=0x"
                        << wide_bits(*view.results,
                                     lane * kResultWidth + kInstrLsb, 32)
                        << " result=0x"
                        << wide_bits(*view.results,
                                     lane * kResultWidth + kDataLsb, 64)
                        << std::dec << '\n';
            }
            if (pc != kAcquirePc)
                continue;
            const uint64_t data = wide_bits(
                *view.results, lane * kResultWidth + kDataLsb, 64);
            const uint32_t word = static_cast<uint32_t>(data);
            stream_ << "TICKET_RETIRE cycle=" << cycle
                    << " hart=" << hart
                    << " lane=" << lane
                    << " pc=0x" << std::hex << pc
                    << " instr=0x"
                    << wide_bits(*view.results,
                                 lane * kResultWidth + kInstrLsb, 32)
                    << " result=0x" << data
                    << " owner=0x" << (word & 0xffffU)
                    << " ticket=0x" << ((word >> 16) & 0xffffU)
                    << std::dec << '\n';
        }

        previous_atomic_active_[hart] = view.atomic_active;
        previous_atomic_state_[hart] = view.atomic_state;
        previous_atomic_inflight_[hart] = view.atomic_inflight;
    }

#if OPENRV64_4H_CORE_INSTANCES >= 2
    void trace_l1(const Vtb_4h_3p___024root* root, uint32_t cycle,
                  unsigned hart, uint64_t line, uint64_t lock_addr) {
        const HartView view = hart == 0 ? hart0(root) : hart1(root);
        if (view.request_fire && same_line(view.request_addr, line)) {
            pending_[hart][view.request_tag] = true;
            stream_ << "CORE_L1_REQUEST cycle=" << cycle
                    << " hart=" << hart
                    << " tag=" << static_cast<unsigned>(view.request_tag)
                    << " write=" << view.request_write
                    << " size=" << static_cast<unsigned>(view.request_size)
                    << " addr=0x" << std::hex << view.request_addr
                    << std::dec << '\n';
        }
        if (view.backend_resp_fire &&
            pending_[hart][view.backend_resp_tag]) {
            stream_ << "CORE_L1_RESPONSE cycle=" << cycle
                    << " hart=" << hart
                    << " tag="
                    << static_cast<unsigned>(view.backend_resp_tag)
                    << " rdata=0x" << std::hex << view.backend_rdata
                    << " word=0x" << word_at(view.backend_rdata, lock_addr)
                    << std::dec << '\n';
            pending_[hart][view.backend_resp_tag] = false;
        }
        if (view.l1_mem_fire && same_line(view.l1_mem_addr, line)) {
            stream_ << "L1_ARRAY_ACCESS cycle=" << cycle
                    << " hart=" << hart
                    << " write=" << view.l1_mem_write
                    << " addr=0x" << std::hex << view.l1_mem_addr
                    << " read_word=0x"
                    << line_word_at(*view.l1_mem_rdata, lock_addr)
                    << " wdata=0x" << view.l1_mem_wdata
                    << " wstrb=0x"
                    << static_cast<unsigned>(view.l1_mem_wstrb)
                    << std::dec << '\n';
        }
        if (view.command_fire && same_line(view.command_addr, line)) {
            l1_outstanding_valid_[hart][view.command_txn] = true;
            l1_outstanding_addr_[hart][view.command_txn] = view.command_addr;
            stream_ << "L1_L2_REQUEST cycle=" << cycle
                    << " hart=" << hart
                    << " txn=" << static_cast<unsigned>(view.command_txn)
                    << " write=" << view.command_write
                    << " addr=0x" << std::hex << view.command_addr
                    << std::dec << '\n';
        }
        if (view.response_fire) {
            const unsigned txn =
                (root->tb_4h_3p__DOT__hart_resp_txn_id >> (hart * 4)) & 0xfU;
            if (l1_outstanding_valid_[hart][txn] &&
                same_line(l1_outstanding_addr_[hart][txn], line)) {
                stream_ << "L2_L1_RESPONSE cycle=" << cycle
                        << " hart=" << hart << " txn=" << txn
                        << " word=0x" << std::hex
                        << wide_bits(root->tb_4h_3p__DOT__hart_resp_rdata,
                                     hart * 512 +
                                         static_cast<unsigned>(lock_addr & 63ULL) * 8,
                                     32)
                        << std::dec << '\n';
                l1_outstanding_valid_[hart][txn] = false;
            }
        }
    }

    void trace_l2(const Vtb_4h_3p___024root* root, uint32_t cycle,
                  uint64_t line, uint64_t lock_addr) {
#define L2(name) root->tb_4h_3p__DOT__u_l2__DOT__u_debug__DOT__##name
        if (L2(lookup_dispatch_r) && L2(lookup_valid_q) &&
            same_line(L2(lookup_addr_q), line)) {
            stream_ << "L2_LOOKUP cycle=" << cycle
                    << " hart="
                    << static_cast<unsigned>(L2(lookup_hart_id_q))
                    << " txn="
                    << static_cast<unsigned>(L2(lookup_txn_id_q))
                    << " source="
                    << static_cast<unsigned>(L2(lookup_source_id_q))
                    << " op=" << static_cast<unsigned>(L2(lookup_op_q))
                    << " action="
                    << static_cast<unsigned>(L2(lookup_action_r))
                    << " hit=" << static_cast<unsigned>(L2(lookup_hit_r))
                    << " mshr_match="
                    << static_cast<unsigned>(L2(lookup_mshr_match_r))
                    << " addr=0x" << std::hex << L2(lookup_addr_q)
                    << " wstrb=0x" << L2(lookup_wstrb_q)
                    << " write_word=0x"
                    << line_word_at(L2(lookup_wdata_q), lock_addr)
                    << " hit_word=0x"
                    << line_word_at(L2(lookup_hit_payload), lock_addr)
                    << " dir_hit=" << std::dec
                    << static_cast<unsigned>(
                           root->tb_4h_3p__DOT__u_l2__DOT__coherence_directory_lookup_hit)
                    << " dir_d=0x" << std::hex
                    << static_cast<unsigned>(
                           root->tb_4h_3p__DOT__u_l2__DOT__coherence_directory_lookup_d_sharers)
                    << " req_mask=0x"
                    << static_cast<unsigned>(
                           root->tb_4h_3p__DOT__u_l2__DOT__lookup_request_hart_mask_r)
                    << " probe_targets=0x"
                    << static_cast<unsigned>(
                           root->tb_4h_3p__DOT__u_l2__DOT__coherence_write_probe_targets)
                    << std::dec << '\n';
        }
        if (L2(response_enqueue) && same_line(L2(enqueue_addr), line)) {
            stream_ << "L2_RESPONSE_ENQUEUE cycle=" << cycle
                    << " source=" << (L2(hit_enqueue) ? "hit" : "mshr")
                    << " addr=0x" << std::hex << L2(enqueue_addr)
                    << " word=0x";
            if (L2(hit_enqueue))
                stream_ << line_word_at(L2(hit_data_q), lock_addr);
            else
                stream_ << line_word_at(
                    L2(mshr_replay_data_q)[L2(replay_candidate_mshr_r)],
                    lock_addr);
            stream_ << std::dec << '\n';
        }

        for (unsigned mshr = 0; mshr < 8; ++mshr) {
            const bool valid = L2(mshr_valid_q)[mshr];
            const unsigned state = L2(mshr_state_q)[mshr];
            const uint64_t mshr_line = L2(mshr_line_addr_q)[mshr];
            if (l2_initialized_ &&
                (valid != l2_valid_[mshr] || state != l2_state_[mshr] ||
                 mshr_line != l2_line_[mshr]) &&
                (same_line(mshr_line, line) ||
                 same_line(l2_line_[mshr], line))) {
                stream_ << "L2_MSHR cycle=" << cycle
                        << " index=" << mshr
                        << " old=" << l2_valid_[mshr] << ':'
                        << l2_state_[mshr] << ":0x" << std::hex
                        << l2_line_[mshr]
                        << " new=" << std::dec << valid << ':' << state
                        << ":0x" << std::hex << mshr_line << std::dec
                        << '\n';
            }
            l2_valid_[mshr] = valid;
            l2_state_[mshr] = state;
            l2_line_[mshr] = mshr_line;
        }
        l2_initialized_ = true;

        const bool probe_line_match = same_line(L2(probe_line_addr_q), line);
        const uint32_t probe_state =
            static_cast<uint32_t>(L2(probe_issue_pending)) |
            (static_cast<uint32_t>(L2(probe_ack_pending)) << 4) |
            (static_cast<uint32_t>(
                 root->tb_4h_3p__DOT__l1d_invalidate_valid) << 8) |
            (static_cast<uint32_t>(
                 root->tb_4h_3p__DOT__l1d_invalidate_ready) << 12) |
            (static_cast<uint32_t>(
                 root->tb_4h_3p__DOT__probe_resp_valid) << 16);
        if ((probe_line_match || previous_probe_line_match_) &&
            (!probe_initialized_ || probe_state != previous_probe_state_ ||
             probe_line_match != previous_probe_line_match_)) {
            stream_ << "PROBE cycle=" << cycle
                    << " issue=0x" << std::hex
                    << static_cast<unsigned>(L2(probe_issue_pending))
                    << " ack=0x"
                    << static_cast<unsigned>(L2(probe_ack_pending))
                    << " id=0x" << static_cast<unsigned>(L2(probe_id_q))
                    << " command=0x"
                    << static_cast<unsigned>(L2(probe_command_q))
                    << " cache_mask=0x"
                    << static_cast<unsigned>(L2(probe_cache_mask_q))
                    << " line=0x" << L2(probe_line_addr_q)
                    << " inv_valid=0x"
                    << static_cast<unsigned>(
                           root->tb_4h_3p__DOT__l1d_invalidate_valid)
                    << " inv_ready=0x"
                    << static_cast<unsigned>(
                           root->tb_4h_3p__DOT__l1d_invalidate_ready)
                    << " resp_valid=0x"
                    << static_cast<unsigned>(
                           root->tb_4h_3p__DOT__probe_resp_valid)
                    << std::dec << '\n';
        }

#define H0_L1(name)                                                        \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__u_l1d__DOT__u_l1__DOT__g_cache__DOT__u_cache__DOT__u_debug__DOT__##name
        const bool h0_invalidate_active =
            (root->tb_4h_3p__DOT__l1d_invalidate_valid & 1U) ||
            H0_L1(sync_invalidate_launch) ||
            H0_L1(sync_invalidate_probe_q);
        if ((probe_line_match || previous_probe_line_match_) &&
            h0_invalidate_active) {
            constexpr unsigned target_set = 63;
            stream_ << "L1_INVALIDATE_INTERNAL cycle=" << cycle
                    << " hart=0 state="
                    << static_cast<unsigned>(H0_L1(state_q))
                    << " ext_valid="
                    << static_cast<unsigned>(
                           root->tb_4h_3p__DOT__l1d_invalidate_valid & 1U)
                    << " ext_ready="
                    << static_cast<unsigned>(
                           root->tb_4h_3p__DOT__l1d_invalidate_ready & 1U)
                    << " launch="
                    << static_cast<unsigned>(H0_L1(sync_invalidate_launch))
                    << " probe="
                    << static_cast<unsigned>(H0_L1(sync_invalidate_probe_q))
                    << " tag_read_fire="
                    << static_cast<unsigned>(H0_L1(sync_tag_read_fire))
                    << " tag_read_set="
                    << static_cast<unsigned>(H0_L1(sync_tag_read_set))
                    << " captured_addr=0x" << std::hex
                    << H0_L1(sync_invalidate_addr_q)
                    << " captured_set=0x"
                    << static_cast<unsigned>(H0_L1(sync_invalidate_set_q))
                    << " captured_tag=0x"
                    << H0_L1(sync_invalidate_tag_q)
                    << " captured_valid=0x"
                    << static_cast<unsigned>(
                           H0_L1(sync_invalidate_valid_bits_q))
                    << " read_tags=";
            for (unsigned way = 0; way < 4; ++way) {
                if (way)
                    stream_ << ',';
                stream_ << H0_L1(sync_tag_read_q)[way];
            }
            stream_ << " live=";
            for (unsigned way = 0; way < 4; ++way) {
                if (way)
                    stream_ << ',';
                stream_ << static_cast<unsigned>(
                               H0_L1(valid_q)[target_set * 4 + way])
                        << ':' << H0_L1(tag_mem)[way][target_set];
            }
            stream_ << std::dec << '\n';
        }
#undef H0_L1
        probe_initialized_ = true;
        previous_probe_state_ = probe_state;
        previous_probe_line_match_ = probe_line_match;
#undef L2
    }
#endif

    void trace_cache_state(const Vtb_4h_3p___024root* root,
                           uint32_t cycle, uint64_t line,
                           uint64_t lock_addr) {
        trace_cache_hart0(root, cycle, line, lock_addr);
#if OPENRV64_4H_CORE_INSTANCES >= 2
        trace_cache_hart1(root, cycle, line, lock_addr);
#endif
    }

    void trace_cache_hart0(const Vtb_4h_3p___024root* root,
                           uint32_t cycle, uint64_t line,
                           uint64_t lock_addr) {
#define CACHE(name)                                                         \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__u_l1d__DOT__u_l1__DOT__g_cache__DOT__u_cache__DOT__u_debug__DOT__##name
        trace_cache_common(cycle, 0, line, lock_addr, CACHE(valid_q),
                           CACHE(tag_mem), CACHE(data_mem));
#undef CACHE
    }

#if OPENRV64_4H_CORE_INSTANCES >= 2
    void trace_cache_hart1(const Vtb_4h_3p___024root* root,
                           uint32_t cycle, uint64_t line,
                           uint64_t lock_addr) {
#define CACHE(name)                                                         \
    root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__u_l1d__DOT__u_l1__DOT__g_cache__DOT__u_cache__DOT__u_debug__DOT__##name
        trace_cache_common(cycle, 1, line, lock_addr, CACHE(valid_q),
                           CACHE(tag_mem), CACHE(data_mem));
#undef CACHE
    }
#endif

    template <typename ValidArray, typename TagArray, typename DataArray>
    void trace_cache_common(uint32_t cycle, unsigned hart, uint64_t line,
                            uint64_t lock_addr, const ValidArray& valid,
                            const TagArray& tags, const DataArray& data) {
        const unsigned set = static_cast<unsigned>((line >> 6) & 0x3fU);
        const unsigned bank =
            static_cast<unsigned>((lock_addr >> 3) & 0x7U);
        bool changed = !cache_initialized_[hart];
        for (unsigned way = 0; way < 4; ++way) {
            const bool way_valid = valid[set * 4 + way];
            const uint64_t tag = tags[way][set];
            const uint64_t bank_data = data[way][bank][set];
            changed = changed || way_valid != cache_valid_[hart][way] ||
                tag != cache_tag_[hart][way] ||
                bank_data != cache_data_[hart][way];
            cache_valid_[hart][way] = way_valid;
            cache_tag_[hart][way] = tag;
            cache_data_[hart][way] = bank_data;
        }
        if (!changed)
            return;
        stream_ << "L1_CACHE_STATE cycle=" << cycle
                << " hart=" << hart << " set=" << set
                << " bank=" << bank << " valid=";
        for (unsigned way = 0; way < 4; ++way)
            stream_ << cache_valid_[hart][way];
        stream_ << " entries=" << std::hex;
        for (unsigned way = 0; way < 4; ++way) {
            if (way)
                stream_ << ',';
            stream_ << cache_tag_[hart][way] << ':'
                    << word_at(cache_data_[hart][way], lock_addr);
        }
        stream_ << std::dec << '\n';
        cache_initialized_[hart] = true;
    }

    std::ostream& stream_;
    uint16_t ticket_ = 0;
    uint32_t retire_start_ = 0;
    uint32_t retire_end_ = 0;
    bool have_watch_addr_ = false;
    uint64_t watch_addr_ = 0;
    bool fixed_watch_addr_ = false;
    uint32_t discovery_cycle_ = 0;
    bool have_provisional_addr_ = false;
    uint64_t provisional_addr_ = 0;
    std::array<bool, 2> candidate_valid_{};
    std::array<uint64_t, 2> candidate_addr_{};
    std::array<bool, 2> previous_atomic_active_{};
    std::array<unsigned, 2> previous_atomic_state_{};
    std::array<bool, 2> previous_atomic_inflight_{};
    std::array<std::array<bool, 8>, 2> pending_{};
    std::array<std::array<bool, 16>, 2> l1_outstanding_valid_{};
    std::array<std::array<uint64_t, 16>, 2> l1_outstanding_addr_{};
    bool l2_initialized_ = false;
    std::array<bool, 8> l2_valid_{};
    std::array<unsigned, 8> l2_state_{};
    std::array<uint64_t, 8> l2_line_{};
    bool probe_initialized_ = false;
    bool previous_probe_line_match_ = false;
    uint32_t previous_probe_state_ = 0;
    std::array<bool, 2> cache_initialized_{};
    std::array<std::array<bool, 4>, 2> cache_valid_{};
    std::array<std::array<uint64_t, 4>, 2> cache_tag_{};
    std::array<std::array<uint64_t, 4>, 2> cache_data_{};
};

void trace_hart0_pc(std::ostream& stream,
                    const Vtb_4h_3p___024root* root,
                    uint32_t cycle) {
    constexpr unsigned result_width = 457;
    constexpr unsigned reg_write_bit = 153;
    constexpr unsigned rd_lsb = 154;
    constexpr unsigned rs2_lsb = 159;
    constexpr unsigned rs1_lsb = 164;
    constexpr unsigned data_lsb = 169;
    constexpr unsigned instr_lsb = 233;
    constexpr unsigned pc_lsb = 329;
    const uint8_t retire =
        root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_debug__DOT__backend_retire_arch;
    const auto& results =
        root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_debug__DOT__queue_retire_result;
    const unsigned priv =
        root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_debug__DOT__csr_priv_mode;
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
               << " regwrite=" << std::dec
               << wide_bits(results,
                            lane * result_width + reg_write_bit, 1)
               << " rd="
               << wide_bits(results, lane * result_width + rd_lsb, 5)
               << " data=" << std::hex << std::setw(16)
               << std::setfill('0')
               << wide_bits(results, lane * result_width + data_lsb, 64)
               << " rs1=" << std::dec
               << wide_bits(results, lane * result_width + rs1_lsb, 5)
               << " rs2="
               << wide_bits(results, lane * result_width + rs2_lsb, 5)
               << std::setfill(' ') << std::dec << '\n';
    }

    if (root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_debug__DOT__trap_enter) {
        stream << "TRAP cycle=" << cycle
               << " hart=0 from_priv=" << priv
               << " to_s="
               << static_cast<unsigned>(
                      root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_debug__DOT__csr_trap_to_s)
               << " interrupt="
               << static_cast<unsigned>(
                      root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_debug__DOT__trap_interrupt)
               << " cause="
               << static_cast<unsigned>(
                      root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_debug__DOT__trap_cause)
               << " epc=" << std::hex << std::setw(16)
               << std::setfill('0')
               << root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_debug__DOT__trap_pc
               << " vector=" << std::setw(16)
               << root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_debug__DOT__csr_trap_vector
               << std::setfill(' ') << std::dec << '\n';
        stream.flush();
    }
}

void trace_hart0_m_illegal(const Vtb_4h_3p___024root* root,
                           uint32_t cycle) {
#define H0_DEBUG(name)                                                      \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_debug__DOT__##name
    constexpr unsigned machine_privilege = 3;
    constexpr unsigned illegal_instruction_cause = 2;
    const unsigned privilege = H0_DEBUG(csr_priv_mode);

    if (!H0_DEBUG(trap_enter) || H0_DEBUG(trap_interrupt) ||
        H0_DEBUG(csr_trap_to_s) ||
        H0_DEBUG(trap_cause) != illegal_instruction_cause ||
        privilege != machine_privilege) {
        return;
    }

    std::cout
        << "HOST_M_ILLEGAL cycle=" << cycle
        << " trap_pc=0x" << std::hex << H0_DEBUG(trap_pc)
        << " backend_pc=0x" << H0_DEBUG(backend_retire_pc)
        << " backend_instr=0x" << std::setw(8) << std::setfill('0')
        << H0_DEBUG(backend_retire_instr)
        << " backend_exception=" << std::dec
        << static_cast<unsigned>(H0_DEBUG(backend_exception))
        << " backend_cause="
        << static_cast<unsigned>(H0_DEBUG(backend_cause))
        << " decode_valid=0x" << std::hex
        << static_cast<unsigned>(H0_DEBUG(decode_valid))
        << " decode_illegal=0x"
        << static_cast<unsigned>(H0_DEBUG(decode_illegal))
        << " decode0=0x" << H0_DEBUG(decode_pc0)
        << ":0x" << std::setw(8) << H0_DEBUG(instr0)
        << " decode1=0x" << H0_DEBUG(decode_pc1)
        << ":0x" << std::setw(8) << H0_DEBUG(instr1)
        << " decode2=0x" << H0_DEBUG(decode_pc2)
        << ":0x" << std::setw(8) << H0_DEBUG(instr2)
        << " csr_mepc_before=0x" << H0_DEBUG(csr_mepc)
        << " csr_mcause_before=0x" << H0_DEBUG(csr_mcause)
        << " csr_mtval_before=0x" << H0_DEBUG(csr_mtval)
        << std::setfill(' ') << std::dec << '\n';
    std::cout.flush();
#undef H0_DEBUG
}

void dump_hart0_gprs(std::ostream& stream,
                     const Vtb_4h_3p___024root* root,
                     uint32_t cycle) {
    const auto& regs =
        root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_debug__DOT__gpr_debug_regs;

    stream << "GPR_SNAPSHOT cycle=" << cycle << '\n';
    stream << std::hex << std::setfill('0');
    stream << "x0=0000000000000000\n";
    for (unsigned reg = 1; reg < 32; ++reg) {
        stream << 'x' << std::dec << reg << "=0x" << std::hex
               << std::setw(16)
               << wide_bits(regs, (reg - 1) * 64, 64) << '\n';
    }
    stream << std::dec << std::setfill(' ');
    stream.flush();
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
#define L2_DEBUG(name) root->tb_4h_3p__DOT__u_l2__DOT__u_debug__DOT__##name
    if (!root->tb_4h_3p__DOT__bus_req_valid ||
        !root->tb_4h_3p__DOT__bus_req_ready)
        return;

    const unsigned mshr =
        L2_DEBUG(bus_candidate_mshr_r);
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
               L2_DEBUG(bus_candidate_action_r))
        << " mshr=" << mshr
        << " state="
        << static_cast<unsigned>(
               L2_DEBUG(mshr_state_q)[mshr])
        << " bypass="
        << static_cast<unsigned>(
               L2_DEBUG(mshr_bypass_q)[mshr])
        << " mshr_cacheable="
        << static_cast<unsigned>(
               L2_DEBUG(mshr_bus_cacheable_q)[mshr])
        << " waiter=" << waiter
        << " hart="
        << static_cast<unsigned>(
               L2_DEBUG(waiter_hart_id_q)[waiter])
        << " source="
        << static_cast<unsigned>(
               L2_DEBUG(waiter_source_id_q)[waiter])
        << " op="
        << static_cast<unsigned>(
               L2_DEBUG(waiter_op_q)[waiter])
        << " lock="
        << static_cast<unsigned>(
               L2_DEBUG(waiter_lock_q)[waiter])
        << " waiter_size="
        << static_cast<unsigned>(
               L2_DEBUG(waiter_size_q)[waiter])
        << " waiter_addr=0x" << std::hex
        << L2_DEBUG(waiter_addr_q)[waiter]
        << " wstrb=0x"
        << root->tb_4h_3p__DOT__bus_req_wstrb
        << std::dec << '\n';
    std::cout.flush();
#undef L2_DEBUG
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
#define L2_DEBUG(name) root->tb_4h_3p__DOT__u_l2__DOT__u_debug__DOT__##name
#define EP0_DEBUG(name)                                                     \
    root->tb_4h_3p__DOT__u_probe_cluster__DOT__g_endpoint__BRA__0__KET____DOT__u_endpoint__DOT__u_debug__DOT__##name
#define EP1_DEBUG(name)                                                     \
    root->tb_4h_3p__DOT__u_probe_cluster__DOT__g_endpoint__BRA__1__KET____DOT__u_endpoint__DOT__u_debug__DOT__##name
#define H0_L1D_DEBUG(name)                                                  \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__u_debug__DOT__##name
#define H1_L1D_DEBUG(name)                                                  \
    root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1d__DOT__u_debug__DOT__##name
#define H0_L1I_DEBUG(name)                                                  \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1i__DOT__u_debug__DOT__##name
#define H1_L1I_DEBUG(name)                                                  \
    root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1i__DOT__u_debug__DOT__##name
#define H0_L1I_CACHE_DEBUG(name)                                            \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1i__DOT__u_l1i__DOT__u_l1__DOT__g_cache__DOT__u_cache__DOT__u_debug__DOT__##name
#define H1_L1I_CACHE_DEBUG(name)                                            \
    root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1i__DOT__u_l1i__DOT__u_l1__DOT__g_cache__DOT__u_cache__DOT__u_debug__DOT__##name
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
        << root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_debug__DOT__backend_retire_pc
        << ",0x"
        << root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__u_debug__DOT__backend_retire_pc
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
               L2_DEBUG(probe_issue_pending))
        << "/0x"
        << static_cast<unsigned>(
               L2_DEBUG(probe_ack_pending))
        << ":" << static_cast<unsigned>(
               L2_DEBUG(probe_id_q))
        << ':' << static_cast<unsigned>(
               L2_DEBUG(probe_command_q))
        << ':' << static_cast<unsigned>(
               L2_DEBUG(probe_cache_mask_q))
        << ":0x" << std::hex
        << L2_DEBUG(probe_line_addr_q)
        << " probe_resp=0x"
        << static_cast<unsigned>(root->tb_4h_3p__DOT__probe_resp_valid)
        << " endpoint=" << std::dec
        << static_cast<unsigned>(
               EP0_DEBUG(invalidate_pending_q))
        << ':' << static_cast<unsigned>(
               EP0_DEBUG(response_valid_q))
        << ':' << static_cast<unsigned>(
               EP0_DEBUG(response_id_q))
        << ':' << EP0_DEBUG(timeout_q)
        << ','
        << static_cast<unsigned>(
               EP1_DEBUG(invalidate_pending_q))
        << ':' << static_cast<unsigned>(
               EP1_DEBUG(response_valid_q))
        << ':' << static_cast<unsigned>(
               EP1_DEBUG(response_id_q))
        << ':' << EP1_DEBUG(timeout_q)
        << " l1d0=" << std::dec
        << static_cast<unsigned>(
               H0_L1D_DEBUG(backend_state))
        << ':'
        << static_cast<unsigned>(
               H0_L1D_DEBUG(store_buffer_count))
        << ":0x" << std::hex
        << static_cast<unsigned>(
               H0_L1D_DEBUG(demand_mshr_valid))
        << ":0x"
        << H0_L1D_DEBUG(request_addr)
        << " l1d1=" << std::dec
        << static_cast<unsigned>(
               H1_L1D_DEBUG(backend_state))
        << ':'
        << static_cast<unsigned>(
               H1_L1D_DEBUG(store_buffer_count))
        << ":0x" << std::hex
        << static_cast<unsigned>(
               H1_L1D_DEBUG(demand_mshr_valid))
        << ":0x"
        << H1_L1D_DEBUG(request_addr)
        << " l1i0=" << std::dec
        << static_cast<unsigned>(
               H0_L1I_CACHE_DEBUG(state_q))
        << ":0x" << std::hex
        << static_cast<unsigned>(
               H0_L1I_DEBUG(demand_mshr_valid_vec))
        << ':' << std::dec
        << static_cast<unsigned>(
               H0_L1I_DEBUG(response_count_q))
        << " l1i1="
        << static_cast<unsigned>(
               H1_L1I_CACHE_DEBUG(state_q))
        << ":0x" << std::hex
        << static_cast<unsigned>(
               H1_L1I_DEBUG(demand_mshr_valid_vec))
        << ':' << std::dec
        << static_cast<unsigned>(
               H1_L1I_DEBUG(response_count_q))
        << " l2=" << std::dec
        << static_cast<unsigned>(L2_DEBUG(lookup_action_r))
        << ':'
        << static_cast<unsigned>(L2_DEBUG(lookup_op_q))
        << ":0x" << std::hex
        << L2_DEBUG(lookup_addr_q)
        << " active_probe=" << std::dec
        << static_cast<unsigned>(L2_DEBUG(active_probe_mshr_q))
        << " queues="
        << static_cast<unsigned>(L2_DEBUG(cmd_count_q))
        << '/'
        << static_cast<unsigned>(L2_DEBUG(response_count_q))
        << " mshr=";
    for (unsigned mshr = 0; mshr < 8; ++mshr) {
        if (mshr)
            std::cout << ',';
        std::cout
            << static_cast<unsigned>(
                   L2_DEBUG(mshr_valid_q)[mshr])
            << ':'
            << static_cast<unsigned>(
                   L2_DEBUG(mshr_state_q)[mshr])
            << ':'
            << static_cast<unsigned>(
                   L2_DEBUG(mshr_post_probe_state_q)[mshr])
            << ':'
            << static_cast<unsigned>(
                   L2_DEBUG(mshr_coh_action_q)[mshr])
            << ":0x" << std::hex
            << L2_DEBUG(mshr_line_addr_q)[mshr]
            << ":0x" << std::hex
            << static_cast<unsigned>(
                   L2_DEBUG(mshr_probe_target_q)[mshr])
            << "/0x"
            << static_cast<unsigned>(
                   L2_DEBUG(mshr_probe_cache_mask_q)[mshr])
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
#undef H1_L1I_CACHE_DEBUG
#undef H0_L1I_CACHE_DEBUG
#undef H1_L1I_DEBUG
#undef H0_L1I_DEBUG
#undef H1_L1D_DEBUG
#undef H0_L1D_DEBUG
#undef EP1_DEBUG
#undef EP0_DEBUG
#undef L2_DEBUG
#endif
}

void trace_hart0_l1i_state(const Vtb_4h_3p___024root* root,
                           uint32_t cycle) {
#define H0_BUS(name)                                                        \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_debug__DOT__##name
#define H0_L1I(name)                                                       \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1i__DOT__u_debug__DOT__##name
#define H0_CACHE(name)                                                     \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1i__DOT__u_l1i__DOT__u_l1__DOT__g_cache__DOT__u_cache__DOT__u_debug__DOT__##name
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
            << ':' << static_cast<unsigned>(
                H0_BUS(fetch_l1i_inflight_q)[slot])
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
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_debug__DOT__##name
#define H0_FETCH(name)                                                     \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__g_fetch_axi__DOT__u_fetch__DOT__u_debug__DOT__##name
#define H0_BUS(name)                                                       \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_debug__DOT__##name
#define H0_L1I(name)                                                       \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1i__DOT__u_debug__DOT__##name
#define H0_L1I_TOP(name)                                                   \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1i__DOT__##name
#define H0_L1(name)                                                        \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1i__DOT__u_l1i__DOT__u_l1__DOT__g_cache__DOT__u_cache__DOT__u_debug__DOT__##name
#define H0_L1_TOP(name)                                                    \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bus__DOT__g_icx__DOT__u_bus__DOT__u_l1i__DOT__u_l1i__DOT__u_l1__DOT__g_cache__DOT__u_cache__DOT__##name
#define H0_RAS(name)                                                       \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_bp__DOT__g_ras__DOT__u_ras__DOT__u_debug__DOT__##name
#define H0_CSR(name)                                                       \
    root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_debug__DOT__##name
    const unsigned ras_top_index = H0_RAS(top_index);
    const uint64_t satp = H0_CSR(csr_satp);

    std::cout
        << "FETCH_PATH cycle=" << cycle << " phase=" << phase
        << " core=0x" << std::hex << H0_CORE(pc_q)
        << ":priv=" << std::dec << static_cast<unsigned>(H0_CSR(csr_priv_mode))
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
        << ':' << static_cast<unsigned>(H0_FETCH(redirect_req_fire))
        << static_cast<unsigned>(H0_FETCH(pair_req_fire))
        << " side="
        << static_cast<unsigned>(H0_FETCH(redirect_line_pending_q))
        << ":0x" << std::hex << H0_FETCH(redirect_line_addr_q)
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

    std::cout
        << "FETCH_DECODE cycle=" << cycle << " phase=" << phase
        << " fetch=" << std::hex
        << static_cast<unsigned>(H0_CORE(fetch_decode_valid))
        << static_cast<unsigned>(H0_CORE(fetch_decode_ready))
        << ":backend="
        << static_cast<unsigned>(H0_CORE(backend_decode_valid))
        << static_cast<unsigned>(H0_CORE(backend_decode_ready))
        << ":fire="
        << static_cast<unsigned>(H0_CORE(frontend_decode_fire))
        << ":decode="
        << static_cast<unsigned>(H0_CORE(decode_valid))
        << static_cast<unsigned>(H0_CORE(decode_illegal))
        << ":found="
        << static_cast<unsigned>(H0_FETCH(lane_found_r))
        << ":sectors="
        << static_cast<unsigned>(H0_FETCH(consume_live_sector_valid))
        << static_cast<unsigned>(H0_FETCH(consume_ingress_sector_valid))
        << static_cast<unsigned>(H0_FETCH(consume_alt_sector_valid))
        << ':' << static_cast<unsigned>(H0_FETCH(consume_ingress_select))
        << static_cast<unsigned>(H0_FETCH(consume_alt_select))
        << static_cast<unsigned>(H0_FETCH(consume_fetch_select))
        << static_cast<unsigned>(H0_FETCH(consume_sector_valid))
        << " lanes=0x" << H0_CORE(decode_pc0)
        << ":0x" << H0_CORE(instr0)
        << ",0x" << H0_CORE(decode_pc1)
        << ":0x" << H0_CORE(instr1)
        << ",0x" << H0_CORE(decode_pc2)
        << ":0x" << H0_CORE(instr2)
        << ":raw=0x" << wide_bits(H0_FETCH(lane_instr_r), 0, 32)
        << ",0x" << wide_bits(H0_FETCH(lane_instr_r), 32, 32)
        << ",0x" << wide_bits(H0_FETCH(lane_instr_r), 64, 32)
        << std::dec << '\n';

    std::cout
        << "FETCH_RESPONSE cycle=" << cycle << " phase=" << phase
        << " resp=" << std::dec
        << static_cast<unsigned>(H0_FETCH(resp_valid_i))
        << static_cast<unsigned>(H0_FETCH(resp_stash_i))
        << static_cast<unsigned>(H0_FETCH(resp_demand_i))
        << ":0x" << std::hex << H0_FETCH(resp_addr_i)
        << ":match=" << std::dec
        << static_cast<unsigned>(H0_FETCH(resp_match))
        << static_cast<unsigned>(H0_FETCH(carousel_resp_match))
        << static_cast<unsigned>(H0_FETCH(redirect_resp_match))
        << static_cast<unsigned>(H0_FETCH(fal_resp_match))
        << static_cast<unsigned>(H0_FETCH(orphan_forced_demand_in_window))
        << ":tap="
        << static_cast<unsigned>(H0_FETCH(alt_prefetch_aged_r))
        << static_cast<unsigned>(H0_FETCH(alt_sector_response_tap_r))
        << static_cast<unsigned>(H0_FETCH(alt_sector_predicted_tap_r))
        << static_cast<unsigned>(H0_FETCH(alt_sector_unpredicted_tap_r))
        << ":data=";
    for (unsigned word = 0; word < 8; ++word) {
        if (word)
            std::cout << ',';
        std::cout << "0x" << std::hex
                  << wide_bits(H0_FETCH(resp_data_i), word * 32, 32);
    }
    std::cout
        << ":l1i=" << std::dec
        << static_cast<unsigned>(H0_L1I(l1_resp_valid))
        << ':' << static_cast<unsigned>(H0_L1I(l1_resp_tag))
        << ':' << static_cast<unsigned>(H0_L1I(output_stored_response))
        << static_cast<unsigned>(H0_L1I(output_direct_response))
        << ":raw=";
    for (unsigned word = 0; word < 16; ++word) {
        if (word)
            std::cout << ',';
        std::cout << "0x" << std::hex
                  << wide_bits(H0_L1I(l1_req_rdata), word * 32, 32);
    }
    std::cout << ":out=";
    for (unsigned word = 0; word < 16; ++word) {
        if (word)
            std::cout << ',';
        std::cout << "0x" << std::hex
                  << wide_bits(H0_L1I(req_rdata_o), word * 32, 32);
    }
    std::cout << std::dec << '\n';

    const unsigned fill_index = H0_L1I_TOP(demand_mshr_fill_index_r);
    std::cout
        << "FETCH_L1I cycle=" << cycle << " phase=" << phase
        << " fill=" << std::dec
        << static_cast<unsigned>(H0_L1I_TOP(demand_mshr_fill_found_r))
        << ':' << fill_index
        << ":0x" << std::hex << H0_L1I(demand_mshr_addr_q)[fill_index]
        << ":0x" << wide_bits(H0_L1I_TOP(demand_mshr_data_q)[fill_index],
                               0, 32)
        << " mshr=" << std::dec
        << static_cast<unsigned>(H0_L1I(demand_mshr_valid_vec))
        << ':' << static_cast<unsigned>(H0_L1I(demand_mshr_complete_vec))
        << ':' << static_cast<unsigned>(H0_L1I(demand_mshr_fill_done_vec));
    for (unsigned slot = 0; slot < 4; ++slot) {
        std::cout
            << (slot ? ',' : ':') << slot
            << ":0x" << std::hex << H0_L1I(demand_mshr_addr_q)[slot]
            << ":0x" << wide_bits(H0_L1I_TOP(demand_mshr_data_q)[slot],
                                   0, 32);
    }
    std::cout
        << " array=" << std::dec
        << static_cast<unsigned>(H0_L1(sync_fill_launch))
        << static_cast<unsigned>(H0_L1(sync_fill_probe_q))
        << static_cast<unsigned>(H0_L1(fill_fire))
        << ':' << static_cast<unsigned>(H0_L1_TOP(sync_fill_set_q))
        << ':' << static_cast<unsigned>(H0_L1_TOP(fill_set))
        << ':' << static_cast<unsigned>(H0_L1_TOP(fill_way))
        << " lookup="
        << static_cast<unsigned>(H0_L1(request_fire))
        << static_cast<unsigned>(H0_L1_TOP(sync_lookup_valid_q))
        << ':' << static_cast<unsigned>(H0_L1_TOP(sync_lookup_set_q))
        << ':' << static_cast<unsigned>(H0_L1_TOP(sync_lookup_way_comb))
        << std::dec << '\n';
    std::cout.flush();
#undef H0_CSR
#undef H0_RAS
#undef H0_L1_TOP
#undef H0_L1
#undef H0_L1I_TOP
#undef H0_L1I
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
                root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_debug__DOT__backend_csr_write),
            root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_debug__DOT__backend_csr_write_addr,
            root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_debug__DOT__backend_csr_wdata,
            root->tb_4h_3p__DOT__g_hart__BRA__0__KET____DOT__u_core__DOT__u_debug__DOT__csr_mip_sw,
        };
#if OPENRV64_4H_CORE_INSTANCES >= 2
    case 1:
        return {
            static_cast<bool>(
                root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__u_debug__DOT__backend_csr_write),
            root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__u_debug__DOT__backend_csr_write_addr,
            root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__u_debug__DOT__backend_csr_wdata,
            root->tb_4h_3p__DOT__g_hart__BRA__1__KET____DOT__u_core__DOT__u_debug__DOT__csr_mip_sw,
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
    const char* const linux_symbols_path =
        plusarg_value(argc, argv, "+linux_symbols=");
    const char* const opensbi_symbols_path =
        plusarg_value(argc, argv, "+opensbi_symbols=");
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
    const bool gpr_snapshot = has_plusarg(argc, argv, "+gpr_snapshot");
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
    const char* const ticket_lock_trace_path =
        plusarg_value(argc, argv, "+ticket_lock_trace=");
    const char* const ticket_lock_ticket_text =
        plusarg_value(argc, argv, "+ticket_lock_ticket=");
    const char* const ticket_lock_paddr_text =
        plusarg_value(argc, argv, "+ticket_lock_paddr=");
    const char* const ticket_lock_trace_start_text =
        plusarg_value(argc, argv, "+ticket_lock_trace_start=");
    const char* const ticket_lock_trace_end_text =
        plusarg_value(argc, argv, "+ticket_lock_trace_end=");
    const char* const ticket_lock_retire_start_text =
        plusarg_value(argc, argv, "+ticket_lock_retire_start=");
    const char* const ticket_lock_retire_end_text =
        plusarg_value(argc, argv, "+ticket_lock_retire_end=");

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
    const uint32_t ticket_lock_trace_start = ticket_lock_trace_start_text
        ? parse_cycle(ticket_lock_trace_start_text,
                      "+ticket_lock_trace_start")
        : 0;
    const uint32_t ticket_lock_trace_end = ticket_lock_trace_end_text
        ? parse_cycle(ticket_lock_trace_end_text,
                      "+ticket_lock_trace_end")
        : 0;
    const uint32_t ticket_lock_retire_start = ticket_lock_retire_start_text
        ? parse_cycle(ticket_lock_retire_start_text,
                      "+ticket_lock_retire_start")
        : 0;
    const uint32_t ticket_lock_retire_end = ticket_lock_retire_end_text
        ? parse_cycle(ticket_lock_retire_end_text,
                      "+ticket_lock_retire_end")
        : 0;
    bool checkpoint_saved = false;
    uint64_t next_periodic_checkpoint = checkpoint_interval;
    uint32_t last_symbol_progress_cycle = 0;

    PcSymbolizer pc_symbols;
    if (!pc_symbols.load(linux_symbols_path, opensbi_symbols_path))
        return EXIT_FAILURE;

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

    if (gpr_snapshot)
        dump_hart0_gprs(std::cout, top->rootp,
                        top->checkpoint_cycle_o);

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

    std::ofstream ticket_lock_trace_file;
    std::unique_ptr<TicketLockTrace> ticket_lock_trace;
    if (ticket_lock_trace_path) {
        ticket_lock_trace_file.open(ticket_lock_trace_path,
                                    std::ios::out | std::ios::trunc);
        if (!ticket_lock_trace_file.is_open()) {
            std::cerr << "Unable to open ticket-lock trace: "
                      << ticket_lock_trace_path << '\n';
            return EXIT_FAILURE;
        }
        const uint64_t ticket = ticket_lock_ticket_text
            ? parse_u64(ticket_lock_ticket_text, "+ticket_lock_ticket")
            : 0x3b;
        if (ticket > 0xffffU) {
            std::cerr << "+ticket_lock_ticket exceeds 16 bits\n";
            return EXIT_FAILURE;
        }
        const bool fixed_watch_addr = ticket_lock_paddr_text != nullptr;
        const uint64_t watch_addr = fixed_watch_addr
            ? parse_u64(ticket_lock_paddr_text, "+ticket_lock_paddr")
            : 0;
        ticket_lock_trace = std::make_unique<TicketLockTrace>(
            ticket_lock_trace_file, static_cast<uint16_t>(ticket),
            fixed_watch_addr, watch_addr,
            ticket_lock_retire_start, ticket_lock_retire_end);
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
        if (!top->checkpoint_clk_i)
            trace_hart0_m_illegal(top->rootp,
                                  top->checkpoint_cycle_o);
        if (host_pc_trace.is_open() && !top->checkpoint_clk_i) {
            trace_hart0_pc(host_pc_trace, top->rootp,
                           top->checkpoint_cycle_o);
            if ((top->checkpoint_cycle_o & 0x3fffU) == 0)
                host_pc_trace.flush();
        }
        if (l1d_watch && !top->checkpoint_clk_i)
            l1d_watch->trace(top->rootp, top->checkpoint_cycle_o);
        if (ticket_lock_trace && !top->checkpoint_clk_i &&
            top->checkpoint_cycle_o >= ticket_lock_trace_start &&
            (ticket_lock_trace_end == 0 ||
             top->checkpoint_cycle_o <= ticket_lock_trace_end))
            ticket_lock_trace->trace(top->rootp,
                                     top->checkpoint_cycle_o);
        if (l2_bus_trace && !top->checkpoint_clk_i)
            trace_l2_bus_request(top->rootp, top->checkpoint_cycle_o);
        context->timeInc(5);
        top->checkpoint_clk_i = !top->checkpoint_clk_i;
        top->eval();

        const uint32_t cycle = top->checkpoint_cycle_o;
        if (pc_symbols.enabled() && cycle != 0 &&
            (cycle % 1000000) == 0 &&
            cycle != last_symbol_progress_cycle) {
            trace_pc_symbols(rootp, cycle, pc_symbols);
            last_symbol_progress_cycle = cycle;
        }
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
            const uint64_t pc = hart0_pc(rootp);
            std::cout << "CHECKPOINT SAVED path=" << checkpoint_path
                      << " cycle=" << cycle
                      << " pc=0x" << std::hex << pc << std::dec;
            if (pc_symbols.enabled())
                std::cout << " symbol=" << pc_symbols.resolve(pc);
            std::cout
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
                      << " pc=0x" << std::hex << pc << std::dec;
            if (pc_symbols.enabled())
                std::cout << " symbol=" << pc_symbols.resolve(pc);
            std::cout
                      << " time=" << context->time() << '\n';
            std::cout.flush();
            do {
                next_periodic_checkpoint += checkpoint_interval;
            } while (next_periodic_checkpoint <= cycle);

            if (checkpoint_stop_pc_text && pc == checkpoint_stop_pc) {
                std::cout << "PERIODIC CHECKPOINT STOP PC cycle=" << cycle
                          << " pc=0x" << std::hex << pc << std::dec;
                if (pc_symbols.enabled())
                    std::cout << " symbol=" << pc_symbols.resolve(pc);
                std::cout
                          << " path=" << path << '\n';
                std::cout.flush();
                break;
            }
        }

        if (stop_cycles_text && cycle >= stop_cycle) {
            const uint64_t pc = hart0_pc(rootp);
            std::cout << "SIMULATION STOP cycle=" << cycle
                      << " pc=0x" << std::hex << pc << std::dec;
            if (pc_symbols.enabled())
                std::cout << " symbol=" << pc_symbols.resolve(pc);
            std::cout
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
