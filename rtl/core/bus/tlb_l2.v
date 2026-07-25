`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"

// Shared second-level translation cache.
//
// The main array caches final 4 KiB translations in indexed, set-associative
// storage.  Superpage translations deliberately bypass this array: indexing a
// 2 MiB or 1 GiB translation with 4 KiB VPN bits would make lookup incorrect,
// while probing all possible sets would turn the structure back into a CAM.
// The small fully-associative L1 ITLB/DTLB retain superpage translations.
module openrv64_bus_tlb_l2 #(
    parameter integer ENTRIES = 256,
    parameter integer WAYS = 4,
    parameter integer ASID_WIDTH = 16
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         tlbi_i,

    input  wire                         lookup_valid_i,
    input  wire [`RV64_XLEN-1:0]        lookup_vaddr_i,
    input  wire [`RV64_SATP_MODE_WIDTH-1:0] lookup_vm_mode_i,
    input  wire [ASID_WIDTH-1:0]        lookup_asid_i,
    input  wire [1:0]                   lookup_access_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]  lookup_priv_i,
    input  wire                         lookup_sum_i,
    input  wire                         lookup_mxr_i,
    output reg                          lookup_hit_o,
    output reg  [`RV64_XLEN-1:0]        lookup_paddr_o,
    output reg                          lookup_page_fault_o,
    output reg                          lookup_global_o,
    output reg                          lookup_readable_o,
    output reg                          lookup_writable_o,
    output reg                          lookup_executable_o,
    output reg                          lookup_user_o,
    output reg                          lookup_accessed_o,
    output reg                          lookup_dirty_o,

    input  wire                         fill_valid_i,
    input  wire [`RV64_XLEN-1:0]        fill_vaddr_i,
    input  wire [`RV64_XLEN-1:0]        fill_paddr_i,
    input  wire [`RV64_SATP_MODE_WIDTH-1:0] fill_vm_mode_i,
    input  wire [ASID_WIDTH-1:0]        fill_asid_i,
    input  wire                         fill_global_i,
    input  wire [`RV64_PAGE_LEVEL_WIDTH-1:0] fill_level_i,
    input  wire                         fill_readable_i,
    input  wire                         fill_writable_i,
    input  wire                         fill_executable_i,
    input  wire                         fill_user_i,
    input  wire                         fill_accessed_i,
    input  wire                         fill_dirty_i
);

    localparam [1:0] ACCESS_READ = 2'd0;
    localparam [1:0] ACCESS_WRITE = 2'd1;
    localparam [1:0] ACCESS_EXEC = 2'd2;
    localparam integer SETS = ENTRIES / WAYS;
    localparam integer SET_INDEX_WIDTH = (SETS <= 1) ? 1 : $clog2(SETS);
    localparam integer WAY_INDEX_WIDTH = (WAYS <= 1) ? 1 : $clog2(WAYS);
    localparam integer VPN_WIDTH = `RV64_XLEN - 12;
    localparam integer ENTRY_DIRTY_BIT = 0;
    localparam integer ENTRY_ACCESSED_BIT = 1;
    localparam integer ENTRY_USER_BIT = 2;
    localparam integer ENTRY_EXECUTABLE_BIT = 3;
    localparam integer ENTRY_WRITABLE_BIT = 4;
    localparam integer ENTRY_READABLE_BIT = 5;
    localparam integer ENTRY_GLOBAL_BIT = 6;
    localparam integer ENTRY_ASID_LSB = 7;
    localparam integer ENTRY_VM_MODE_LSB = ENTRY_ASID_LSB + ASID_WIDTH;
    localparam integer ENTRY_PPN_LSB =
        ENTRY_VM_MODE_LSB + `RV64_SATP_MODE_WIDTH;
    localparam integer ENTRY_VPN_LSB = ENTRY_PPN_LSB + VPN_WIDTH;
    localparam integer ENTRY_WIDTH = ENTRY_VPN_LSB + VPN_WIDTH;

    // Valid state is resettable; the payload banks are intentionally not.
    // Keeping one packed payload memory per way gives a single indexed read
    // from each of four banks instead of a 256-entry CAM or a reset-expanded
    // register file.
    reg [SETS-1:0] valid_q [0:WAYS-1];
    reg [WAY_INDEX_WIDTH-1:0] replace_q [0:SETS-1];
    reg [WAY_INDEX_WIDTH-1:0] fill_way_r;

    wire [VPN_WIDTH-1:0] lookup_vpn =
        lookup_vaddr_i[`RV64_XLEN-1:12];
    wire [VPN_WIDTH-1:0] fill_vpn =
        fill_vaddr_i[`RV64_XLEN-1:12];
    wire [VPN_WIDTH-1:0] fill_ppn =
        fill_paddr_i[`RV64_XLEN-1:12];
    wire [SET_INDEX_WIDTH-1:0] lookup_set =
        lookup_vaddr_i[12 +: SET_INDEX_WIDTH];
    wire [SET_INDEX_WIDTH-1:0] fill_set =
        fill_vaddr_i[12 +: SET_INDEX_WIDTH];
    wire fill_4k = fill_valid_i &&
        (fill_level_i == `RV64_PAGE_LEVEL_4K);
    wire [ENTRY_WIDTH-1:0] fill_entry = {
        fill_vpn,
        fill_ppn,
        fill_vm_mode_i,
        fill_asid_i,
        fill_global_i,
        fill_readable_i,
        fill_writable_i,
        fill_executable_i,
        fill_user_i,
        fill_accessed_i,
        fill_dirty_i
    };

    wire [ENTRY_WIDTH-1:0] lookup_entry [0:WAYS-1];
    genvar storage_way;
    generate
        for (storage_way = 0; storage_way < WAYS;
             storage_way = storage_way + 1) begin : g_way_storage
            reg [ENTRY_WIDTH-1:0] entry_q [0:SETS-1];

            assign lookup_entry[storage_way] = entry_q[lookup_set];

            always @(posedge clk) begin
                if (!tlbi_i && fill_4k &&
                    (fill_way_r == storage_way))
                    entry_q[fill_set] <= fill_entry;
            end
        end
    endgenerate

    function permission_ok;
        input readable;
        input writable;
        input executable;
        input user_page;
        input accessed;
        input dirty;
        input [1:0] access_kind;
        input [`RV64_PRIV_WIDTH-1:0] privilege;
        input sum;
        input mxr;
        reg access_allowed;
        reg privilege_allowed;
        begin
            access_allowed =
                (access_kind == ACCESS_EXEC) ? executable :
                (access_kind == ACCESS_WRITE) ? writable :
                (access_kind == ACCESS_READ) ?
                    (readable || (mxr && executable)) : 1'b0;
            privilege_allowed =
                (privilege == `RV64_PRIV_U) ? user_page :
                (privilege == `RV64_PRIV_S) ?
                    (!user_page ||
                     ((access_kind != ACCESS_EXEC) && sum)) : 1'b0;
            permission_ok = access_allowed && privilege_allowed && accessed &&
                            ((access_kind != ACCESS_WRITE) || dirty);
        end
    endfunction

    integer lookup_way;
    always @* begin
        lookup_hit_o = 1'b0;
        lookup_paddr_o = {`RV64_XLEN{1'b0}};
        lookup_page_fault_o = 1'b0;
        lookup_global_o = 1'b0;
        lookup_readable_o = 1'b0;
        lookup_writable_o = 1'b0;
        lookup_executable_o = 1'b0;
        lookup_user_o = 1'b0;
        lookup_accessed_o = 1'b0;
        lookup_dirty_o = 1'b0;

        for (lookup_way = 0; lookup_way < WAYS;
             lookup_way = lookup_way + 1) begin
            if (!lookup_hit_o && lookup_valid_i && !tlbi_i &&
                valid_q[lookup_way][lookup_set] &&
                (lookup_entry[lookup_way][ENTRY_VPN_LSB +: VPN_WIDTH] ==
                 lookup_vpn) &&
                (lookup_entry[lookup_way][
                    ENTRY_VM_MODE_LSB +: `RV64_SATP_MODE_WIDTH] ==
                 lookup_vm_mode_i) &&
                (lookup_entry[lookup_way][ENTRY_GLOBAL_BIT] ||
                 (lookup_entry[lookup_way][
                    ENTRY_ASID_LSB +: ASID_WIDTH] == lookup_asid_i))) begin
                lookup_hit_o = 1'b1;
                lookup_paddr_o = {
                    lookup_entry[lookup_way][ENTRY_PPN_LSB +: VPN_WIDTH],
                    lookup_vaddr_i[11:0]
                };
                lookup_page_fault_o = !permission_ok(
                    lookup_entry[lookup_way][ENTRY_READABLE_BIT],
                    lookup_entry[lookup_way][ENTRY_WRITABLE_BIT],
                    lookup_entry[lookup_way][ENTRY_EXECUTABLE_BIT],
                    lookup_entry[lookup_way][ENTRY_USER_BIT],
                    lookup_entry[lookup_way][ENTRY_ACCESSED_BIT],
                    lookup_entry[lookup_way][ENTRY_DIRTY_BIT],
                    lookup_access_i,
                    lookup_priv_i,
                    lookup_sum_i,
                    lookup_mxr_i
                );
                lookup_global_o =
                    lookup_entry[lookup_way][ENTRY_GLOBAL_BIT];
                lookup_readable_o =
                    lookup_entry[lookup_way][ENTRY_READABLE_BIT];
                lookup_writable_o =
                    lookup_entry[lookup_way][ENTRY_WRITABLE_BIT];
                lookup_executable_o =
                    lookup_entry[lookup_way][ENTRY_EXECUTABLE_BIT];
                lookup_user_o =
                    lookup_entry[lookup_way][ENTRY_USER_BIT];
                lookup_accessed_o =
                    lookup_entry[lookup_way][ENTRY_ACCESSED_BIT];
                lookup_dirty_o =
                    lookup_entry[lookup_way][ENTRY_DIRTY_BIT];
            end
        end
    end

    reg fill_invalid_found_r;
    integer select_way;
    // A payload fill can only follow this structure's own miss, and the
    // shared walker admits one miss at a time.  No other L2-TLB fill can race
    // that walk, so a successful response cannot duplicate a resident tag.
    // Replacement therefore needs only an invalid-way search plus round
    // robin, avoiding a second payload-bank read port on the fill address.
    always @* begin
        fill_way_r = replace_q[fill_set];
        fill_invalid_found_r = 1'b0;

        for (select_way = 0; select_way < WAYS;
             select_way = select_way + 1) begin
            if (!fill_invalid_found_r &&
                !valid_q[select_way][fill_set]) begin
                fill_way_r = select_way[WAY_INDEX_WIDTH-1:0];
                fill_invalid_found_r = 1'b1;
            end
        end
    end

    wire fill_victim_valid = valid_q[fill_way_r][fill_set];

    // Simulation-visible performance events.
    wire diag_lookup = lookup_valid_i && !tlbi_i;
    wire diag_hit = diag_lookup && lookup_hit_o;
    wire diag_miss = diag_lookup && !lookup_hit_o;
    wire diag_fill = fill_4k && !tlbi_i;
    wire diag_evict = diag_fill && fill_victim_valid;
    wire diag_superpage_bypass = fill_valid_i &&
        (fill_level_i != `RV64_PAGE_LEVEL_4K);

    integer state_way;
    integer state_set;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (state_set = 0; state_set < SETS;
                 state_set = state_set + 1)
                replace_q[state_set] <= {WAY_INDEX_WIDTH{1'b0}};
            for (state_way = 0; state_way < WAYS;
                 state_way = state_way + 1)
                valid_q[state_way] <= {SETS{1'b0}};
        end else if (tlbi_i) begin
            for (state_set = 0; state_set < SETS;
                 state_set = state_set + 1)
                replace_q[state_set] <= {WAY_INDEX_WIDTH{1'b0}};
            for (state_way = 0; state_way < WAYS;
                 state_way = state_way + 1)
                valid_q[state_way] <= {SETS{1'b0}};
        end else if (fill_4k) begin
            valid_q[fill_way_r][fill_set] <= 1'b1;
            if (fill_way_r == WAYS - 1)
                replace_q[fill_set] <= {WAY_INDEX_WIDTH{1'b0}};
            else
                replace_q[fill_set] <= fill_way_r + 1'b1;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((ENTRIES < 1) || (WAYS < 1) || (ENTRIES % WAYS != 0))
            $fatal(1, "L2 TLB entries must be divisible by ways");
        if (((WAYS & (WAYS - 1)) != 0) ||
            ((SETS & (SETS - 1)) != 0))
            $fatal(1, "L2 TLB ways and sets must be powers of two");
    end
`endif

endmodule
