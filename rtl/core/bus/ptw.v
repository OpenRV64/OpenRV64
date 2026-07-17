`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"

module openrv64_bus_ptw (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         req_valid_i,
    output wire                         req_ready_o,
    input  wire [`RV64_XLEN-1:0]        req_vaddr_i,
    input  wire [1:0]                   req_access_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]  req_priv_i,
    input  wire [`RV64_SATP_MODE_WIDTH-1:0] req_vm_mode_i,
    input  wire [`RV64_SATP_ASID_WIDTH-1:0] req_asid_i,
    input  wire [`RV64_SATP_PPN_WIDTH-1:0] req_root_ppn_i,
    input  wire                         req_sum_i,
    input  wire                         req_mxr_i,

    output wire                         resp_valid_o,
    input  wire                         resp_ready_i,
    output wire [`RV64_XLEN-1:0]        resp_paddr_o,
    output wire                         resp_page_fault_o,
    output wire                         resp_access_fault_o,
    output wire                         resp_global_o,
    output wire [`RV64_PAGE_LEVEL_WIDTH-1:0] resp_level_o,
    output wire                         resp_readable_o,
    output wire                         resp_writable_o,
    output wire                         resp_executable_o,
    output wire                         resp_user_o,
    output wire                         resp_accessed_o,
    output wire                         resp_dirty_o,

    output wire                         mem_valid_o,
    input  wire                         mem_ready_i,
    output wire                         mem_write_o,
    output wire [`RV64_XLEN-1:0]        mem_addr_o,
    output wire [`RV64_XLEN-1:0]        mem_wdata_o,
    output wire [7:0]                   mem_wstrb_o,
    input  wire [`RV64_XLEN-1:0]        mem_rdata_i,
    input  wire                         mem_error_i
);

    localparam [1:0] STATE_IDLE = 2'd0;
    localparam [1:0] STATE_WALK = 2'd1;
    localparam [1:0] STATE_RESP = 2'd2;

    localparam [1:0] ACCESS_READ = 2'd0;
    localparam [1:0] ACCESS_WRITE = 2'd1;
    localparam [1:0] ACCESS_EXEC = 2'd2;

    reg [1:0] state_q;
    reg [`RV64_XLEN-1:0] vaddr_q;
    reg [1:0] access_q;
    reg [`RV64_PRIV_WIDTH-1:0] priv_q;
    reg sum_q;
    reg mxr_q;
    reg [`RV64_PAGE_LEVEL_WIDTH-1:0] level_q;
    reg [`RV64_XLEN-1:0] table_base_q;
    reg global_q;

    reg [`RV64_XLEN-1:0] resp_paddr_q;
    reg resp_page_fault_q;
    reg resp_access_fault_q;
    reg resp_global_q;
    reg [`RV64_PAGE_LEVEL_WIDTH-1:0] resp_level_q;
    reg resp_readable_q;
    reg resp_writable_q;
    reg resp_executable_q;
    reg resp_user_q;
    reg resp_accessed_q;
    reg resp_dirty_q;

    wire [8:0] vpn_0 = vaddr_q[20:12];
    wire [8:0] vpn_1 = vaddr_q[29:21];
    wire [8:0] vpn_2 = vaddr_q[38:30];
    wire [8:0] walk_vpn = (level_q == `RV64_PAGE_LEVEL_1G) ? vpn_2 :
                          (level_q == `RV64_PAGE_LEVEL_2M) ? vpn_1 : vpn_0;

    wire pte_v = mem_rdata_i[`RV64_PTE_V_BIT];
    wire pte_r = mem_rdata_i[`RV64_PTE_R_BIT];
    wire pte_w = mem_rdata_i[`RV64_PTE_W_BIT];
    wire pte_x = mem_rdata_i[`RV64_PTE_X_BIT];
    wire pte_u = mem_rdata_i[`RV64_PTE_U_BIT];
    wire pte_g = mem_rdata_i[`RV64_PTE_G_BIT];
    wire pte_a = mem_rdata_i[`RV64_PTE_A_BIT];
    wire pte_d = mem_rdata_i[`RV64_PTE_D_BIT];
    wire [`RV64_SATP_PPN_WIDTH-1:0] pte_ppn =
        mem_rdata_i[`RV64_PTE_PPN_BITS];
    wire pte_reserved = |mem_rdata_i[`RV64_PTE_RESERVED_BITS];
    wire pte_encoding_invalid = !pte_v || (!pte_r && pte_w) ||
                                pte_reserved;
    wire pte_leaf = pte_r || pte_x;
    wire pte_nonleaf_reserved = pte_u || pte_a || pte_d;

    wire canonical_sv39 =
        (req_vaddr_i[63:39] == {25{req_vaddr_i[38]}});
    wire superpage_aligned =
        (level_q == `RV64_PAGE_LEVEL_1G) ? !(|pte_ppn[17:0]) :
        (level_q == `RV64_PAGE_LEVEL_2M) ? !(|pte_ppn[8:0]) : 1'b1;

    wire access_permission =
        (access_q == ACCESS_EXEC) ? pte_x :
        (access_q == ACCESS_WRITE) ? pte_w :
        (access_q == ACCESS_READ) ? (pte_r || (mxr_q && pte_x)) : 1'b0;
    wire privilege_permission =
        (priv_q == `RV64_PRIV_U) ? pte_u :
        (priv_q == `RV64_PRIV_S) ?
            (!pte_u || ((access_q != ACCESS_EXEC) && sum_q)) : 1'b0;
    wire ad_permission = pte_a &&
                         ((access_q != ACCESS_WRITE) || pte_d);
    wire leaf_permission = access_permission && privilege_permission &&
                           ad_permission;

    function [`RV64_XLEN-1:0] compose_paddr;
        input [`RV64_SATP_PPN_WIDTH-1:0] ppn;
        input [`RV64_XLEN-1:0] vaddr;
        input [`RV64_PAGE_LEVEL_WIDTH-1:0] level;
        begin
            case (level)
                `RV64_PAGE_LEVEL_1G:
                    compose_paddr = {8'd0, ppn[43:18], vaddr[29:0]};
                `RV64_PAGE_LEVEL_2M:
                    compose_paddr = {8'd0, ppn[43:9], vaddr[20:0]};
                default:
                    compose_paddr = {8'd0, ppn, vaddr[11:0]};
            endcase
        end
    endfunction

    wire [`RV64_XLEN-1:0] leaf_paddr =
        compose_paddr(pte_ppn, vaddr_q, level_q);

    assign req_ready_o = (state_q == STATE_IDLE);

    assign resp_valid_o = (state_q == STATE_RESP);
    assign resp_paddr_o = resp_paddr_q;
    assign resp_page_fault_o = resp_page_fault_q;
    assign resp_access_fault_o = resp_access_fault_q;
    assign resp_global_o = resp_global_q;
    assign resp_level_o = resp_level_q;
    assign resp_readable_o = resp_readable_q;
    assign resp_writable_o = resp_writable_q;
    assign resp_executable_o = resp_executable_q;
    assign resp_user_o = resp_user_q;
    assign resp_accessed_o = resp_accessed_q;
    assign resp_dirty_o = resp_dirty_q;

    assign mem_valid_o = (state_q == STATE_WALK);
    assign mem_write_o = 1'b0;
    assign mem_addr_o = table_base_q + {{52{1'b0}}, walk_vpn, 3'b000};
    assign mem_wdata_o = {`RV64_XLEN{1'b0}};
    assign mem_wstrb_o = 8'h00;

    task automatic set_fault_response;
        input page_fault;
        input access_fault;
        begin
            resp_paddr_q <= {`RV64_XLEN{1'b0}};
            resp_page_fault_q <= page_fault;
            resp_access_fault_q <= access_fault;
            resp_global_q <= 1'b0;
            resp_level_q <= `RV64_PAGE_LEVEL_4K;
            resp_readable_q <= 1'b0;
            resp_writable_q <= 1'b0;
            resp_executable_q <= 1'b0;
            resp_user_q <= 1'b0;
            resp_accessed_q <= 1'b0;
            resp_dirty_q <= 1'b0;
            state_q <= STATE_RESP;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= STATE_IDLE;
            vaddr_q <= {`RV64_XLEN{1'b0}};
            access_q <= ACCESS_READ;
            priv_q <= `RV64_PRIV_M;
            sum_q <= 1'b0;
            mxr_q <= 1'b0;
            level_q <= `RV64_PAGE_LEVEL_1G;
            table_base_q <= {`RV64_XLEN{1'b0}};
            global_q <= 1'b0;
            resp_paddr_q <= {`RV64_XLEN{1'b0}};
            resp_page_fault_q <= 1'b0;
            resp_access_fault_q <= 1'b0;
            resp_global_q <= 1'b0;
            resp_level_q <= `RV64_PAGE_LEVEL_4K;
            resp_readable_q <= 1'b0;
            resp_writable_q <= 1'b0;
            resp_executable_q <= 1'b0;
            resp_user_q <= 1'b0;
            resp_accessed_q <= 1'b0;
            resp_dirty_q <= 1'b0;
        end else begin
            case (state_q)
                STATE_IDLE: begin
                    if (req_valid_i) begin
                        if (req_vm_mode_i == `RV64_SATP_MODE_BARE) begin
                            resp_paddr_q <= req_vaddr_i;
                            resp_page_fault_q <= 1'b0;
                            resp_access_fault_q <= 1'b0;
                            resp_global_q <= 1'b1;
                            resp_level_q <= `RV64_PAGE_LEVEL_4K;
                            resp_readable_q <= 1'b1;
                            resp_writable_q <= 1'b1;
                            resp_executable_q <= 1'b1;
                            resp_user_q <= 1'b1;
                            resp_accessed_q <= 1'b1;
                            resp_dirty_q <= 1'b1;
                            state_q <= STATE_RESP;
                        end else if ((req_vm_mode_i !=
                                     `RV64_SATP_MODE_SV39) ||
                                    !canonical_sv39 ||
                                    (req_priv_i == `RV64_PRIV_M)) begin
                            set_fault_response(1'b1, 1'b0);
                        end else begin
                            vaddr_q <= req_vaddr_i;
                            access_q <= req_access_i;
                            priv_q <= req_priv_i;
                            sum_q <= req_sum_i;
                            mxr_q <= req_mxr_i;
                            level_q <= `RV64_PAGE_LEVEL_1G;
                            table_base_q <= {
                                8'd0, req_root_ppn_i, 12'd0
                            };
                            global_q <= 1'b0;
                            state_q <= STATE_WALK;
                        end
                    end
                end

                STATE_WALK: begin
                    if (mem_ready_i) begin
                        if (mem_error_i) begin
                            set_fault_response(1'b0, 1'b1);
                        end else if (pte_encoding_invalid) begin
                            set_fault_response(1'b1, 1'b0);
                        end else if (pte_leaf) begin
                            if (!superpage_aligned || !leaf_permission) begin
                                set_fault_response(1'b1, 1'b0);
                            end else begin
                                resp_paddr_q <= leaf_paddr;
                                resp_page_fault_q <= 1'b0;
                                resp_access_fault_q <= 1'b0;
                                resp_global_q <= global_q || pte_g;
                                resp_level_q <= level_q;
                                resp_readable_q <= pte_r;
                                resp_writable_q <= pte_w;
                                resp_executable_q <= pte_x;
                                resp_user_q <= pte_u;
                                resp_accessed_q <= pte_a;
                                resp_dirty_q <= pte_d;
                                state_q <= STATE_RESP;
                            end
                        end else if ((level_q == `RV64_PAGE_LEVEL_4K) ||
                                     pte_nonleaf_reserved) begin
                            set_fault_response(1'b1, 1'b0);
                        end else begin
                            table_base_q <= {8'd0, pte_ppn, 12'd0};
                            level_q <= level_q - 1'b1;
                            global_q <= global_q || pte_g;
                        end
                    end
                end

                STATE_RESP: begin
                    if (resp_ready_i) begin
                        state_q <= STATE_IDLE;
                    end
                end

                default: begin
                    state_q <= STATE_IDLE;
                end
            endcase
        end
    end

    wire unused_asid = |req_asid_i;

endmodule
